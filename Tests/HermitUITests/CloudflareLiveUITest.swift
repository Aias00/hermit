import XCTest

/// ATTENDED simulator test, disabled unless explicitly configured.
///
/// Generate a separate xctestrun with prepare_live_ui_run.py. First run its
/// non-secret smoke mode and verify no UI captures are retained. The live copy
/// sets capture lifetimes to keepNever; also pass -collect-test-diagnostics never.
/// MOSHPIT_CF_LIVE=1 and MOSHPIT_CF_LIVE_CAPTURE_DISABLED=1 are required, together
/// with public MOSHPIT_CF_LIVE_HOSTNAME. Automatic discovery is the default.
/// Only MOSHPIT_CF_MANUAL_ACCESS=1 enables the advanced override and requires
/// TEAM_DOMAIN, AUDIENCE and SSH_HOST under the MOSHPIT_CF_LIVE_ prefix.
/// No password, OTP, key, token or cookie is accepted.
///
/// The test first cancels the actual system authentication browser, then waits
/// for a real Access/IdP login. The person completes MFA by hand. An optional
/// MOSHPIT_CF_EXPORT_LOGIN_LINK_DIR enables the DEBUG simulator's public-key
/// handoff link for an external browser. That mode verifies cross-browser
/// transfer, not attended MFA inside Safari. Only consent/Cancel controls are
/// automated; browser contents and credentials are never inspected. It creates
/// a dedicated saved connection without SSH or remote configuration changes.
/// Real carrier/SSH verification is a separate integration test.
final class CloudflareLiveUITest: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 600
    }

    private struct Configuration {
        let hostname: String
        let teamDomain: String
        let audience: String
        let logicalHost: String
        let manualAccess: Bool
        let loginLinkDirectory: String?

        static func load() throws -> Self {
            let environment = ProcessInfo.processInfo.environment
            guard environment["MOSHPIT_CF_LIVE"] == "1" else {
                throw XCTSkip("Attended Access verification is opt-in")
            }
            guard environment["MOSHPIT_CF_LIVE_CAPTURE_DISABLED"] == "1" else {
                throw XCTSkip("Use the separate no-capture xctestrun and verify its smoke result before real login")
            }
            func field(_ suffix: String) throws -> String {
                guard let value = environment["MOSHPIT_CF_LIVE_" + suffix]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty else { throw XCTSkip("Missing public Access application metadata") }
                return value
            }
            let hostname = try field("HOSTNAME")
            let manualAccess = environment["MOSHPIT_CF_MANUAL_ACCESS"] == "1"
            // Existing live fixtures may still export team/audience metadata.
            // Their presence must not opt out of the normal hostname-only flow.
            return try Self(hostname: hostname,
                            teamDomain: manualAccess ? field("TEAM_DOMAIN") : "",
                            audience: manualAccess ? field("AUDIENCE") : "",
                            logicalHost: manualAccess ? field("SSH_HOST") : hostname,
                            manualAccess: manualAccess,
                            loginLinkDirectory: environment["MOSHPIT_CF_EXPORT_LOGIN_LINK_DIR"])
        }
    }

    private enum Failure: Error {
        case formNotReachable, accountResetFailed, cancellationNotObserved
        case authenticationBrowserNotPresented
        case loginCancelled, loginDeadlineExceeded, loginNetworkFailure, loginCredentialStorageFailed
        case loginPresentationFailed, loginConfigurationRejected, loginCredentialVerificationFailed
        case loginTransferFailed, loginHTTPFailure, loginSimulatorHandoffFailed, loginUnknownAppError
        case loginReturnedWithoutAccount, loginStillPendingAtTestDeadline
        case savedConnectionMissing, persistedLoginNotRestored
    }

    /// No screenshot or debugDescription attachments: those can include the
    /// authentication UI. Use geometry only for our own configuration form.
    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) throws {
        var towardTop = false
        for attempt in 0..<24 {
            let bar = app.navigationBars["新建 Host"].exists
                ? app.navigationBars["新建 Host"] : app.navigationBars["编辑 Host"]
            let form = app.collectionViews.firstMatch
            var area = (form.exists ? form.frame : app.frame).intersection(app.frame)
            if bar.exists {
                let top = max(area.minY, bar.frame.maxY + 10)
                area = CGRect(x: area.minX, y: top, width: area.width, height: max(0, area.maxY - top))
            }
            if app.keyboards.firstMatch.exists {
                area.size.height = max(0, min(area.maxY, app.keyboards.firstMatch.frame.minY - 54) - area.minY)
            }
            area = area.insetBy(dx: 12, dy: 10)
            guard area.height > 80 else { break }
            var distance = min(area.height * 0.4, 180)
            if element.exists {
                let frame = element.frame
                if area.contains(frame), element.isHittable { return }
                towardTop = frame.midY < area.midY
                distance = min(distance, max(60, abs(frame.midY - area.midY)))
            } else if attempt == 8 || attempt == 16 {
                towardTop.toggle()
            }
            let x = area.minX + area.width * 0.7
            let y = area.minY + area.height * (towardTop ? 0.25 : 0.75)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: x, dy: y)).press(forDuration: 0.05,
                thenDragTo: origin.withOffset(CGVector(dx: x, dy: y + (towardTop ? distance : -distance))))
        }
        throw Failure.formNotReachable
    }

    @MainActor
    private func fillPublicField(_ identifier: String, with value: String, in app: XCUIApplication) throws {
        let field = app.textFields[identifier].firstMatch
        try reveal(field, in: app)
        field.tap()
        field.typeText(value)
    }

    /// Poll only app-owned state with generic identifiers. The browser's URL,
    /// contents, account label value, and credentials are never read or logged.
    @MainActor
    private func wait(seconds: TimeInterval, until predicate: @MainActor () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if predicate() { return true }
            try await Task.sleep(for: .seconds(1))
        }
        return false
    }

    /// The initial iOS permission alert is separate from cancelling the browser.
    /// Do not inspect its text or any web content; only the consent button is used.
    @MainActor
    private func acceptBrowserConsent(in app: XCUIApplication) {
        let names = NSPredicate(format: "label IN %@", ["Continue", "继续"])
        for owner in [app, XCUIApplication(bundleIdentifier: "com.apple.springboard"),
                      XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")] {
            let button = owner.alerts.buttons.matching(names).firstMatch
            if button.exists && button.isHittable {
                button.tap()
                return
            }
        }
    }

    @MainActor
    private func browserCancelButton(in app: XCUIApplication) -> XCUIElement? {
        let names = NSPredicate(format: "label IN %@", ["Cancel", "取消"])
        // Prefer the service's own accessibility tree, which cannot match the
        // connection form's Cancel button underneath the authentication sheet.
        let service = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        let serviceCancel = service.buttons.matching(names).firstMatch
        if serviceCancel.exists && serviceCancel.isHittable { return serviceCancel }

        // Some runtimes expose native browser chrome under the host app. Never
        // query the browser DOM; exclude both app-owned form navigation bars.
        let browserBars = app.navigationBars.matching(NSPredicate(
            format: "identifier != %@ AND identifier != %@", "新建 Host", "编辑 Host"))
        let candidates = [browserBars.buttons.matching(names).firstMatch,
                          app.toolbars.buttons.matching(names).firstMatch]
        return candidates.first { $0.exists && $0.isHittable }
    }

    @MainActor
    private func awaitAuthenticationBrowser(in app: XCUIApplication) async throws -> CGRect {
        let deadline = Date().addingTimeInterval(30)
        var stableFrame: CGRect?
        var stableSince: Date?
        while Date() < deadline {
            acceptBrowserConsent(in: app)
            if app.staticTexts["cloudflare-access-error"].firstMatch.exists {
                throw classifiedLoginError(in: app)
            }
            if let cancel = browserCancelButton(in: app) {
                let frame = cancel.frame
                if !frame.isEmpty && app.frame.contains(frame) {
                    if frame == stableFrame, let since = stableSince, Date().timeIntervalSince(since) >= 1 {
                        return frame
                    }
                    if frame != stableFrame { stableFrame = frame; stableSince = Date() }
                } else {
                    stableFrame = nil
                    stableSince = nil
                }
            } else {
                stableFrame = nil
                stableSince = nil
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw Failure.authenticationBrowserNotPresented
    }

    /// Compare only fixed, credential-free app error messages. Never read or
    /// print an unknown label, account value, URL, web view or accessibility tree.
    @MainActor
    private func classifiedLoginError(in app: XCUIApplication) -> Failure {
        let known: [(Failure, [String])] = [
            (.loginCancelled, ["已取消 Cloudflare 登录。"]),
            (.loginDeadlineExceeded, ["Access login timed out."]),
            (.loginNetworkFailure, ["Could not reach the Access login service."]),
            (.loginCredentialStorageFailed, ["无法安全保存 Cloudflare 登录状态，请解锁设备后重试。"]),
            (.loginPresentationFailed, ["请回到 Hermit 前台后登录 Cloudflare。"]),
            (.loginConfigurationRejected, ["Invalid or unsupported Access application configuration.",
                                           "Access application metadata verification failed."]),
            (.loginCredentialVerificationFailed, [
                "Cloudflare 需要登录。请登录此连接的 Access 应用后重试。",
                "Access returned an invalid token.", "Access token signature verification failed.",
                "Access token claims are invalid.", "The Access session has expired.",
                "The Access token belongs to another application.", "The Access token belongs to another team.",
                "An interactive Access user identity is required."
            ]),
            (.loginTransferFailed, [
                "Access returned an invalid transfer public key.", "Access returned an invalid transfer response.",
                "Access credential transfer authentication failed.", "Could not create an ephemeral login key.",
                "This login attempt has already completed or been cancelled.",
                "Access returned an oversized response.", "Access returned an unexpected response."
            ]),
            (.loginHTTPFailure, [301, 302, 303, 307, 308, 400, 401, 403, 404, 408, 429, 500, 502, 503, 504]
                .map { "Access login failed with HTTP status \($0)." }),
            (.loginSimulatorHandoffFailed, ["Unable to prepare the simulator login handoff."])
        ]
        for (failure, messages) in known {
            let match = app.staticTexts.matching(NSPredicate(
                format: "identifier == %@ AND label IN %@", "cloudflare-access-error", messages)).firstMatch
            if match.exists { return failure }
        }
        return .loginUnknownAppError
    }

    @MainActor
    private func awaitLoginOutcome(in app: XCUIApplication) async throws {
        let account = app.descendants(matching: .any).matching(identifier: "cloudflare-access-account").firstMatch
        let signOut = app.buttons["cloudflare-access-sign-out"].firstMatch
        let login = app.buttons["cloudflare-access-login"].firstMatch
        let error = app.staticTexts["cloudflare-access-error"].firstMatch
        let started = Date()
        let deadline = started.addingTimeInterval(310)
        var nextProgress = 30
        var idleWithoutAccountSince: Date?
        while Date() < deadline {
            // Check errors before the success predicate: short-circuiting on a
            // missing account previously hid every early failure for 310 seconds.
            if error.exists {
                let failure = classifiedLoginError(in: app)
                print("[CloudflareLive] App login outcome: \(failure), after \(Int(Date().timeIntervalSince(started)))s.")
                throw failure
            }
            if account.exists && signOut.exists && login.exists && login.isEnabled { return }
            if login.exists && login.isEnabled {
                if let idleSince = idleWithoutAccountSince, Date().timeIntervalSince(idleSince) >= 3 {
                    print("[CloudflareLive] App login ended without an account or error state.")
                    throw Failure.loginReturnedWithoutAccount
                }
                if idleWithoutAccountSince == nil { idleWithoutAccountSince = Date() }
            } else {
                idleWithoutAccountSince = nil
            }
            let elapsed = Int(Date().timeIntervalSince(started))
            if elapsed >= nextProgress {
                print("[CloudflareLive] Waiting for App login outcome (\(elapsed)s).")
                nextProgress += 30
            }
            try await Task.sleep(for: .seconds(1))
        }
        print("[CloudflareLive] Test wait expired without an app success or error state; this is not proof of an Access timeout.")
        throw Failure.loginStillPendingAtTestDeadline
    }

    @MainActor
    func testAccessCancellationLoginAndRelaunch() async throws {
        let config = try Configuration.load()
        let name = "Cloudflare Live \(UUID().uuidString.prefix(8))"
        let app = XCUIApplication()
        // Preserve other connections and their credentials. No RESET, SEED,
        // pre-trust, file-vault override, or TLS override is part of this test.
        app.launchArguments = ["-MOSHPIT_AUTOCARE_OFF", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if let directory = config.loginLinkDirectory {
            app.launchEnvironment["MOSHPIT_CF_EXPORT_LOGIN_LINK_DIR"] = directory
        }
        app.launch()
        defer { app.terminate() }
        guard app.buttons["home-add"].waitForExistence(timeout: 10) else { throw Failure.formNotReachable }
        app.buttons["home-add"].tap()
        guard app.navigationBars["新建 Host"].waitForExistence(timeout: 5) else { throw Failure.formNotReachable }
        try fillPublicField("Name", with: name, in: app)
        try fillPublicField("Host", with: config.logicalHost, in: app)
        let transport = app.buttons["connection-transport-picker"].firstMatch
        try reveal(transport, in: app)
        transport.tap()
        let cloudflare = app.buttons["Cloudflare SSH (Experimental)"].firstMatch
        guard cloudflare.waitForExistence(timeout: 3) else { throw Failure.formNotReachable }
        cloudflare.tap()
        if config.manualAccess {
            let advanced = app.buttons.matching(NSPredicate(
                format: "label == %@", "高级 Cloudflare 配置")).firstMatch
            try reveal(advanced, in: app)
            advanced.tap()
            try fillPublicField("cloudflare-hostname", with: config.hostname, in: app)
            let manual = app.switches["cloudflare-manual-access-toggle"].firstMatch
            try reveal(manual, in: app)
            guard manual.value as? String == "0" else { throw Failure.formNotReachable }
            manual.tap()
            try fillPublicField("cloudflare-team-domain", with: config.teamDomain, in: app)
            try fillPublicField("cloudflare-audience", with: config.audience, in: app)
        }

        let login = app.buttons["cloudflare-access-login"].firstMatch
        let signOut = app.buttons["cloudflare-access-sign-out"].firstMatch
        let account = app.descendants(matching: .any).matching(identifier: "cloudflare-access-account").firstMatch
        let error = app.staticTexts["cloudflare-access-error"].firstMatch
        let cancelled = app.staticTexts.matching(NSPredicate(
            format: "identifier == %@ AND label == %@", "cloudflare-access-error", "已取消 Cloudflare 登录。"
        )).firstMatch
        try reveal(login, in: app)
        // The explicitly selected verification application may retain an older
        // test login. Clear only that scope through its normal app control.
        if signOut.exists {
            try reveal(signOut, in: app)
            signOut.tap()
            guard try await wait(seconds: 15, until: { !signOut.exists && login.isEnabled }) else {
                throw Failure.accountResetFailed
            }
        }

        print("[CloudflareLive] Step 1: exercise the actual system authentication browser's Cancel control.")
        try reveal(login, in: app)
        login.tap()
        let browserCancelFrame = try await awaitAuthenticationBrowser(in: app)
        // Element.tap() on an animating Safari button can ask XCTest to capture
        // its entire hierarchy during hit-point retries, despite keepNever.
        // Tap only the stable native control's screen coordinate instead.
        let appFrame = app.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: browserCancelFrame.midX - appFrame.minX,
            dy: browserCancelFrame.midY - appFrame.minY)).tap()
        guard try await wait(seconds: 15, until: { cancelled.exists && login.exists && login.isEnabled }) else {
            throw Failure.cancellationNotObserved
        }
        guard !account.exists && !signOut.exists else { throw Failure.cancellationNotObserved }

        login.tap()
        _ = try await awaitAuthenticationBrowser(in: app)
        print(config.loginLinkDirectory == nil
              ? "[CloudflareLive] Step 2: complete Access login and MFA by hand in Simulator."
              : "[CloudflareLive] Step 2: complete the App's one-time public-key handoff in the external browser. This does not verify in-Safari MFA.")
        try await awaitLoginOutcome(in: app)
        print("[CloudflareLive] Access login completed and the app reported a persisted account.")

        app.buttons["save-connection"].tap()
        let host = app.buttons["connection-card-\(name)"].firstMatch
        guard host.waitForExistence(timeout: 5) else { throw Failure.savedConnectionMissing }
        app.terminate()
        app.launch()
        guard host.waitForExistence(timeout: 10) else { throw Failure.savedConnectionMissing }
        guard app.reveal(host) else { throw Failure.savedConnectionMissing }
        let edit = app.buttons["编辑主机"].firstMatch
        pressForMenu(host, until: edit)
        edit.tap()
        guard app.navigationBars["编辑 Host"].waitForExistence(timeout: 5) else { throw Failure.formNotReachable }
        try reveal(login, in: app)
        guard try await wait(seconds: 30, until: { account.exists && signOut.exists && login.isEnabled && !error.exists }) else {
            throw Failure.persistedLoginNotRestored
        }
        print("[CloudflareLive] Access account restored after app restart without another browser login.")
        app.navigationBars["编辑 Host"].buttons["Cancel"].tap()
    }
}
