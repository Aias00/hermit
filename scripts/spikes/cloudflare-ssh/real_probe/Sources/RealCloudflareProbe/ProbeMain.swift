import CloudflareAccess
import CloudflareSSH
import Darwin
import Dispatch
import Foundation
import NIOCore

/// Machine-readable output contains only fixed event names, bounded counts,
/// and local file paths. Neither error reflection nor credential descriptions
/// are ever sent to stdout/stderr.
func emit(_ event: String, _ fields: [String: Any] = [:]) {
    var output = fields
    output["event"] = event
    guard var data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) else { return }
    data.append(10)
    FileHandle.standardOutput.write(data)
}

@main
enum ProbeMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] || arguments == ["-h"] {
            FileHandle.standardOutput.write(Data((Options.usage + "\n").utf8))
            return
        }
        if arguments == ["--self-check"] {
            do { try selfCheck(); emit("self_check_passed") }
            catch { report(error); exit(1) }
            return
        }
        do {
            let options = try Options(arguments: arguments)
            let operation = Task { try await run(options) }
            // Interruptions cancel polling/dialing and run cleanup. Never
            // print task/error objects that could include an ephemeral URL.
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)
            let signals = [SIGINT, SIGTERM].map { number in
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler { operation.cancel() }
                source.resume()
                return source
            }
            defer { for source in signals { source.cancel() } }
            try await operation.value
        } catch { report(error); exit(1) }
    }

    private static func run(_ options: Options) async throws {
        if options.anonymousTransport {
            guard let audience = options.audience else { throw ProbeError.invalidArguments }
            // Construction validates only public scope; no metadata lookup,
            // Keychain, file credential, login transfer or browser is involved.
            let application = try AccessApplication(hostname: options.hostname,
                audience: audience, teamDomain: options.teamDomain)
            try await AnonymousTransportProbe.run(hostname: application.hostname)
            return
        }
        let http = URLSessionAccessHTTPClient()
        let application: AccessApplication
        if let audience = options.audience {
            application = try AccessApplication(hostname: options.hostname, audience: audience, teamDomain: options.teamDomain)
        } else {
            emit("verifying_application_metadata")
            application = try await AccessApplicationDiscovery.discover(hostname: options.hostname,
                teamDomain: options.teamDomain, using: http)
            emit("application_metadata_verified")
        }

        let credentials: AccessCredentials
        if let path = options.reuseCredentials {
            emit("revalidating_saved_credentials")
            let saved = try JSONDecoder().decode(AccessCredentials.self, from: PrivateFile.read(path))
            credentials = try await AccessJWTValidator.validateCredentials(saved, for: application, using: http)
        } else {
            let directory = try PrivateFile.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let transfer = try AccessLoginTransfer(application: application)
            let page = directory.appendingPathComponent("login.html")
            try PrivateFile.writeNew(PrivateFile.loginPage(for: transfer.browserURL), to: page.path)
            emit("waiting_for_browser_login", ["login_html": page.path, "timeout_seconds": options.loginTimeout,
                                               "browser_opened_automatically": false])
            credentials = try await transfer.poll(using: http, timeout: .seconds(options.loginTimeout))
        }
        try Task.checkCancellation()
        emit("access_credentials_verified", ["source": options.reuseCredentials == nil ? "encrypted_transfer" : "private_file",
             "signature_verified": true, "issuer_verified": true, "audience_verified": true,
             "user_identity_present": !credentials.identity.subject.isEmpty,
             "valid_for_seconds": max(0, Int(credentials.identity.expiresAt.timeIntervalSinceNow))])
        if let path = options.saveCredentials {
            try PrivateFile.writeNew(JSONEncoder().encode(credentials), to: path)
            emit("credentials_saved", ["mode": "0600"])
        }
        if options.loginOnly {
            emit("login_probe_complete", ["wss_tested": false, "g2_complete": false])
            return
        }
        emit("connecting_wss")
        let banner = try await SSHBannerProbe.run(hostname: application.hostname, accessToken: credentials.applicationToken)
        emit("ssh_banner_verified", ["protocol_version": banner.protocolVersion,
             "identification_bytes": banner.identificationBytes, "ssh_host_key_verified": false,
             "g1_complete": false, "g2_complete": false])
    }

    private static func report(_ error: Error) {
        if error is CancellationError { emit("cancelled"); return }
        if let error = error as? AccessError {
            emit("failed", ["layer": "access", "message": error.localizedDescription])
        } else if let error = error as? CloudflareSSHTransportError {
            emit("failed", ["layer": "wss", "message": error.localizedDescription])
        } else if let error = error as? ProbeError {
            emit("failed", ["layer": "probe", "message": error.localizedDescription])
        } else {
            emit("failed", ["layer": "probe", "message": "Operation failed; raw diagnostics were suppressed."])
        }
    }

    private static func selfCheck() throws {
        let directory = try PrivateFile.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("private-test.json").path
        let expected = Data("non-secret-self-check".utf8)
        try PrivateFile.writeNew(expected, to: path)
        guard try PrivateFile.read(path) == expected else { throw ProbeError.privateFile }
        var rejectedExisting = false
        do { try PrivateFile.writeNew(expected, to: path) } catch ProbeError.privateFile { rejectedExisting = true }
        guard rejectedExisting else { throw ProbeError.privateFile }
        guard chmod(path, 0o644) == 0 else { throw ProbeError.privateFile }
        var rejectedPermissions = false
        do { _ = try PrivateFile.read(path) } catch ProbeError.privateFile { rejectedPermissions = true }
        guard rejectedPermissions else { throw ProbeError.privateFile }
        var parser = SSHBannerParser()
        guard try parser.consume(ByteBuffer(string: "notice\r\nSSH-2.")) == nil,
              let banner = try parser.consume(ByteBuffer(string: "0-test\r\n")),
              banner.protocolVersion == "2.0" else { throw ProbeError.invalidBanner }
        _ = try AccessApplication(hostname: "ssh.example.com", audience: "example-audience", teamDomain: "example.cloudflareaccess.com")
        let anonymous = ["--anonymous-transport", "--hostname", "ssh.example.com", "--team", "example.cloudflareaccess.com", "--aud", "synthetic-audience"]
        guard try Options(arguments: anonymous).anonymousTransport else { throw ProbeError.invalidArguments }
        for extra in [["--login-only"], ["--save-credentials", "/tmp/not-created"],
                      ["--reuse-credentials", "/tmp/not-read"], ["--login-timeout-seconds", "300"],
                      ["--anonymous-transport"]] {
            var rejected = false
            do { _ = try Options(arguments: anonymous + extra) } catch ProbeError.invalidArguments { rejected = true }
            guard rejected else { throw ProbeError.invalidArguments }
        }
        var missingAudienceRejected = false
        do { _ = try Options(arguments: Array(anonymous.dropLast(2))) }
        catch ProbeError.invalidArguments { missingAudienceRejected = true }
        guard missingAudienceRejected else { throw ProbeError.invalidArguments }
    }
}
