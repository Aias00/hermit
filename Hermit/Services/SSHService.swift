import Foundation
@preconcurrency import Citadel
import Crypto
import NIOCore
import NIOSSH
import MoshpitKit
import CloudflareAccess
import CloudflareSSH
import TailcatSSH
import TailscaleSSH
import NIOPosix

// MARK: - Errors

enum SSHError: Error, CustomStringConvertible, LocalizedError {
    case missingKeychainRef
    case missingSecret
    case unsupportedKeyType(String)
    case ptyAlreadyOpen
    case ptyNotReady
    case sessionClosed
    case authenticationFailed
    case authMethodRejected
    case channelOpenFailed
    case connectionFailed
    case handshakeFailed
    case credentialUnavailable
    case underlying(Error)

    /// Translate a raw Citadel / NIO error into the friendliest case. The
    /// SSH handshake reaches the server before the password is ever judged,
    /// so a wrong password surfaces here as `allAuthenticationOptionsFailed`
    /// — which users must see as "authentication failed", not "error 4".
    static func map(_ error: Error) -> SSHError {
        if let e = error as? SSHError { return e }
        if let authentication = error as? SSHChannelAuthentication.Failure {
            switch authentication {
            case .connectionClosed: return .handshakeFailed
            case .timedOut: return .connectionFailed
            }
        }
        if error is CloudflareAuthError || error is AccessError
            || error is CloudflareSSHTransportError || error is ConnectionTransportError
            || error is TailcatSSHTransportError || error is TailcatCredentialError
            || error is TailscaleSSHTransportError || error is TailscaleAccountError {
            return .underlying(error)
        }
        if let c = error as? SSHClientError {
            switch c {
            case .allAuthenticationOptionsFailed:
                return .authenticationFailed
            case .unsupportedPasswordAuthentication,
                 .unsupportedPrivateKeyAuthentication,
                 .unsupportedHostBasedAuthentication:
                return .authMethodRejected
            case .channelCreationFailed:
                return .channelOpenFailed
            }
        }
        // Connection-level failures (host down / refused / timeout / DNS).
        if error is ChannelError { return .connectionFailed }
        let s = String(describing: error).lowercased()
        for needle in ["refused", "timeout", "timedout", "unreachable",
                       "connectionreset", "connectfailed", "nameresolution",
                       "posixerror"] where s.contains(needle) {
            return .connectionFailed
        }
        // The transport came up and then went away during the SSH handshake.
        // Citadel reports this as a ClientHandshakeHandler context with
        // "Disconnected error 1", which matched none of the needles above and
        // so reached the user verbatim — pointer addresses and all — on a
        // product whose troubleshooting page promises "plain language, not
        // stderr". Found by pointing a capture at an unroutable address.
        for needle in ["handshake", "disconnected"] where s.contains(needle) {
            return .handshakeFailed
        }
        return .underlying(error)
    }

    /// Citadel may report only EOF after the carrier already recorded a useful
    /// failure. Recover only bounded transport metadata, before local cleanup
    /// can add its own close events. Explicit SSH/auth decisions remain primary.
    static func preservingCloudflareSetupCause(
        _ error: Error,
        firstTermination: CloudflareSSHDiagnosticEvent.Kind?,
        firstFailure: CloudflareSSHTransportError?
    ) -> Error {
        var underlying = error
        while let ssh = underlying as? SSHError, case .underlying(let nested) = ssh {
            underlying = nested
        }
        guard !(underlying is HostKeyRejected), !(underlying is CancellationError),
              (underlying as? URLError)?.code != .cancelled else { return error }

        let mayUseTransportCause: Bool
        if let authentication = underlying as? SSHChannelAuthentication.Failure {
            mayUseTransportCause = authentication == .connectionClosed
        } else if let transport = underlying as? CloudflareSSHTransportError {
            mayUseTransportCause = transport == .connectionClosed
        } else if let channel = underlying as? ChannelError {
            switch channel {
            case .alreadyClosed, .ioOnClosedChannel, .eof: mayUseTransportCause = true
            default: mayUseTransportCause = false
            }
        } else if underlying is CloudflareAuthError || underlying is AccessError
                    || underlying is ConnectionTransportError || underlying is TailcatSSHTransportError
                    || underlying is TailcatCredentialError || underlying is TailscaleSSHTransportError
                    || underlying is TailscaleAccountError {
            mayUseTransportCause = false
        } else {
            switch map(underlying) {
            case .sessionClosed, .handshakeFailed, .underlying: mayUseTransportCause = true
            default: mayUseTransportCause = false
            }
        }
        guard mayUseTransportCause else { return error }

        switch firstTermination {
        case .failed(let failure): return firstFailure ?? failure
        case .transportEOF, .peerClose:
            // A close code is not an Access HTTP status or an SSH auth result.
            // Preserve closure without guessing why the peer chose to close.
            return CloudflareSSHTransportError.connectionClosed
        case nil:
            if let firstFailure { return firstFailure }
            return error
        default:
            // In particular, a local close/cancellation must not be relabelled
            // with a TLS/IO error produced later while the channel shuts down.
            return error
        }
    }

    /// NSError bridging shows "SSHError error 1." unless we hand Foundation
    /// the sentence ourselves — which is exactly what an upload-failure
    /// banner displayed to a user (2026-08-17). Any code path that shows
    /// `localizedDescription` now gets `description` for free.
    var errorDescription: String? { description }

    /// The raw error text, for logs and bug reports. Never shown in the UI —
    /// `description` is what a user sees, and it is a sentence.
    var diagnostic: String {
        if case .underlying(let err) = self {
            return "SSHError.underlying: \(String(describing: err))"
        }
        return "SSHError.\(self)"
    }

    var description: String {
        switch self {
        case .missingKeychainRef:
            return String(localized: "Connection has no associated keychain reference")
        case .missingSecret:
            return String(localized: "Password / private key was not provided")
        case .unsupportedKeyType(let label):
            return String(localized: "Unsupported SSH key type: \(label)")
        case .ptyAlreadyOpen:
            return String(localized: "A PTY is already attached to this session")
        case .ptyNotReady:
            return String(localized: "PTY has not been opened yet — call requestPTY first")
        case .sessionClosed:
            return String(localized: "SSH session is closed")
        case .authenticationFailed:
            return String(localized: "Authentication failed — the server rejected your username and password / key. Double-check your credentials.")
        case .authMethodRejected:
            return String(localized: "The server rejected this sign-in method. Try a different one (e.g. a key instead of a password).")
        case .channelOpenFailed:
            return String(localized: "Connected, but the server wouldn't open a session channel.")
        case .connectionFailed:
            return String(localized: "Couldn't reach the server. Check the host, port, and that it's online.")
        case .handshakeFailed:
            return String(localized: "The server closed the connection while setting up SSH. Check that the port really is an SSH server, and that a firewall or proxy isn't cutting the connection.")
        case .credentialUnavailable:
            return String(localized: "Couldn't read the saved credential. After re-installing or re-signing the app (e.g. via SideStore), open Edit and re-enter your password / re-select your key.")
        case .underlying(let error):
            if let tailcat = error as? TailcatSSHTransportError { return tailcat.moshpitMessage }
            if let tailscale = error as? TailscaleSSHTransportError { return tailscale.moshpitMessage }
            if error is CloudflareAuthError || error is AccessError
                || error is CloudflareSSHTransportError || error is ConnectionTransportError
                || error is TailcatSSHTransportError || error is TailcatCredentialError
                || error is TailscaleAccountError {
                return error.localizedDescription
            }
            // Deliberately says nothing about the wrapped error. For a library
            // type that does not implement LocalizedError — which Citadel's
            // internals do not — `localizedDescription` renders as
            // "The operation couldn't be completed. (Citadel.ClientHandshake-
            // Handler.(unknown context at $105f91dd4)… error 1.)". That went
            // straight to the alert, on a product whose troubleshooting page
            // promises "plain language, not stderr". Adding needles to the
            // classifier only ever closes the paths someone thought of; this
            // closes the default. `diagnostic` keeps the detail for logs.
            return String(localized: "The connection failed for a reason Hermit didn't recognise. Check the host, port and that the server is reachable, then try again.")
        }
    }
}

// MARK: - SSHClientProvider (testable)

/// Indirection over `Citadel.SSHClient.connect(...)` so tests can inject a
/// mock that never opens a network socket. Production uses
/// `CitadelSSHClientProvider`.
protocol SSHClientProvider: Sendable {
    func connect(
        host: String,
        port: Int,
        authenticationMethod: SSHAuthenticationMethod,
        hostKeyValidator: SSHHostKeyValidator
    ) async throws -> SSHClient

    /// Runs the SSH handshake over an already-connected channel instead of
    /// dialing `host:port` itself — the SOCKS-proxy path hands in a channel
    /// that's already past the proxy's CONNECT handshake.
    func connect(
        on channel: Channel,
        authenticationMethod: SSHAuthenticationMethod,
        hostKeyValidator: SSHHostKeyValidator
    ) async throws -> SSHClient
}

struct CitadelSSHClientProvider: SSHClientProvider {
    func connect(
        host: String,
        port: Int,
        authenticationMethod: SSHAuthenticationMethod,
        hostKeyValidator: SSHHostKeyValidator
    ) async throws -> SSHClient {
        try await SSHClient.connect(
            host: host,
            port: port,
            authenticationMethod: authenticationMethod,
            hostKeyValidator: hostKeyValidator,
            reconnect: .never,
            // The TCP connect only; the handshake has its own clock. Citadel's
            // default is 30s. A SYN that gets no answer in 15s is a black hole
            // — most often a VPN address with the tunnel down — and the sooner
            // it fails, the sooner the retry lands on the path the user has
            // meanwhile fixed. Real paths connect in one round trip.
            connectTimeout: .seconds(15)
        )
    }

    func connect(
        on channel: Channel,
        authenticationMethod: SSHAuthenticationMethod,
        hostKeyValidator: SSHHostKeyValidator
    ) async throws -> SSHClient {
        do {
            try Task.checkCancellation()
            // Citadel's connect(on:) installs its NIOSSH handlers before it
            // returns; authentication itself is driven by later inbound data.
            let executor = SSHChannelTaskExecutor(eventLoop: channel.eventLoop)
            let client = try await withTaskExecutorPreference(executor) {
                try await SSHClient.connect(
                    on: channel,
                    authenticationMethod: authenticationMethod,
                    hostKeyValidator: hostKeyValidator
                )
            }
            try Task.checkCancellation()
            return client
        } catch {
            try? await channel.close()
            throw error
        }
    }
}

/// Citadel's existing-channel entry installs handlers with NIO's synchronous
/// pipeline API before its first await. Its nonisolated async function must run
/// on this channel's event loop, including when called from Swift concurrency.
private final class SSHChannelTaskExecutor: TaskExecutor {
    private let eventLoop: EventLoop

    init(eventLoop: EventLoop) { self.eventLoop = eventLoop }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        eventLoop.execute { [self] in
            job.runSynchronously(on: asUnownedTaskExecutor())
        }
    }
}

// MARK: - SSHSession

/// A single connected SSH session with a PTY-backed shell channel.
///
/// Lifecycle:
///  1. `SSHService.connect(connection)` returns an authenticated `SSHSession`.
///  2. Caller calls `requestPTY(rows:cols:)` once — that opens the PTY and
///     starts pumping inbound bytes into `dataStream`.
///  3. Caller writes user input with `write(_:)` and forwards resize events
///     with `resize(rows:cols:)`.
///  4. Caller terminates with `close()` (or by deinit — `close()` is safe to
///     call twice).
///
/// Internally the session talks to its SSH client through the
/// ``SSHClientTransport`` seam, so lifecycle tests can run a REAL session
/// over a scripted fake — same pattern as `MoshTransport`'s
/// `DatagramChannel`.
actor SSHSession {
    nonisolated let connection: ServerConnection
    nonisolated let dataStream: AsyncStream<Data>

    private let transport: any SSHClientTransport
    /// The concrete Citadel client, kept ONLY for the SFTP subsystem — SFTP
    /// is deliberately outside the ``SSHClientTransport`` seam. A session
    /// built over an injected transport (tests) has none, and uploads then
    /// exercise the exec/base64 fallback, which the fake CAN run.
    private let sftpClient: SSHClient?
    // nonisolated: the PTY read loop yields into it DIRECTLY, synchronously,
    // preserving chunk order. It used to hop through `Task { await deliver }`
    // per chunk — an UNORDERED task per chunk, so under load chunk N+1 could
    // reach the actor before chunk N and the terminal byte stream arrived
    // REORDERED: split escape sequences, protocol lines glued into %output
    // payloads, characters at wrong positions. Bisected to b941818 against a
    // user-verified-good build 334 (2026-08-19); every rendering symptom
    // since traced back to this. `yield` is thread-safe, and yield-after-
    // finish is a documented no-op, so no `closed` guard is needed.
    private nonisolated let continuation: AsyncStream<Data>.Continuation
    private var writer: (any SSHPTYWriter)?
    private var ptyOpened = false
    private(set) var rows: Int = 24
    private(set) var cols: Int = 80
    private var closed = false
    /// Logical EOF and physical transport teardown are separate states. Every
    /// close caller joins the same owned transport shutdown, including after
    /// the PTY has already marked the session disconnected.
    private var shutdownTask: Task<Void, Never>?
    /// Fired when the transport dies on its own (read loop hit EOF/error) —
    /// NOT on an intentional `close()`. Drives auto-reconnect. Cleared after.
    private var onUnexpectedClose: (@Sendable () -> Void)?

    init(connection: ServerConnection, client: SSHClient) {
        self.init(connection: connection,
                  transport: CitadelClientTransport(client: client),
                  sftpClient: client)
    }

    /// The lifecycle-test entry: a REAL session over a scripted transport
    /// (hung execs on half-open sockets, refused PTYs, dead writers) — the
    /// same seam pattern `MoshTransport` gets from `DatagramChannel`.
    init(connection: ServerConnection,
         transport: any SSHClientTransport,
         sftpClient: SSHClient? = nil) {
        self.connection = connection
        self.transport = transport
        self.sftpClient = sftpClient

        var captured: AsyncStream<Data>.Continuation!
        self.dataStream = AsyncStream<Data>(bufferingPolicy: .unbounded) { cont in
            captured = cont
        }
        self.continuation = captured
    }

    /// True until `close()` has run or the upstream stream finishes.
    var isConnected: Bool { !closed }

    /// Register a death handler. `close()` sets `closed` first, so the handler
    /// only fires on an *unexpected* drop, never on intentional teardown.
    func setOnUnexpectedClose(_ handler: @escaping @Sendable () -> Void) {
        onUnexpectedClose = handler
    }

    // MARK: - PTY

    func requestPTY(rows: Int, cols: Int) async throws {
        try Task.checkCancellation()
        guard !closed else { throw SSHError.sessionClosed }
        guard !ptyOpened else { throw SSHError.ptyAlreadyOpen }
        ptyOpened = true
        self.rows = rows
        self.cols = cols

        try await withTaskCancellationHandler {
            let w = try await transport.openPTY(
                rows: rows, cols: cols,
                onOutput: { [weak self] data in
                    // Synchronous, in-order: the read loop is the only caller
                    // and it is sequential. See `continuation`'s doc.
                    self?.continuation.yield(data)
                },
                onEnd: { [weak self] in
                    Task { await self?.markClosed() }
                })
            try Task.checkCancellation()
            guard !closed else { throw SSHError.sessionClosed }
            installWriter(w)
        } onCancel: {
            // Citadel's PTY setup awaits NIO futures. Cancelling the Swift task
            // alone does not release those waits; closing this session's owned
            // transport ends the pending setup and its unstructured read loop.
            Task { await self.close() }
        }
    }

    // MARK: - I/O

    func write(_ data: Data) async throws {
        guard !closed else { throw SSHError.sessionClosed }
        guard let writer else { throw SSHError.ptyNotReady }
        do {
            try await writer.write(data)
        } catch {
            throw SSHError.underlying(error)
        }
    }

    func writeText(_ text: String) async throws {
        guard let data = text.data(using: .utf8) else { return }
        try await write(data)
    }

    /// Run a one-shot command over a fresh exec channel and return its stdout.
    /// Used to bootstrap mosh-server (`mosh-server new -s …` prints the UDP
    /// port + session key, then daemonizes). Does not touch the PTY channel.
    func executeCommand(_ command: String) async throws -> Data {
        guard !closed else { throw SSHError.sessionClosed }
        // Exec arguments can contain terminal input, credentials or uploaded
        // content. Even a short public prefix leaks passwords into diagnostics.
        Log.ssh.debug("exec: opening command channel")
        do {
            return try await transport.run(command)
        } catch {
            throw SSHError.underlying(error)
        }
    }

    /// Run a command with a separate, binary-safe stdin payload. The caller
    /// frames the payload (for example one JSON line); no payload is placed in
    /// the remote process arguments or diagnostics.
    func executeCommand(_ command: String, standardInput: Data) async throws -> Data {
        guard !closed else { throw SSHError.sessionClosed }
        Log.ssh.debug("exec: opening command channel with stdin")
        do {
            return try await transport.run(command, standardInput: standardInput)
        } catch {
            throw SSHError.underlying(error)
        }
    }

    /// Remembered evidence that this host's SFTP subsystem is unavailable
    /// (an upload already fell back to exec and succeeded there). Session-
    /// scoped on purpose: a reconnect probes fresh, and sshd config changes
    /// are rare enough that re-learning once per connection is cheap.
    private var sftpKnownUnavailable = false

    /// Upload one file into `~/.moshpit/uploads/` over an SFTP subchannel on
    /// this already-authenticated connection, returning the absolute remote
    /// path. Does not touch the PTY channel, so the terminal stays usable
    /// while bytes move.
    ///
    /// Hosts with `Subsystem sftp` disabled fall back to landing the bytes
    /// over exec channels alone (base64 chunks appended to a temp file, one
    /// decode at the end — see ``ExecUploadCommands``). The fallback runs on
    /// ANY SFTP failure rather than trying to classify Citadel's errors; if
    /// both paths fail, the exec error is the one surfaced, and SFTP is only
    /// remembered as unavailable once exec has actually succeeded.
    ///
    /// The home directory is resolved with `realpath .` because SFTP starts
    /// in `$HOME` but never expands `~` itself — an upload addressed to a
    /// literal `~/…` lands in a directory named `~`. `mkdir` has no `-p` and
    /// errors on an existing directory, so both creates are best-effort; a
    /// genuinely un-creatable directory still fails loudly at the open.
    /// Directory 700 / file 600: screenshots on a shared host are nobody
    /// else's to read.
    func uploadToUploadsDirectory(
        _ data: Data,
        named filename: String,
        progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        guard !closed else { throw SSHError.sessionClosed }
        if !sftpKnownUnavailable {
            do {
                return try await sftpUpload(data, named: filename, progress: progress)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Fall through to the exec path; its error wins if it also
                // fails, since it is the one still standing.
            }
        }
        let path = try await execUpload(data, named: filename, progress: progress)
        sftpKnownUnavailable = true
        return path
    }

    private func sftpUpload(
        _ data: Data,
        named filename: String,
        progress: (@Sendable (Double) -> Void)?) async throws -> String {
        // SFTPFileAttributes' public init doesn't take permissions — set the
        // field after construction.
        @Sendable func attributes(permissions: UInt32) -> SFTPFileAttributes {
            var attrs = SFTPFileAttributes()
            attrs.permissions = permissions
            return attrs
        }
        do {
            // A transport-injected session (tests) has no Citadel client and
            // therefore no SFTP — throw into the exec/base64 fallback, which
            // is exactly the path such a session wants exercised.
            guard let sftpClient else { throw SSHError.sessionClosed }
            let sftp = try await sftpClient.openSFTP()
            return try await SSHResourceScope.withCleanup(operation: {
                let home = try await sftp.getRealPath(atPath: ".")
                let appDir = home + "/.moshpit"
                let uploads = appDir + "/uploads"
                try? await sftp.createDirectory(
                    atPath: appDir, attributes: attributes(permissions: 0o700))
                try? await sftp.createDirectory(
                    atPath: uploads, attributes: attributes(permissions: 0o700))
                let path = uploads + "/" + filename
                let file = try await sftp.openFile(
                    filePath: path,
                    flags: [.write, .create, .truncate],
                    attributes: attributes(permissions: 0o600))
                try await SSHResourceScope.withCleanup(operation: {
                    // Chunked so a cancel lands between writes and progress
                    // moves during the transfer, not just at its end.
                    let chunkSize = 128 * 1024
                    var offset = 0
                    while offset < data.count {
                        try Task.checkCancellation()
                        let end = min(offset + chunkSize, data.count)
                        try await file.write(
                            ByteBuffer(bytes: data[offset..<end]), at: UInt64(offset))
                        offset = end
                        progress?(Double(offset) / Double(data.count))
                    }
                }, cleanup: { try await file.close() })
                return path
            }, cleanup: { try await sftp.close() })
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SSHError.underlying(error)
        }
    }

    /// The no-SFTP path: base64 chunks appended over exec channels, decoded
    /// once at the end. ~45 round trips for a 2MB image — a fallback, not
    /// the fast path, but it works against nothing more than a shell.
    private func execUpload(
        _ data: Data,
        named filename: String,
        progress: (@Sendable (Double) -> Void)?) async throws -> String {
        let homeData = try await executeCommand("printf %s \"$HOME\"")
        guard let home = String(data: homeData, encoding: .utf8),
              home.hasPrefix("/") else {
            throw SSHError.underlying(ExecUploadError.homeUnresolvable)
        }
        let plan = ExecUploadCommands.plan(home: home, filename: filename)

        _ = try await executeCommand(plan.begin)
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            let end = min(offset + ExecUploadCommands.chunkBytes, data.count)
            let chunk = data[offset..<end].base64EncodedString()
            _ = try await executeCommand(plan.append(chunk))
            offset = end
            // Cap below 1.0 — the decode round trip is still ahead.
            progress?(0.95 * Double(offset) / Double(data.count))
        }
        let reply = try await executeCommand(plan.finish)
        guard String(data: reply, encoding: .utf8)?
            .contains(ExecUploadCommands.successMarker) == true else {
            throw SSHError.underlying(ExecUploadError.decodeFailed)
        }
        progress?(1)
        return plan.finalPath
    }

    enum ExecUploadError: Error {
        case homeUnresolvable
        case decodeFailed
    }

    // MARK: - Reading files for preview

    /// The SFTP session previews read through, kept open between reads: a
    /// folder of thumbnails is a dozen reads in a row, and opening a fresh
    /// subsystem channel for each (what `withSFTP` does) costs a round trip
    /// apiece. Reopened when the channel has died; closed with the session.
    private var previewSFTP: SFTPClient?

    private func previewReader() async throws -> SFTPClient {
        guard !closed else { throw SSHError.sessionClosed }
        if let previewSFTP, previewSFTP.isActive { return previewSFTP }
        // A transport-injected session (tests) has no Citadel client; the
        // callers fall back to exec, as uploads do.
        guard let sftpClient else { throw SSHError.sessionClosed }
        let fresh = try await sftpClient.openSFTP()
        guard !closed else {
            try? await fresh.close()
            throw SSHError.sessionClosed
        }
        previewSFTP = fresh
        return fresh
    }

    /// What `path` is: file or folder, size, modification time. SFTP stat,
    /// or the exec fallback (no time) on a host without the subsystem.
    func remoteStat(_ path: String) async throws -> RemoteFileEntry {
        guard !closed else { throw SSHError.sessionClosed }
        do {
            let attributes = try await previewReader().getAttributes(at: path)
            return Self.entry(path: path, attributes)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let output = try await executeCommand(RemoteFileCommands.stat(path))
            guard let entry = RemoteFileCommands.parseStat(String(decoding: output, as: UTF8.self),
                                                           path: path) else {
                throw SSHError.underlying(RemoteReadError.notFound)
            }
            return entry
        }
    }

    /// Opens `path` for reads at any offset — what streaming playback pulls
    /// byte ranges through. SFTP only: the exec fallback can't read a range,
    /// so on a host without SFTP this throws and the caller downloads.
    func openRemoteFile(_ path: String) async throws -> RemoteFileHandle {
        guard !closed else { throw SSHError.sessionClosed }
        let file = try await previewReader().openFile(filePath: path, flags: .read)
        do {
            let size = try await file.readAttributes().size ?? 0
            guard size > 0 else { throw SSHError.underlying(RemoteReadError.notFound) }
            return RemoteFileHandle(file: file, size: size)
        } catch {
            try? await file.close()
            throw error
        }
    }

    /// The login directory — where SFTP and exec channels start. SFTP
    /// resolves `.`; the exec fallback asks the shell.
    func remoteHomeDirectory() async throws -> String {
        guard !closed else { throw SSHError.sessionClosed }
        do {
            let home = try await previewReader().getRealPath(atPath: ".")
            if home.hasPrefix("/") { return home }
        } catch is CancellationError {
            throw CancellationError()
        } catch {}
        let output = try await executeCommand("pwd")
        let home = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard home.hasPrefix("/") else { throw SSHError.underlying(RemoteReadError.notFound) }
        return home
    }

    /// The entries of the folder at `path`, unfiltered and unsorted (see
    /// `RemoteFileEntry.browsable`).
    func listRemoteDirectory(_ path: String) async throws -> [RemoteFileEntry] {
        guard !closed else { throw SSHError.sessionClosed }
        do {
            let base = path.hasSuffix("/") ? String(path.dropLast()) : path
            return try await previewReader().listDirectory(atPath: path)
                .flatMap(\.components)
                .filter { $0.filename != "." && $0.filename != ".." }
                .map { Self.entry(path: base + "/" + $0.filename, $0.attributes) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let output = try await executeCommand(RemoteFileCommands.list(path))
            return RemoteFileCommands.parseList(String(decoding: output, as: UTF8.self), in: path)
        }
    }

    /// Copy the file at `path` into `destination` (created or replaced).
    /// Reads ride SFTP in 256KB chunks, eight in flight at a time so a long
    /// round trip doesn't set the pace; the exec fallback moves files up to
    /// `RemoteFileCommands.execDownloadLimit` as one base64 reply.
    func downloadRemoteFile(
        _ path: String,
        to destination: URL,
        progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard !closed else { throw SSHError.sessionClosed }
        try await LocalTransferFile.write(to: destination) { staged in
            do {
                try await self.sftpDownload(path, to: staged, progress: progress)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A cancelled NIO request can surface EOF/SSHError instead
                // of CancellationError. It must not start another transfer.
                try Task.checkCancellation()
                try await self.execDownload(path, to: staged, progress: progress)
            }
        }
        progress?(1)
    }

    private func sftpDownload(
        _ path: String,
        to destination: URL,
        progress: (@Sendable (Double) -> Void)?) async throws {
        let file = try await previewReader().openFile(filePath: path, flags: .read)
        do {
            let size = try await file.readAttributes().size ?? 0
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            _ = try await WindowedRead.pull(
                size: size, chunk: 64 * 1024, window: 16,
                read: { offset, length in
                    var buffer = try await file.read(from: offset, length: length)
                    return buffer.readBytes(length: buffer.readableBytes) ?? []
                },
                write: { offset, bytes in
                    try handle.seek(toOffset: offset)
                    try handle.write(contentsOf: bytes)
                },
                progress: { received in
                    if size > 0 { progress?(min(0.99, Double(received) / Double(size))) }
                })
            try? await file.close()
        } catch {
            try? await file.close()
            throw error
        }
    }

    private func execDownload(
        _ path: String,
        to destination: URL,
        progress: (@Sendable (Double) -> Void)?) async throws {
        let entry = try await remoteStat(path)
        guard !entry.isDirectory else { throw SSHError.underlying(RemoteReadError.notFound) }
        guard (entry.size ?? 0) <= RemoteFileCommands.execDownloadLimit else {
            throw SSHError.underlying(RemoteReadError.tooLargeWithoutSFTP)
        }
        let output = try await executeCommand(RemoteFileCommands.cat(path))
        guard let data = Data(base64Encoded: output, options: .ignoreUnknownCharacters) else {
            throw SSHError.underlying(RemoteReadError.notFound)
        }
        try Task.checkCancellation()
        try data.write(to: destination)
    }

    enum RemoteReadError: Error {
        case notFound
        case tooLargeWithoutSFTP
    }

    // MARK: - Changing files from the folder sheet

    enum RemoteEditError: Error {
        /// Something with the target name is already there.
        case nameTaken
        /// The exec form ran but didn't report success, or the path is one
        /// the sheet never deletes.
        case failed
    }

    /// SFTP first, the exec form (`RemoteFileEdits`) on any SFTP failure —
    /// the same split as reads. The exec reply decides: its marker is the
    /// only success there is.
    private func edit(sftp: (SFTPClient) async throws -> Void, exec command: String?) async throws {
        guard !closed else { throw SSHError.sessionClosed }
        do {
            try await sftp(previewReader())
            return
        } catch is CancellationError {
            throw CancellationError()
        } catch {}
        guard let command else { throw SSHError.underlying(RemoteEditError.failed) }
        try Self.checkEditReply(try await executeCommand(command))
    }

    private static func checkEditReply(_ reply: Data) throws {
        let text = String(decoding: reply, as: UTF8.self)
        if text.contains(RemoteFileEdits.takenMarker) { throw SSHError.underlying(RemoteEditError.nameTaken) }
        guard text.contains(RemoteFileEdits.okMarker) else { throw SSHError.underlying(RemoteEditError.failed) }
    }

    func createRemoteDirectory(_ path: String) async throws {
        try await edit(sftp: { try await $0.createDirectory(atPath: path) },
                       exec: RemoteFileEdits.makeDirectory(path))
    }

    /// Never overwrites: OpenSSH's SFTP rename refuses an existing target,
    /// and the exec form checks first.
    func renameRemoteItem(_ path: String, to newPath: String) async throws {
        try await edit(sftp: { sftp in
            if (try? await sftp.getAttributes(at: newPath)) != nil {
                throw SSHError.underlying(RemoteEditError.nameTaken)
            }
            try await sftp.rename(at: path, to: newPath)
        }, exec: RemoteFileEdits.rename(path, to: newPath))
    }

    /// A file goes through SFTP; a folder, with everything in it, through
    /// `rm -rf` — SFTP can only remove an empty one.
    func deleteRemoteItem(_ entry: RemoteFileEntry) async throws {
        guard let command = RemoteFileEdits.remove(entry.path, isDirectory: entry.isDirectory) else {
            throw SSHError.underlying(RemoteEditError.failed)
        }
        if entry.isDirectory {
            guard !closed else { throw SSHError.sessionClosed }
            try Self.checkEditReply(try await executeCommand(command))
        } else {
            try await edit(sftp: { try await $0.remove(at: entry.path) }, exec: command)
        }
    }

    /// Each upload owns its SFTP/exec children. Cancelling releases the caller
    /// even if a peer never replies, without closing the interactive transport.
    func uploadRemoteFile(from local: URL, to remotePath: String,
                          progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let scope = SSHChildChannelScope()
        defer { scope.cancel() }
        try await CancellableTransfer.run(onCancel: { scope.cancel() }) {
            try await self.performUpload(from: local, to: remotePath,
                                         progress: progress, scope: scope)
        }
    }

    private func performUpload(from local: URL, to remotePath: String,
                               progress: (@Sendable (Double) -> Void)?,
                               scope: SSHChildChannelScope) async throws {
        try Task.checkCancellation()
        try scope.checkCancellation()
        guard !closed else { throw SSHError.sessionClosed }
        let size = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? UInt64) ?? 0
        let scratch = RemoteFileEdits.uploadScratchDirectory(for: remotePath)
        var ownsSFTPScratch = false
        do {
            guard let sftpClient else { throw SSHError.sessionClosed }
            // Never reuse the preview reader: cancelling an upload must not
            // close a thumbnail, download, or the terminal's child channel.
            let sftp = try await sftpClient.openSFTP(cancellationScope: scope)
            try Task.checkCancellation()
            var directoryAttributes = SFTPFileAttributes.none
            directoryAttributes.permissions = 0o700
            try await sftp.createDirectory(atPath: scratch, attributes: directoryAttributes)
            ownsSFTPScratch = true
            let payload = RemoteFileEdits.child("payload", of: scratch)
            var fileAttributes = SFTPFileAttributes.none
            fileAttributes.permissions = 0o600
            let file = try await sftp.openFile(filePath: payload, flags: [.write, .create, .forceCreate],
                                               attributes: fileAttributes)
            let handle = try FileHandle(forReadingFrom: local)
            defer { try? handle.close() }
            var offset: UInt64 = 0
            while let chunk = try handle.read(upToCount: 128 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                try await file.write(ByteBuffer(bytes: chunk), at: offset)
                try Task.checkCancellation()
                offset += UInt64(chunk.count)
                if size > 0 { progress?(min(0.99, Double(offset) / Double(size))) }
            }
            try await file.close()
            try Task.checkCancellation()
            // Standard SFTP v3 rename refuses an existing target. Keeping all
            // partial bytes in an owned directory also makes delayed cleanup
            // harmless to a newer upload, including a lost rename reply.
            try await sftp.rename(at: payload, to: remotePath)
            _ = await withTimeoutValue(1) { try await sftp.rmdir(at: scratch); return true }
            try Task.checkCancellation()
            try scope.checkCancellation()
            progress?(1)
            return
        } catch {
            if ownsSFTPScratch {
                await cleanupUploadScratch(RemoteFileEdits.sftpUploadCleanup(directory: scratch))
            }
            try Task.checkCancellation()
            try scope.checkCancellation()
        }

        guard size <= RemoteFileCommands.execDownloadLimit else {
            throw SSHError.underlying(RemoteReadError.tooLargeWithoutSFTP)
        }
        let data = try Data(contentsOf: local)
        let plan = RemoteFileEdits.upload(to: remotePath)
        var ownsScratch = false
        do {
            try Task.checkCancellation()
            try Self.checkEditReply(try await transport.run(plan.begin, cancellationScope: scope))
            ownsScratch = true
            var offset = 0
            while offset < data.count {
                try Task.checkCancellation()
                let end = min(offset + ExecUploadCommands.chunkBytes, data.count)
                _ = try await transport.run(plan.append(data[offset..<end].base64EncodedString()),
                                            cancellationScope: scope)
                try Task.checkCancellation()
                offset = end
                progress?(0.95 * Double(offset) / Double(max(data.count, 1)))
            }
            try Task.checkCancellation()
            try Self.checkEditReply(try await transport.run(plan.finish, cancellationScope: scope))
            try Task.checkCancellation()
            try scope.checkCancellation()
            progress?(1)
        } catch {
            // Only a confirmed begin grants ownership. Cleanup never touches
            // the final target, whose ownership is ambiguous after a lost reply.
            if ownsScratch { await cleanupUploadScratch(plan.cleanup) }
            try Task.checkCancellation()
            try scope.checkCancellation()
            throw SSHError.map(error)
        }
    }

    private func cleanupUploadScratch(_ command: String) async {
        // Cleanup has its own lifetime, since the upload's scope is cancelled.
        // Closing this scope at the deadline also stops late channel creation.
        let cleanup = SSHChildChannelScope()
        defer { cleanup.cancel() }
        _ = await withTimeoutValue(1) {
            _ = try await self.transport.run(command, cancellationScope: cleanup)
            return true
        }
    }

    private static func entry(path: String, _ attributes: SFTPFileAttributes) -> RemoteFileEntry {
        // S_IFMT / S_IFDIR. A symlink reads as what readdir reported for the
        // link itself; a link to a previewable file still previews.
        let isDirectory = attributes.permissions.map { $0 & 0o170000 == 0o040000 } ?? false
        return RemoteFileEntry(path: path, isDirectory: isDirectory, size: attributes.size,
                               modified: attributes.accessModificationTime?.modificationTime)
    }

    func resize(rows: Int, cols: Int) async throws {
        guard !closed else { throw SSHError.sessionClosed }
        self.rows = rows
        self.cols = cols
        guard let writer else { throw SSHError.ptyNotReady }
        do {
            try await writer.resize(cols: cols, rows: rows)
        } catch {
            throw SSHError.underlying(error)
        }
    }

    func close() async {
        closed = true
        writer = nil
        onUnexpectedClose = nil
        continuation.finish()
        await shutdownOwnedTransport()
    }

    // MARK: - Private actor-isolated helpers

    private func installWriter(_ w: any SSHPTYWriter) {
        self.writer = w
    }

    private func markClosed() async {
        guard !closed else { return }
        closed = true
        writer = nil
        continuation.finish()
        // Reached only on an unexpected drop — `close()` flips `closed` first,
        // so the read loop's markClosed is a no-op there.
        let handler = onUnexpectedClose
        onUnexpectedClose = nil
        handler?()
        await shutdownOwnedTransport()
    }

    private func shutdownOwnedTransport() async {
        if let shutdownTask { await shutdownTask.value; return }
        let transport = self.transport
        let preview = previewSFTP
        previewSFTP = nil
        let shutdown = Task {
            // Close the parent first. Waiting for an SFTP child on a dead or
            // backpressured carrier must not delay the operation that releases
            // all pending channel reads/writes.
            await transport.shutdown()
            try? await preview?.close()
        }
        shutdownTask = shutdown
        await shutdown.value
    }
}

// MARK: - Client transport seam

/// The slice of the SSH client that ``SSHSession`` consumes, as a protocol —
/// the seam that lets lifecycle tests run a real session over a scripted
/// fake: a hung exec on a half-open socket, a refused PTY, a dead writer —
/// the exact shapes behind this week's suspension/recovery bugs, none of
/// which loopback networking can produce. Production is
/// ``CitadelClientTransport``. SFTP is deliberately NOT part of the seam
/// (see `SSHSession.sftpClient`).
protocol SSHClientTransport: AnyObject, Sendable {
    /// One-shot exec channel: stderr merged, buffered to completion.
    func run(_ command: String) async throws -> Data
    /// Exec owned by an individual cancellable transfer, never the parent PTY.
    func run(_ command: String, cancellationScope: SSHChildChannelScope) async throws -> Data
    /// One-shot exec with framed stdin, separate from the command arguments.
    func run(_ command: String, standardInput: Data) async throws -> Data
    /// Open the interactive PTY. Returns once the server accepted it,
    /// handing back the stdin writer; `onOutput` then streams host bytes for
    /// the channel's lifetime, and `onEnd` fires when the read loop finishes
    /// — cleanly or not; the session turns that into `markClosed`.
    func openPTY(rows: Int, cols: Int,
                 onOutput: @escaping @Sendable (Data) -> Void,
                 onEnd: @escaping @Sendable () -> Void) async throws -> any SSHPTYWriter
    /// Tear the connection down; must also end an open PTY's read loop
    /// (which makes the session's `close()` race-free against `markClosed`).
    func shutdown() async
}

enum SSHExecInputError: Error {
    case unsupportedTransport
}

extension SSHClientTransport {
    // Scripted transports can ignore cancellation while producing their reply;
    // the late result must still never advance to the next upload phase.
    func run(_ command: String, cancellationScope: SSHChildChannelScope) async throws -> Data {
        try cancellationScope.checkCancellation()
        let result = try await run(command)
        try cancellationScope.checkCancellation()
        return result
    }

    // Test transports that only support ordinary exec must fail closed. Falling
    // back to a quoted argument would put sensitive stdin back into argv.
    func run(_ command: String, standardInput: Data) async throws -> Data {
        throw SSHExecInputError.unsupportedTransport
    }
}

/// The PTY stdin surface the session writes through.
protocol SSHPTYWriter: Sendable {
    func write(_ data: Data) async throws
    func resize(cols: Int, rows: Int) async throws
}

/// Production ``SSHClientTransport`` over a Citadel `SSHClient`.
final class CitadelClientTransport: SSHClientTransport {
    private let client: SSHClient

    init(client: SSHClient) {
        self.client = client
    }

    func run(_ command: String) async throws -> Data {
        let buffer = try await client.executeCommand(command, mergeStreams: true)
        return Data(buffer.readableBytesView)
    }

    func run(_ command: String, cancellationScope: SSHChildChannelScope) async throws -> Data {
        let buffer = try await client.executeCommand(command, mergeStreams: true,
                                                     cancellationScope: cancellationScope)
        return Data(buffer.readableBytesView)
    }

    func run(_ command: String, standardInput: Data) async throws -> Data {
        var result = Data()
        var receivedEOF = false
        do {
            try await client.withExec(command) { inbound, outbound in
                try await outbound.write(ByteBuffer(bytes: standardInput))
                for try await chunk in inbound {
                    switch chunk {
                    case .stdout(let bytes), .stderr(let bytes):
                        result.append(contentsOf: bytes.readableBytesView)
                    }
                }
                receivedEOF = true
            }
        } catch let error as ChannelError where error == .alreadyClosed && receivedEOF {
            // The server can close after EOF before withExec's own close.
        }
        return result
    }

    func openPTY(rows: Int, cols: Int,
                 onOutput: @escaping @Sendable (Data) -> Void,
                 onEnd: @escaping @Sendable () -> Void) async throws -> any SSHPTYWriter {
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        // Ask for a UTF-8 locale on the remote PTY, same value the mosh
        // bootstrap forwards (`-l LANG=…`). Without it many Linux hosts start
        // the session in the C locale and CJK input/output turns into
        // mojibake ("？？？"/<ffff>) — the classic "输入中文乱码" report.
        // OpenSSH accepts LANG by default (`AcceptEnv LANG LC_*`); servers
        // that refuse env requests just ignore this (wantReply: false).
        let environment = [
            SSHChannelRequestEvent.EnvironmentRequest(
                wantReply: false, name: "LANG", value: "en_US.UTF-8")
        ]

        // Handshake: return only after Citadel has accepted the PTY request
        // and handed us a writer, while the surrounding read loop keeps
        // running for the lifetime of the session. Bridged with a
        // CheckedContinuation; closing the client breaks `withPTY`'s read
        // loop, so no Task handle needs holding for cancellation.
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<any SSHPTYWriter, Error>) in
            Task { [client] in
                var resumed = false
                do {
                    try await client.withPTY(request, environment: environment) { output, writer in
                        if !resumed {
                            resumed = true
                            continuation.resume(returning: CitadelPTYWriter(writer: writer))
                        }
                        do {
                            for try await chunk in output {
                                let buffer: ByteBuffer
                                switch chunk {
                                case .stdout(let buf): buffer = buf
                                case .stderr(let buf): buffer = buf
                                }
                                let bytes = Array(buffer.readableBytesView)
                                if !bytes.isEmpty {
                                    onOutput(Data(bytes))
                                }
                            }
                        } catch {
                            // Read loop ended in error — fall through to onEnd.
                        }
                    }
                } catch {
                    if !resumed {
                        resumed = true
                        continuation.resume(throwing: error)
                    }
                }
                onEnd()
            }
        }
    }

    func shutdown() async {
        try? await client.close()
    }
}

private struct CitadelPTYWriter: SSHPTYWriter {
    let writer: TTYStdinWriter

    func write(_ data: Data) async throws {
        var buffer = ByteBuffer()
        buffer.writeBytes(data)
        try await writer.write(buffer)
    }

    func resize(cols: Int, rows: Int) async throws {
        try await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
    }
}

// MARK: - SSHService

/// Only allowlisted routing/stage metadata crosses the diagnostic boundary.
/// In particular, neither an Error's description nor a saved transportRaw
/// value is suitable for the user's exportable recent log.
struct SSHConnectionDiagnostic: Sendable {
    enum Phase: String, Sendable {
        case transportValidation = "transport-validation"
        case cloudflareAccess = "cloudflare-access"
        case tailcatCredential = "tailcat-credential"
        case tailscaleAccount = "tailscale-account"
        case sshCredential = "ssh-credential"
        case authenticationMethod = "authentication-method"
        case transportDial = "transport-dial"
        case sshAuthentication = "ssh-authentication"
        // Citadel's direct connect combines TCP dial and SSH authentication.
        case directSSHConnect = "direct-ssh-connect"
    }
    enum Outcome: String, Sendable { case started, succeeded, failed }

    let attemptID: UUID
    let connectionID: UUID
    let route: ConnectionTransport?
    let phase: Phase
    let outcome: Outcome
    let errorClass: String?

    var context: String { "conn=\(connectionID.uuidString) route=\(route?.rawValue ?? "unknown")" }
    var message: String {
        "ssh[\(attemptID.uuidString)] \(context) phase=\(phase.rawValue) result=\(outcome.rawValue)"
            + (errorClass.map { " error=\($0)" } ?? "")
    }

    static func classify(_ error: Error) -> String {
        if let ssh = error as? SSHError {
            switch ssh {
            case .underlying(let nested): return classify(nested)
            case .missingKeychainRef: return "ssh.missing-keychain-ref"
            case .missingSecret: return "ssh.missing-secret"
            case .unsupportedKeyType: return "ssh.unsupported-key-type"
            case .credentialUnavailable: return "ssh.credential-unavailable"
            case .authenticationFailed: return "ssh.authentication-failed"
            case .authMethodRejected: return "ssh.auth-method-rejected"
            case .handshakeFailed: return "ssh.handshake-failed"
            case .connectionFailed: return "ssh.connection-failed"
            case .channelOpenFailed: return "ssh.channel-open-failed"
            case .sessionClosed: return "ssh.session-closed"
            case .ptyAlreadyOpen, .ptyNotReady: return "ssh.pty-state"
            }
        }
        if let auth = error as? CloudflareAuthError {
            switch auth {
            case .loginRequired: return "cloudflare-auth.login-required"
            case .cancelled: return "cloudflare-auth.cancelled"
            case .presentationUnavailable: return "cloudflare-auth.presentation-unavailable"
            case .credentialStorage: return "cloudflare-auth.credential-storage"
            }
        }
        if let access = error as? AccessError {
            switch access {
            case .expiredToken: return "access.expired-token"
            case .httpStatus(let code): return "access.http-\(code)"
            case .networkFailure: return "access.network-failure"
            case .deadlineExceeded: return "access.deadline-exceeded"
            case .wrongAudience: return "access.wrong-audience"
            case .wrongIssuer: return "access.wrong-issuer"
            case .invalidSignature: return "access.invalid-signature"
            case .invalidClaims: return "access.invalid-claims"
            case .invalidToken: return "access.invalid-token"
            case .userIdentityRequired: return "access.user-identity-required"
            default: return "access.validation-failed"
            }
        }
        if let transport = error as? CloudflareSSHTransportError {
            switch transport {
            case .invalidEndpoint: return "cloudflare.invalid-endpoint"
            case .invalidCredential: return "cloudflare.invalid-credential"
            case .deadlineExceeded: return "cloudflare.deadline-exceeded"
            case .httpStatus(let code): return "cloudflare.http-\(code)"
            case .dnsFailure(let code): return "cloudflare.dns-\(code.map(String.init) ?? "unknown")"
            case .socketFailure(let code): return "cloudflare.socket-\(code.map(String.init) ?? "unknown")"
            case .tlsFailure(let reason): return "cloudflare.tls-\(reason.rawValue)"
            case .connectionClosed: return "cloudflare.connection-closed"
            case .heartbeatTimedOut: return "cloudflare.heartbeat-timeout"
            case .heartbeatWriteTimedOut: return "cloudflare.heartbeat-write-timeout"
            case .upgradeFailed: return "cloudflare.upgrade-failed"
            case .unsupportedWebSocketOptions: return "cloudflare.unsupported-websocket-options"
            case .invalidWebSocketFrame: return "cloudflare.invalid-websocket-frame"
            case .textFrameUnsupported: return "cloudflare.text-frame-unsupported"
            case .bufferLimitExceeded: return "cloudflare.buffer-limit"
            }
        }
        if error is ConnectionTransportError { return "transport.invalid-configuration" }
        if error is TailcatCredentialError { return "tailcat.credential" }
        if error is TailcatSSHTransportError { return "tailcat.transport" }
        if error is TailscaleAccountError { return "tailscale.account" }
        if error is TailscaleSSHTransportError { return "tailscale.transport" }
        if error is KeychainError { return "keychain.failure" }
        if error is HostKeyRejected { return "ssh.host-key-rejected" }
        if error is CancellationError { return "cancelled" }
        if let url = error as? URLError { return "url.code-\(url.code.rawValue)" }
        if let authentication = error as? SSHChannelAuthentication.Failure {
            return authentication == .timedOut ? "ssh.authentication-timeout" : "ssh.authentication-closed"
        }
        if error is SSHClientError { return classify(SSHError.map(error)) }
        if error is ChannelError { return "nio.channel" }
        return "unclassified"
    }
}

/// Top-level façade that resolves credentials, authenticates, and hands the
/// caller an `SSHSession`. The service holds the long-lived dependencies
/// (`KeychainService`, `HostKeyValidator`) so views/view-models only need
/// one reference.
actor SSHService {
    typealias TrustNewHostHandler = TOFUHostKeyDelegate.TrustNewHost
    typealias AcceptChangedHostHandler = TOFUHostKeyDelegate.AcceptChangedHost

    private let keychain: KeychainService
    private let validator: HostKeyValidator
    private let clientProvider: SSHClientProvider
    private let cloudflareAuth: CloudflareAccessAuth
    private let tailcatCredentials: TailcatCredentials
    private let tailscaleRuntime: TailscaleRuntime
    private let onConnectionDiagnostic: (@Sendable (SSHConnectionDiagnostic) -> Void)?

    /// In-memory credential cache, keyed by connection id. Populated after the
    /// first successful (biometry-gated) keychain read so the now-frequent
    /// auto-reconnects don't re-prompt Face ID on every attempt — and don't
    /// surface a keychain error mid-reconnect. Plaintext lives only in memory
    /// for the app session; cleared on intentional disconnect AND whenever the
    /// app backgrounds (see ``clearAllCachedSecrets()``).
    private var secretCache: [UUID: String] = [:]
    private var seBlobCache: [UUID: Data] = [:]

    /// Keychain reads currently in flight, keyed by connection id, so
    /// concurrent resolutions of the same connection share ONE read — and
    /// therefore one Face ID prompt. This actor is reentrant: without this,
    /// two `connect`s racing for the same connection both see an empty
    /// `secretCache`, both suspend into the keychain, and the user gets two
    /// biometry sheets for one tap. Not hypothetical — the mosh+tmux
    /// dual-transport design authenticates two SSH connections (bootstrap +
    /// `-CC` sidecar) with the same credential, and a parallel `resumeAll`
    /// resumes them together.
    private var secretResolutions: [UUID: Task<String, Error>] = [:]

    /// Forget a cached credential (called when the user disconnects), so the
    /// next connect re-authenticates against the keychain.
    func clearCachedSecret(for id: UUID) {
        secretCache[id] = nil
        seBlobCache[id] = nil
        // Detach (don't cancel) any in-flight read: connects already awaiting
        // it still get their value, but its result no longer lands in the
        // cache — see `resolveSecret`'s identity check.
        secretResolutions[id] = nil
    }

    /// Forget every cached credential. Called when the app backgrounds (see
    /// `SessionHub.setForeground(false)`) so the keychain's `.userPresence`
    /// "authenticate on every read" guarantee isn't silently downgraded to
    /// "once per app session" — without this, a decrypted password/PEM read
    /// once via Face ID would linger in process memory and get reused across
    /// backgroundings, with no re-authentication required on return. Clearing
    /// here only affects re-foreground: reconnects that happen while the app
    /// STAYS foregrounded still hit `secretCache`/`seBlobCache` and never
    /// re-prompt, exactly as before.
    func clearAllCachedSecrets() {
        secretCache.removeAll()
        seBlobCache.removeAll()
        // Same detach as `clearCachedSecret`: a read that finishes AFTER this
        // wipe must not repopulate the cache, or the background-wipe guarantee
        // ("authenticate on every read" survives backgrounding) is quietly
        // undone by whichever reconnect happened to be mid-keychain.
        secretResolutions.removeAll()
    }

    init(keychain: KeychainService,
         hostKeyValidator: HostKeyValidator,
         clientProvider: SSHClientProvider = CitadelSSHClientProvider(),
         tailcatCredentials: TailcatCredentials = .shared,
         tailscaleRuntime: TailscaleRuntime = .shared,
         cloudflareAuth: CloudflareAccessAuth = .shared,
         onConnectionDiagnostic: (@Sendable (SSHConnectionDiagnostic) -> Void)? = nil) {
        self.keychain = keychain
        self.validator = hostKeyValidator
        self.clientProvider = clientProvider
        self.cloudflareAuth = cloudflareAuth
        self.tailcatCredentials = tailcatCredentials
        self.tailscaleRuntime = tailscaleRuntime
        self.onConnectionDiagnostic = onConnectionDiagnostic
    }

    // MARK: - Connect

    /// Authenticates and returns an open SSH session. Caller is responsible
    /// for calling `session.requestPTY(rows:cols:)` next.
    ///
    /// `overrideSecret` lets callers bypass the keychain (useful for the
    /// "Test connection" button in the add-connection form, before the
    /// credential is persisted).
    ///
    /// `onUnknownHost`/`onChangedHost` are the TOFU prompts for THIS
    /// handshake specifically, passed as parameters rather than read off
    /// mutable actor state. `SSHService.shared` is a process-wide singleton
    /// serving every concurrent session (plus background reconnect/keepalive
    /// and the mosh -CC sidecar), so a previous design that installed these
    /// via a separate `setHostKeyHandlers()` call before `connect()` had a
    /// window — between one session's install and its own connect — where a
    /// DIFFERENT session's concurrent install-then-connect could land in
    /// between and silently steal (or hand out) the handler for the wrong
    /// handshake. Threading them through the call itself makes that
    /// impossible: each `connect()` call is self-contained. Both default to
    /// "deny" so a caller that forgets to wire real UI never silently
    /// auto-trusts an unknown or changed host key.
    func connect(_ connection: ServerConnection,
                 overrideSecret: String? = nil,
                 onUnknownHost: @escaping TrustNewHostHandler = { _, _, _ in false },
                 onChangedHost: @escaping AcceptChangedHostHandler = { _, _, _, _ in false }) async throws -> SSHSession {
        let attemptID = UUID()
        let route = connection.transport
        var phase = SSHConnectionDiagnostic.Phase.transportValidation
        func record(_ outcome: SSHConnectionDiagnostic.Outcome, error: Error? = nil) {
            let event = SSHConnectionDiagnostic(attemptID: attemptID, connectionID: connection.id,
                route: route, phase: phase, outcome: outcome, errorClass: error.map(SSHConnectionDiagnostic.classify))
            Log.ssh.notice("\(event.message, privacy: .public)")
            onConnectionDiagnostic?(event)
        }
        do {
            let session = try await connectImplementation(connection, overrideSecret: overrideSecret,
                onUnknownHost: onUnknownHost, onChangedHost: onChangedHost, diagnosticID: attemptID.uuidString,
                diagnosticContext: "conn=\(connection.id.uuidString) route=\(route?.rawValue ?? "unknown")",
                onPhase: { next in phase = next; record(.started) })
            record(.succeeded)
            return session
        } catch {
            // Includes validation/Access/keychain errors before the existing
            // transport catch. Logging must not change their error semantics.
            record(.failed, error: error)
            throw error
        }
    }

    private func connectImplementation(_ connection: ServerConnection,
                 overrideSecret: String?,
                 onUnknownHost: @escaping TrustNewHostHandler,
                 onChangedHost: @escaping AcceptChangedHostHandler,
                 diagnosticID: String, diagnosticContext: String,
                 onPhase: (SSHConnectionDiagnostic.Phase) -> Void) async throws -> SSHSession {
        // Validate before reading SSH keys or touching the network. Unknown
        // transport values and Cloudflare+Mosh must never fall back to direct.
        onPhase(.transportValidation)
        let transport = try connection.validatedTransport()
        let accessToken: String?
        if case .cloudflare(let settings) = transport {
            onPhase(.cloudflareAccess)
            accessToken = try await cloudflareAuth.credentials(settings: settings).applicationToken
        } else {
            accessToken = nil
        }
        let tailcatCredential: TailcatCredential?
        if case .tailcat(let settings) = transport {
            onPhase(.tailcatCredential)
            let credential = try await tailcatCredentials.load(ref: settings.credentialRef)
            guard credential.serverPublicKey == settings.serverPublicKey else {
                throw SSHError.credentialUnavailable
            }
            tailcatCredential = credential
        } else {
            tailcatCredential = nil
        }
        let tailscaleConnection: TailscalePreparedConnection?
        if case .tailscale(let settings) = transport {
            onPhase(.tailscaleAccount)
            tailscaleConnection = try await tailscaleRuntime.prepare(settings: settings, host: connection.host)
        } else {
            tailscaleConnection = nil
        }
        try Task.checkCancellation()
        let authMethod: SSHAuthenticationMethod
        onPhase(.sshCredential)
        if connection.authMethod == .key, connection.sshKeyAlgorithm == .seP256 {
            // Secure Enclave key: the keychain blob is the key's
            // dataRepresentation (an enclave handle), not PEM. Signing runs
            // inside the chip via NIOSSH's native SE support.
            guard let ref = connection.keychainRef else { throw SSHError.missingKeychainRef }
            let blob: Data
            if let cached = seBlobCache[connection.id] {
                blob = cached
            } else {
                do {
                    blob = try await keychain.loadSecret(
                        forRef: ref,
                        reason: "Authenticate to use the Secure Enclave key for \(connection.host)")
                } catch {
                    throw SSHError.credentialUnavailable
                }
                seBlobCache[connection.id] = blob
            }
            onPhase(.authenticationMethod)
            do {
                let seKey = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)
                authMethod = .custom(SecureEnclaveP256AuthDelegate(
                    username: connection.username, key: seKey))
            } catch {
                throw SSHError.underlying(error)
            }
        } else {
            let secret = try await resolveSecret(for: connection, override: overrideSecret)
            onPhase(.authenticationMethod)
            authMethod = try makeAuthMethod(connection: connection, secret: secret)
        }

        // A Tailcat alias is only a display name. Pin SSH trust to the remote
        // node identity so two servers named "mac-mini" never share trust.
        let hostKeyIdentity: String
        if case .tailcat(let settings) = transport {
            hostKeyIdentity = settings.hostKeyIdentity
        } else if let tailscaleConnection {
            hostKeyIdentity = tailscaleConnection.hostKeyIdentity
        } else {
            hostKeyIdentity = connection.host
        }
        let displayHost = connection.host
        let delegate = TOFUHostKeyDelegate(
            validator: validator,
            host: hostKeyIdentity,
            port: connection.port,
            onNewHost: { _, port, fingerprint in
                await onUnknownHost(displayHost, port, fingerprint)
            },
            onChangedHost: { _, port, newFingerprint, oldFingerprint in
                await onChangedHost(displayHost, port, newFingerprint, oldFingerprint)
            }
        )
        let hostKeyValidator = SSHHostKeyValidator.custom(delegate)

        do {
            let client: SSHClient
            onPhase(.transportDial)
            // SOCKS proxies only speak TCP CONNECT — this affects the SSH
            // dial only. If Mosh is also on, its UDP session still connects
            // directly once SSH bootstraps it; the Add Connection form's
            // PROXY footer says so up front rather than let that surface as
            // a silent post-handshake failure.
            switch transport {
            case .socks5(let proxyHost, let proxyPort):
                let channel = try await SOCKSProxyDialer.connect(
                    proxyHost: proxyHost,
                    proxyPort: proxyPort,
                    targetHost: connection.host,
                    targetPort: connection.port
                )
                do {
                    onPhase(.sshAuthentication)
                    client = try await clientProvider.connect(
                        on: channel,
                        authenticationMethod: authMethod,
                        hostKeyValidator: hostKeyValidator
                    )
                    try Task.checkCancellation()
                    try await SOCKSProxyDialer.completeHandoff(on: channel)
                    try Task.checkCancellation()
                } catch {
                    try? await channel.close()
                    throw error
                }
            case .cloudflare(let settings):
                let endpoint = URL(string: "wss://" + settings.hostname + "/")!
                // Correlate only typed phases and monotonic times, never the
                // endpoint, credentials, terminal bytes or peer close text.
                let tunnel: CloudflareSSHConnection
                do {
                    tunnel = try await CloudflareSSHDialer().connect(
                        endpoint: endpoint, accessToken: accessToken,
                        on: MultiThreadedEventLoopGroup.singleton,
                        onDiagnostic: { event in
                            let kind = String(describing: event.kind)
                            switch event.kind {
                            case .pingQueued, .pingSent, .pongReceived:
                                Log.ssh.debug("cloudflare[\(diagnosticID, privacy: .public)] \(diagnosticContext, privacy: .public) +\(event.elapsedMilliseconds)ms \(kind, privacy: .public)")
                            default:
                                Log.ssh.notice("cloudflare[\(diagnosticID, privacy: .public)] \(diagnosticContext, privacy: .public) +\(event.elapsedMilliseconds)ms \(kind, privacy: .public)")
                            }
                        })
                } catch {
                    if let failure = error as? CloudflareSSHTransportError,
                       case .httpStatus(let code) = failure,
                       [301, 302, 303, 307, 308, 401, 403].contains(code) {
                        await cloudflareAuth.invalidate(settings: settings)
                    }
                    throw error
                }
                do {
                    onPhase(.sshAuthentication)
                    client = try await clientProvider.connect(
                        on: tunnel.channel, authenticationMethod: authMethod,
                        hostKeyValidator: hostKeyValidator)
                    try await SSHChannelAuthentication.complete(on: tunnel.channel) {
                        try await tunnel.activate()
                    }
                    Log.ssh.notice("cloudflare[\(diagnosticID, privacy: .public)] \(diagnosticContext, privacy: .public) SSH authenticated")
                    try Task.checkCancellation()
                } catch {
                    let diagnostics = tunnel.diagnostics
                    let failure = SSHError.preservingCloudflareSetupCause(error,
                        firstTermination: diagnostics.firstTermination?.kind,
                        firstFailure: diagnostics.firstFailure)
                    let cause = String(describing: diagnostics.firstTermination?.kind)
                    Log.ssh.notice("cloudflare[\(diagnosticID, privacy: .public)] \(diagnosticContext, privacy: .public) SSH setup ended; first transport termination=\(cause, privacy: .public)")
                    await tunnel.close()
                    throw failure
                }
            case .tailcat:
                guard let credential = tailcatCredential else {
                    throw SSHError.credentialUnavailable
                }
                let tunnel = try await TailcatSSHDialer().connect(
                    address: credential.address,
                    clientKey: credential.clientPrivateKey,
                    port: connection.port,
                    on: MultiThreadedEventLoopGroup.singleton,
                    onDiagnostic: { event in
                        let kind = event.kind.rawValue
                        Log.ssh.notice("tailcat[\(diagnosticID, privacy: .public)] \(diagnosticContext, privacy: .public) +\(event.elapsedMilliseconds)ms \(kind, privacy: .public)")
                    })
                do {
                    onPhase(.sshAuthentication)
                    client = try await clientProvider.connect(
                        on: tunnel.channel, authenticationMethod: authMethod,
                        hostKeyValidator: hostKeyValidator)
                    try await SSHChannelAuthentication.complete(on: tunnel.channel) {
                        try await tunnel.activate()
                    }
                    Log.ssh.notice("tailcat[\(diagnosticID, privacy: .public)] \(diagnosticContext, privacy: .public) SSH authenticated")
                    try Task.checkCancellation()
                } catch {
                    await tunnel.close()
                    throw error
                }
            case .tailscale:
                guard let prepared = tailscaleConnection, let node = prepared.client.nativeNode else {
                    throw TailscaleAccountError.loginRequired
                }
                let tunnel = try await TailscaleSSHDialer().connect(
                    node: node, host: prepared.host, port: connection.port,
                    on: MultiThreadedEventLoopGroup.singleton,
                    onDiagnostic: { event in
                        Log.ssh.notice("tailscale[\(diagnosticID, privacy: .public)] \(diagnosticContext, privacy: .public) +\(event.elapsedMilliseconds)ms \(event.kind.rawValue, privacy: .public)")
                    })
                do {
                    onPhase(.sshAuthentication)
                    client = try await clientProvider.connect(
                        on: tunnel.channel, authenticationMethod: authMethod,
                        hostKeyValidator: hostKeyValidator)
                    try await SSHChannelAuthentication.complete(on: tunnel.channel) {
                        try await tunnel.activate()
                    }
                    Log.ssh.notice("tailscale[\(diagnosticID, privacy: .public)] \(diagnosticContext, privacy: .public) SSH authenticated")
                    try Task.checkCancellation()
                } catch {
                    await tunnel.close()
                    throw error
                }
            case .direct:
                onPhase(.directSSHConnect)
                client = try await clientProvider.connect(
                    host: connection.host,
                    port: connection.port,
                    authenticationMethod: authMethod,
                    hostKeyValidator: hostKeyValidator
                )
            }
            return SSHSession(connection: connection, client: client)
        } catch {
            throw SSHError.map(error)
        }
    }

    // MARK: - Helpers

    private func resolveSecret(for connection: ServerConnection,
                               override: String?) async throws -> String {
        if let override { return override }
        if let cached = secretCache[connection.id] { return cached }
        // Join a read already in flight instead of starting a second one —
        // this is what keeps one user action at one Face ID prompt when two
        // connects race for the same connection (see `secretResolutions`).
        if let inFlight = secretResolutions[connection.id] {
            return try await inFlight.value
        }
        guard let ref = connection.keychainRef else {
            throw SSHError.missingKeychainRef
        }
        let keychain = self.keychain
        let task = Task<String, Error> {
            do {
                switch connection.authMethod {
                case .password:
                    return try await keychain.loadPassword(forRef: ref,
                                                           reason: "Authenticate to connect to \(connection.host)")
                case .key:
                    return try await keychain.loadPrivateKey(forRef: ref,
                                                             reason: "Authenticate to use SSH key for \(connection.host)")
                }
            } catch is KeychainError {
                // Item missing / unreadable (often after a re-sign) → actionable.
                throw SSHError.credentialUnavailable
            }
        }
        secretResolutions[connection.id] = task
        do {
            let secret = try await task.value
            // Cache only if this read is still the registered one. A background
            // wipe (`clearAllCachedSecrets`) between start and finish detaches
            // it, and a late write here would silently undo the wipe.
            if secretResolutions[connection.id] == task {
                secretResolutions[connection.id] = nil
                secretCache[connection.id] = secret
            }
            return secret
        } catch {
            // A failed read must not pin the failure: the next attempt gets a
            // fresh keychain call (and a fresh prompt) rather than this error.
            if secretResolutions[connection.id] == task {
                secretResolutions[connection.id] = nil
            }
            throw error
        }
    }

    private func makeAuthMethod(connection: ServerConnection,
                                secret: String) throws -> SSHAuthenticationMethod {
        switch connection.authMethod {
        case .password:
            return .passwordBased(username: connection.username, password: secret)

        case .key:
            let keyType: SSHKeyType
            do {
                keyType = try SSHKeyDetection.detectPrivateKeyType(from: secret)
            } catch {
                throw SSHError.underlying(error)
            }

            switch keyType {
            case .rsa:
                do {
                    let rsa = try Insecure.RSA.PrivateKey(sshRsa: secret)
                    return .rsa(username: connection.username, privateKey: rsa)
                } catch {
                    throw SSHError.underlying(error)
                }
            case .ed25519:
                do {
                    let key = try Curve25519.Signing.PrivateKey(sshEd25519: secret)
                    return .ed25519(username: connection.username, privateKey: key)
                } catch {
                    throw SSHError.underlying(error)
                }
            case .ecdsaP256:
                do {
                    let key = try OpenSSHECDSAKey.p256PrivateKey(fromPEM: secret)
                    return .p256(username: connection.username, privateKey: key)
                } catch {
                    throw SSHError.underlying(error)
                }
            default:
                // ECDSA P-384/P-521 PEM loading still TODO; ECDSA-sk lives on
                // a hardware token and cannot be loaded at all.
                throw SSHError.unsupportedKeyType(keyType.description)
            }
        }
    }
}

// MARK: - ECDSA-P256 OpenSSH parsing

/// Parses a P-256 private key out of an openssh-key-v1 container — the
/// counterpart Citadel doesn't provide (its own key-type enum only knows
/// "ssh-rsa" and "ssh-ed25519"; there's no ECDSA reader to reuse). Only
/// unencrypted (cipher "none") containers are supported, matching what
/// `SSHKeyFactory` produces and what the ed25519/RSA paths above already
/// assume. Format reference: https://dnaeon.github.io/openssh-private-key-binary-format/
private enum OpenSSHECDSAKey {
    enum ParseError: LocalizedError {
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .malformed(let why): return "Malformed OpenSSH private key: \(why)"
            }
        }
    }

    /// Sequential reader for the SSH wire format (uint32 length-prefixed
    /// strings) — distinct from ASN.1 DER, which `SSHKeyFactory`'s reader
    /// handles; this container is entirely SSH-native framing.
    private struct WireReader {
        private let data: Data
        private var idx: Data.Index

        init(_ data: Data) {
            self.data = data
            self.idx = data.startIndex
        }

        mutating func readUInt32() -> UInt32? {
            guard let bytes = readBytes(4) else { return nil }
            return bytes.reduce(0 as UInt32) { ($0 << 8) | UInt32($1) }
        }

        mutating func readBytes(_ count: Int) -> Data? {
            guard count >= 0, data.distance(from: idx, to: data.endIndex) >= count else { return nil }
            let slice = data[idx..<data.index(idx, offsetBy: count)]
            idx = data.index(idx, offsetBy: count)
            return Data(slice)
        }

        mutating func readSSHString() -> Data? {
            guard let length = readUInt32() else { return nil }
            return readBytes(Int(length))
        }
    }

    static func p256PrivateKey(fromPEM pem: String) throws -> P256.Signing.PrivateKey {
        var text = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        let begin = "-----BEGIN OPENSSH PRIVATE KEY-----"
        let end = "-----END OPENSSH PRIVATE KEY-----"
        guard text.hasPrefix(begin), text.hasSuffix(end) else {
            throw ParseError.malformed("missing OpenSSH PEM boundary")
        }
        text.removeLast(end.count)
        text.removeFirst(begin.count)
        guard let raw = Data(base64Encoded: text.replacingOccurrences(of: "\n", with: "")) else {
            throw ParseError.malformed("invalid base64 payload")
        }

        var reader = WireReader(raw)
        guard reader.readBytes(15) == Data("openssh-key-v1\0".utf8) else {
            throw ParseError.malformed("missing openssh-key-v1 magic")
        }
        guard reader.readSSHString() == Data("none".utf8) else {
            throw ParseError.malformed("encrypted OpenSSH keys are not supported")
        }
        guard reader.readSSHString() == Data("none".utf8) else {
            throw ParseError.malformed("encrypted OpenSSH keys are not supported")
        }
        guard let kdfOptions = reader.readSSHString(), kdfOptions.isEmpty else {
            throw ParseError.malformed("unexpected KDF options")
        }
        guard reader.readUInt32() == 1 else {
            throw ParseError.malformed("expected exactly one key in the container")
        }
        guard reader.readSSHString() != nil else {   // public key blob — re-derived below instead of trusted
            throw ParseError.malformed("missing public key blob")
        }
        guard let privBlob = reader.readSSHString() else {
            throw ParseError.malformed("missing private key blob")
        }

        var priv = WireReader(privBlob)
        guard let check0 = priv.readUInt32(), priv.readUInt32() == check0 else {
            throw ParseError.malformed("private key checksum mismatch")
        }
        guard priv.readSSHString() == Data("ecdsa-sha2-nistp256".utf8) else {
            throw ParseError.malformed("not an ecdsa-sha2-nistp256 key")
        }
        guard priv.readSSHString() == Data("nistp256".utf8) else {
            throw ParseError.malformed("unsupported curve — only nistp256 is handled here")
        }
        guard priv.readSSHString() != nil else {   // public point Q — re-derived below instead of trusted
            throw ParseError.malformed("missing public key point")
        }
        guard let scalarMPInt = priv.readSSHString() else {
            throw ParseError.malformed("missing private scalar")
        }

        return try P256.Signing.PrivateKey(rawRepresentation: fixedLength(fromMPInt: scalarMPInt, length: 32))
    }

    /// Inverse of the `sshMPInt` encoding `SSHKeyFactory` writes: mpint
    /// encoding strips leading zero bytes from the big-endian integer (and
    /// adds one back only as a sign guard when the high bit is set), so the
    /// body isn't reliably exactly 32 bytes — this restores that fixed width.
    private static func fixedLength(fromMPInt mpint: Data, length: Int) -> Data {
        var bytes = mpint
        if bytes.count > length, bytes.first == 0 {
            bytes.removeFirst()
        }
        if bytes.count < length {
            bytes = Data(repeating: 0, count: length - bytes.count) + bytes
        }
        return bytes
    }
}

// MARK: - Secure Enclave auth delegate

/// Offers a Secure Enclave P-256 key for publickey auth. NIOSSH signs via the
/// enclave (`NIOSSHPrivateKey(secureEnclaveP256Key:)`); the private key never
/// leaves the chip. One attempt — if the server rejects it, auth fails.
private final class SecureEnclaveP256AuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let key: SecureEnclave.P256.Signing.PrivateKey
    private var attempted = false

    init(username: String, key: SecureEnclave.P256.Signing.PrivateKey) {
        self.username = username
        self.key = key
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !attempted, availableMethods.contains(.publicKey) else {
            nextChallengePromise.succeed(nil)   // no further methods → clean failure
            return
        }
        attempted = true
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "",
            offer: .privateKey(.init(privateKey: NIOSSHPrivateKey(secureEnclaveP256Key: key)))))
    }
}

#if DEBUG
extension SSHService {
    /// Harness-only: commit a TOFU decision up front so a scripted run
    /// (simulator without a tap tool) reaches the terminal without the
    /// New Host card. Same store the card's Trust button writes.
    func preTrustHostKey(host: String, port: Int, fingerprint: String) async {
        await validator.trust(host: host, port: port, fingerprint: fingerprint)
    }
}
#endif

// MARK: - Shared instance

extension SSHService {
    /// Process-wide default service used by views/view-models that don't
    /// otherwise inject one. Backed by the default ``KeychainService`` and
    /// ``HostKeyValidator`` so it pulls from the real keychain + known-hosts
    /// store. Tests should construct their own ``SSHService`` with mocks
    /// rather than touching this singleton.
    static let shared: SSHService = {
        let kc = KeychainService()
        let hkv = HostKeyValidator()
        return SSHService(keychain: kc, hostKeyValidator: hkv)
    }()
}

// MARK: - Exec-channel upload commands

/// The command lines for the no-SFTP upload fallback. Pure builders, unit
/// tested — a quoting bug here writes bytes to the wrong path on someone
/// else's server, so every path goes through one shell-quoter and the tests
/// pin the exact strings.
///
/// Strict POSIX sh: the exec channel runs a non-login shell on whatever
/// /bin/sh the host has (see HostCapabilities' PATH notes), and `base64 -d`
/// vs `-D` differs across ages of BSD — the finish line tries both orders.
enum ExecUploadCommands {
    /// Raw bytes per exec round trip. 48KB of payload is 64KB of base64 —
    /// comfortably inside every sshd/shell argument limit encountered in
    /// the wild, while keeping a 2MB image to ~45 round trips.
    static let chunkBytes = 48 * 1024

    static let successMarker = "MOSHPIT_UPLOAD_OK"

    struct Plan {
        let begin: String
        let append: (String) -> String
        let finish: String
        let finalPath: String
    }

    static func plan(home: String, filename: String) -> Plan {
        let dirParent = home + "/.moshpit"
        let dir = dirParent + "/uploads"
        let finalPath = dir + "/" + filename
        let tempPath = finalPath + ".b64part"
        let qDirParent = quote(dirParent), qDir = quote(dir)
        let qFinal = quote(finalPath), qTemp = quote(tempPath)
        return Plan(
            begin: "mkdir -p \(qDir) && chmod 700 \(qDirParent) \(qDir) && rm -f \(qTemp)",
            // The base64 alphabet (A–Za–z0–9+/=) is inert inside single
            // quotes — no escaping needed for the payload itself.
            append: { chunk in "printf %s '\(chunk)' >> \(qTemp)" },
            finish: "{ base64 -d < \(qTemp) > \(qFinal) 2>/dev/null"
                + " || base64 -D < \(qTemp) > \(qFinal); }"
                + " && chmod 600 \(qFinal) && rm -f \(qTemp) && echo \(successMarker)",
            finalPath: finalPath)
    }

    /// POSIX single-quoting: close, escaped quote, reopen. The only
    /// character that needs anything is the quote itself.
    static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// A host file held open over SFTP (`SSHSession.openRemoteFile`). Reads may
/// overlap — each is its own request on the wire. Closed by whoever opened
/// it, or with the session.
final class RemoteFileHandle: @unchecked Sendable {
    let size: UInt64
    private let file: SFTPFile

    fileprivate init(file: SFTPFile, size: UInt64) {
        self.file = file
        self.size = size
    }

    /// At most `length` bytes from `offset` (OpenSSH answers 255 KiB at the
    /// most); empty at the end of the file.
    func read(from offset: UInt64, length: UInt32) async throws -> [UInt8] {
        var buffer = try await file.read(from: offset, length: length)
        return buffer.readBytes(length: buffer.readableBytes) ?? []
    }

    func close() async {
        try? await file.close()
    }
}
