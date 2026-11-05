import Foundation
import Observation
import UIKit
import UserNotifications
import MoshpitKit

/// A cached device token does not establish that the current installation is
/// signed for APNs. Read the binary's entitlements before registering or pairing.
enum RemotePushCapability {
    static let environment: String? = {
        guard let url = Bundle.main.executableURL,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return environment(in: CloudSyncEntitlements.signedEntitlements(in: data))
    }()

    static func environment(in entitlements: [String: Any]?) -> String? {
        switch entitlements?["aps-environment"] as? String {
        case "development": return "sandbox"
        case "production": return "production"
        default: return nil
        }
    }

    static var unavailableMessage: String {
        String(localized: "当前安装版本支持连接期间的本地通知。离线推送需要启用推送权限的开发者签名版本。")
    }
}

/// Remote-push half of the Vibe Island control surface.
///
/// The local path — `AgentActivityMonitor` watching a live tmux channel — only
/// reaches a phone that is running Hermit with a session attached. iOS suspends
/// the app within seconds of it leaving the screen and kills the socket shortly
/// after, and no amount of local cleverness gets it back: nothing in the app is
/// executing to notice the agent asking. A push is the only mechanism iOS gives
/// for waking it, and Apple will only deliver one signed with this app's team
/// key — which is why a relay exists at all.
///
/// This service owns the phone's side of that arrangement:
///   * ask iOS for a device token
///   * mint per-connection pairing material: the end-to-end secret locally,
///     the send token at the relay (an HMAC over the routing facts; the relay
///     keeps nothing — see push-relay/token.go)
///   * keep those credentials fresh: a rotated device token or an ageing mint
///     re-mints, and the installer rewrites the host's conf on its next pass
///   * forget a host when the user unpairs — locally, by deleting the secret,
///     which is the only revocation a stateless relay needs the phone for
///
/// It deliberately does NOT handle the incoming notification: a pushed
/// notification carries the same category and `userInfo` a local one does, so
/// `AgentNotificationHandler` routes it through `AgentControlBridge` with no new
/// code. That equivalence is the reason T1 is small.
/// What the host-setup screen needs from the push side.
///
/// A protocol only so that screen's state machine is testable: pairing and
/// proving are the two paths where a wrong state costs the user a phone that
/// stays silent, and they cannot be exercised against real APNs in a unit test.
@MainActor
protocol PushCoordinating: AnyObject {
    var supportsRemotePush: Bool { get }
    /// Why this phone has no usable relay credential, if it has none. nil when
    /// the last mint succeeded.
    var lastRelayError: String? { get }
    func pair(connectionId: UUID, hostLabel: String, relayURL: String) async throws -> PushPairing
    /// The stored pairing for a connection, re-minted if its credential is
    /// missing, stale, or was issued for a device token this phone no longer
    /// has. nil when nothing is paired OR the credential cannot be minted right
    /// now (no device token yet) — a pairing that is not ready must never be
    /// written to a host.
    func ensureReady(connectionId: UUID) async -> PushPairing?
    func unpair(connectionId: UUID)
    func awaitSelfTest(nonce: String, timeout: Duration) async -> Bool
    func forgetSelfTest(nonce: String)
}

extension PushCoordinating {
    var supportsRemotePush: Bool { true }
}

@MainActor
@Observable
final class PushService: PushCoordinating {
    static let shared = PushService()

    /// The current APNs device token, hex. nil until iOS hands one over — which
    /// requires notification authorization AND network.
    private(set) var deviceToken: String?
    /// Last registration error.
    ///
    /// Read by the host-setup sheet's push section (`HostSetupModel.relayError`).
    /// It used to say "surfaced in Settings", which was the one thing it was not
    /// doing: four writers, zero readers, so the only value that could tell a
    /// user "your relay does not know this phone" was computed and dropped. That
    /// got heavier when foreground re-announcement became unconditional — every
    /// return to the app recomputes it. A property that claims to tell the user
    /// something and does not is worse than no property, which is the standard
    /// `postDeliveryFailure()` already set here.
    private(set) var lastError: String?

    private let tokenKey = "moshpit.push.deviceToken"
    private var syncPending = false

    private init() {
        deviceToken = UserDefaults.standard.string(forKey: tokenKey)
    }

    var pairings: [PushPairing] { PushPairingStore.read() }

    /// Which APNs environment this build's tokens belong to.
    ///
    /// A development-signed build (anything out of Xcode) gets a sandbox token;
    /// App Store and TestFlight builds get production ones. The one case this
    /// guess gets wrong — a TestFlight build installed over a development one —
    /// self-corrects at the relay, which retries the other host on
    /// BadDeviceToken and remembers the answer.
    var supportsRemotePush: Bool { AgentNotifications.ordinaryNotificationsEnabled && RemotePushCapability.environment != nil }
    var lastRelayError: String? { supportsRemotePush ? lastError : String(localized: "仅使用锁屏实时活动，普通推送已停用。") }

    nonisolated static var apnsEnvironment: String {
        RemotePushCapability.environment ?? "sandbox"
    }

    // MARK: - Token lifecycle

    /// This product uses silent Live Activity updates only. Unregister legacy
    /// ordinary APNs delivery even when an older installation enabled it.
    func registerForRemoteNotifications() {
        UIApplication.shared.unregisterForRemoteNotifications()
    }

    func handle(deviceToken data: Data) {
        guard AgentNotifications.ordinaryNotificationsEnabled else { return }
        let hex = data.moshpitHexString
        let changed = hex != deviceToken
        // A prefix only: enough to line up with the relay's own fingerprints in
        // a log, not enough to be usable as an address.
        Log.push.info("device token \(hex.prefix(8), privacy: .public)… changed=\(changed, privacy: .public)")
        deviceToken = hex
        UserDefaults.standard.set(hex, forKey: tokenKey)
        lastError = nil
        // Wake anything parked on the token — a first pair blocks here between
        // the permission prompt and its mint.
        for waiter in tokenWaiters.values { waiter.resume() }
        tokenWaiters.removeAll()
        if changed || syncPending {
            Task { await mintNeededPairings() }
        }
    }

    /// Wait briefly for iOS to hand over a device token, or give up.
    ///
    /// The first pair on a fresh install lands here: authorization was granted
    /// a breath ago, `registerForRemoteNotifications()` has been called, and
    /// the token arrives through the app delegate within a second or two. The
    /// same discipline as `awaitSelfTest`: removal from the dictionary is the
    /// single wake-up gate, so the continuation resumes exactly once.
    private func awaitDeviceToken(timeout: Duration = .seconds(10)) async -> String? {
        if let deviceToken { return deviceToken }
        let id = UUID()
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, !Task.isCancelled else { return }
            self.tokenWaiters.removeValue(forKey: id)?.resume()
        }
        await withCheckedContinuation { continuation in
            tokenWaiters[id] = continuation
        }
        timeoutTask.cancel()
        return deviceToken
    }

    @ObservationIgnored private var tokenWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func handleRegistrationFailure(_ error: Error) {
        Log.push.error("iOS refused to issue a device token: \(error.localizedDescription, privacy: .public)")
        // A simulator without a signed-in Apple ID fails here every launch, and
        // so does a build whose entitlements lack aps-environment. Record it
        // rather than logging into the void.
        lastError = error.localizedDescription
        syncPending = true
    }

    /// Re-mint every pairing whose credential is missing, stale, or was issued
    /// for a device token this phone no longer has. Called on token change,
    /// after pairing, and on return to foreground.
    ///
    /// There is nothing to "announce" any more — the relay keeps no registry —
    /// so a healthy pairing costs zero requests here. The installer notices an
    /// updated credential by conf digest and rewrites the host's file on its
    /// next pass.
    func mintNeededPairings() async {
        guard supportsRemotePush, AppSettings.shared.notificationsEnabled else { return }
        guard let token = deviceToken else {
            Log.push.info("mint deferred — no device token yet")
            syncPending = true
            return
        }
        // Two overlapping runs cannot corrupt anything (both are on the main
        // actor) but they can interleave, so the surviving `lastError` comes from
        // whichever finished last rather than whichever ran last. One at a time.
        guard !syncInFlight else { return }
        syncInFlight = true
        defer { syncInFlight = false }
        var failed = false
        for pairing in pairings where pairing.needsMint(currentToken: token) {
            do {
                _ = try await mintAndStore(pairing, token: token)
            } catch {
                failed = true
                lastError = error.localizedDescription
                Log.push.error("relay \(pairing.relayURL, privacy: .public) refused to mint: \(error.localizedDescription, privacy: .public)")
            }
        }
        syncPending = failed
        if !failed {
            lastError = nil
            lastSyncSucceededAt = Date()
        }
    }

    /// Ask the relay for a send token over the CURRENT device token and store
    /// the updated pairing. The relay keeps nothing; what it returns is an HMAC
    /// it can recompute from the routing facts every push carries.
    private func mintAndStore(_ pairing: PushPairing, token: String) async throws -> PushPairing {
        var updated = pairing
        let minted = try await PushRelayClient.mint(apnsToken: token,
                                                    connectionId: pairing.connectionId,
                                                    relayURL: pairing.relayURL)
        updated.sendToken = minted.sendToken
        updated.sendTokenIssuedAt = minted.iat
        updated.apnsToken = token
        updated.apnsEnv = Self.apnsEnvironment
        guard PushPairingStore.upsert(updated) else { throw PushRelayClient.Failure.couldNotSave }
        Log.push.info("minted a send token for \(pairing.hostLabel, privacy: .public) at \(pairing.relayURL, privacy: .public)")
        return updated
    }

    func ensureReady(connectionId: UUID) async -> PushPairing? {
        guard supportsRemotePush, AppSettings.shared.notificationsEnabled else { return nil }
        guard let pairing = PushPairingStore.pairing(for: connectionId) else { return nil }
        guard pairing.needsMint(currentToken: deviceToken) else { return pairing }
        registerForRemoteNotifications()
        guard let token = await awaitDeviceToken() else {
            Log.push.info("credential for \(pairing.hostLabel, privacy: .public) not ready — no device token")
            return nil
        }
        do {
            return try await mintAndStore(pairing, token: token)
        } catch {
            lastError = error.localizedDescription
            Log.push.error("mint for \(pairing.hostLabel, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Called when the app returns to the foreground: a cheap local check that
    /// re-mints only what needs it (rotated device token, ageing credential).
    func refreshRegistration() {
        guard supportsRemotePush, AppSettings.shared.notificationsEnabled else { return }
        guard !pairings.isEmpty, deviceToken != nil else {
            if syncPending { registerForRemoteNotifications() }
            return
        }
        guard !Self.shouldSkipRefresh(syncPending: syncPending,
                                      lastSuccess: lastSyncSucceededAt,
                                      now: Date()) else { return }
        Task { await mintNeededPairings() }
    }

    /// The floor on foreground re-announcement, as a pure decision so it is
    /// pinned by a test rather than only exercised by a phone.
    ///
    /// `.active` fires every time the app switcher is scrubbed past, so without
    /// this N paired hosts cost N posts per glance — and a few hosts plus fast
    /// switching is enough to earn the ingress rate limit, which (until the
    /// error was wired to the screen) the user could not have seen. A pending
    /// failure skips the floor: that is the case worth being eager about.
    static func shouldSkipRefresh(syncPending: Bool, lastSuccess: Date?,
                                  now: Date, floor: TimeInterval = 60) -> Bool {
        guard !syncPending, let lastSuccess else { return false }
        return now.timeIntervalSince(lastSuccess) < floor
    }

    @ObservationIgnored private var lastSyncSucceededAt: Date?
    @ObservationIgnored private var syncInFlight = false

    // MARK: - Proving a pairing

    /// Nonces this device has seen arrive, and whoever is waiting for one.
    ///
    /// A set rather than "the last one", because the push can beat the exec
    /// channel's own reply: the sheet asks the host to fire a test and starts
    /// waiting, but on a fast link the notification is already in when the wait
    /// begins. Recording arrivals means the wait cannot miss one it caused.
    @ObservationIgnored private var arrivedSelfTests: Set<String> = []
    @ObservationIgnored private var selfTestWaiters: [String: CheckedContinuation<Void, Never>] = [:]

    /// Called from the notification delegate when a self-test push lands.
    func noteSelfTestArrived(nonce: String) {
        Log.push.info("self-test push arrived: \(nonce, privacy: .public)")
        arrivedSelfTests.insert(nonce)
        selfTestWaiters.removeValue(forKey: nonce)?.resume()
    }

    /// Wait for a specific self-test push, or give up.
    ///
    /// Returns true only if THIS nonce arrived. A stale test push from an
    /// earlier attempt satisfies nothing, which is the whole reason the nonce
    /// exists — the old install flow's equivalent check resolved on any evidence
    /// it could find and called that success.
    ///
    /// Arrival and timeout share ONE wake-up path — `selfTestWaiters.removeValue`
    /// — so the continuation is resumed exactly once and by whichever comes
    /// first. That is not style: a `withTaskGroup` racing a sleeper against a
    /// `withCheckedContinuation` deadlocks on the timeout, because the group
    /// awaits every child before returning and `cancelAll()` cannot resume a
    /// continuation. It hung forever, which left `HostSetupModel.provePush()`
    /// spinning in `.proving` and made its timeout message unreachable — on the
    /// commonest first-pair path of all, where the relay has no device token yet
    /// and no push was ever going to arrive.
    func awaitSelfTest(nonce: String, timeout: Duration = .seconds(20)) async -> Bool {
        if arrivedSelfTests.contains(nonce) { return true }
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, !Task.isCancelled else { return }
            // removeValue is the gate: whoever takes the continuation out of the
            // dictionary owns resuming it, and there is only ever one taker.
            if let waiter = self.selfTestWaiters.removeValue(forKey: nonce) {
                Log.push.info("self-test \(nonce, privacy: .public) never arrived — giving up")
                waiter.resume()
            }
        }
        // Resumed by noteSelfTestArrived, by the timeout above, or by
        // forgetSelfTest — never by more than one of them.
        await withCheckedContinuation { continuation in
            selfTestWaiters[nonce] = continuation
        }
        timeoutTask.cancel()
        return arrivedSelfTests.contains(nonce)
    }

    /// Forget a finished attempt so a long-lived app does not accumulate nonces.
    ///
    /// Resumes a waiter that is somehow still parked rather than dropping its
    /// continuation on the floor: an abandoned `withCheckedContinuation` is a
    /// task that never finishes, and this whole path already paid for that once.
    func forgetSelfTest(nonce: String) {
        arrivedSelfTests.remove(nonce)
        selfTestWaiters.removeValue(forKey: nonce)?.resume()
    }

    // MARK: - Pairing

    /// Mint material for a connection and return a READY pairing — end-to-end
    /// secret from this phone's CSPRNG, send token from the relay.
    ///
    /// The relay is asked BEFORE the host is touched, for the same reason
    /// registration used to be: if the mint fails there is nothing to undo on
    /// the host, and the user sees the real error instead of a host configured
    /// with a credential that could never have worked.
    ///
    /// A first-ever pair usually lands here seconds after notification
    /// permission was granted, before iOS has handed over a device token — so
    /// this waits briefly for one rather than failing the commonest path.
    func pair(connectionId: UUID, hostLabel: String, relayURL: String) async throws -> PushPairing {
        guard supportsRemotePush else { throw PushRelayClient.Failure.unsupportedSigning }
        guard AppSettings.shared.notificationsEnabled else { throw PushRelayClient.Failure.notificationsDisabled }
        // A re-pair mints a fresh SECRET on purpose: the previous conf on that
        // host stops decrypting, which is the whole point of re-pairing after a
        // machine changes hands. (Its send token dies of relay-side TTL — a
        // stateless relay has no row to delete — but a token without the secret
        // can only ever produce the generic fallback line.)
        let pairing = PushPairing.make(connectionId: connectionId,
                                       hostLabel: hostLabel,
                                       relayURL: relayURL)
        // Abort before the host is touched. A pairing the phone failed to save,
        // installed on a host anyway, is the worst arrangement available: the
        // host holds secrets, every push it sends is undecryptable, and there is
        // no local record left to unpair with.
        guard PushPairingStore.upsert(pairing) else { throw PushRelayClient.Failure.couldNotSave }
        registerForRemoteNotifications()
        guard let token = await awaitDeviceToken() else {
            // Stored but credential-less: `ensureReady`/`mintNeededPairings`
            // completes it the moment a token exists. Failing loudly here beats
            // silently installing a conf the sender would skip.
            syncPending = true
            throw PushRelayClient.Failure.noDeviceToken
        }
        return try await mintAndStore(pairing, token: token)
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        UIApplication.shared.unregisterForRemoteNotifications()
    }

    /// Forget a host. Local-only, and that is now the whole story: deleting the
    /// pairing SECRET is what stops this device reading anything, and the relay
    /// has no registration to forget. A conf left on an unreachable host keeps
    /// a valid send token until its TTL runs out — such a host can ring the
    /// generic fallback line, never content — and the unpair flow's host-side
    /// file removal handles the reachable case.
    func unpair(connectionId: UUID) {
        PushPairingStore.remove(connectionId: connectionId)
    }
}

/// The relay's HTTP surface, as seen from the phone. Exactly one call: "here is
/// my device token and a connection id — mint me a send token". The relay
/// answers with an HMAC and remembers nothing.
enum PushRelayClient {
    enum Failure: LocalizedError {
        case notificationsDisabled
        case unsupportedSigning
        case badURL
        case couldNotSave
        case noDeviceToken
        case status(Int, String)

        var errorDescription: String? {
            switch self {
            case .notificationsDisabled:
                return String(localized: "请先开启设置中的通知开关。")
            case .unsupportedSigning:
                return RemotePushCapability.unavailableMessage
            case .badURL:
                return String(localized: "That relay address isn't a valid URL.")
            case .couldNotSave:
                return String(localized: "Couldn't save the pairing on this phone, so nothing was installed on the host. The diagnostics log has the reason.")
            case .noDeviceToken:
                return String(localized: "iOS hasn't issued a push token to this phone yet — check that notifications are allowed, then try again.")
            case let .status(code, body):
                return String(localized: "Relay refused to mint a send token (\(code)): \(body)")
            }
        }
    }

    /// Ask the relay for a send token over this device token and connection.
    static func mint(apnsToken: String, connectionId: UUID,
                     relayURL: String) async throws -> (sendToken: String, iat: Date) {
        guard let url = URL(string: relayURL + "/v1/mint"),
              url.scheme == "https" || url.host == "localhost" || url.host == "127.0.0.1"
        else { throw Failure.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 15
        let payload = [
            "apnsToken": apnsToken,
            "conn": connectionId.uuidString,
        ]
        request.httpBody = try JSONEncoder().encode(payload)

        // One retry, on NETWORK failure only. A live re-pair was watched dying
        // at exactly this step on the old register flow — a transient error
        // that one retry would have covered. An HTTP status is the relay's
        // ANSWER; asking again would not change it.
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            try await Task.sleep(for: .seconds(2))
            (data, response) = try await URLSession.shared.data(for: request)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw Failure.status(code, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        struct Minted: Decodable {
            let sendToken: String
            let iat: Int64
        }
        let minted = try JSONDecoder().decode(Minted.self, from: data)
        return (minted.sendToken, Date(timeIntervalSince1970: TimeInterval(minted.iat)))
    }
}

/// Minimal app delegate, added solely because remote-notification tokens are
/// delivered nowhere else — SwiftUI has no equivalent hook. Keep it an
/// NSObject: as a UIResponder vending `keyCommands` it silently broke every
/// SwiftUI `.keyboardShortcut` in the app.
final class PushAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushService.shared.handle(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in PushService.shared.handleRegistrationFailure(error) }
    }
}
