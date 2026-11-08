import CoreGraphics
import Foundation
import Testing
@testable import ClickRelay

/// The router's gate and refusals, without permissions. Only paths that
/// refuse before anything is posted are exercised here.
@MainActor
@Suite("Tool router")
struct ToolRouterTests {
    let clock = FakeClock()
    let leases: LeaseController
    let preferences: Preferences
    let router: ToolRouter
    let session = Fixtures.session()

    init() {
        leases = LeaseController(clock: clock, authenticator: FakeAuthenticator())
        preferences = Preferences(defaults: Fixtures.defaults())
        preferences.unlockWaitSeconds = 0
        let windows = [
            Fixtures.window(2, pid: Fixtures.notesPID, frame: CGRect(x: 150, y: 150, width: 200, height: 200), title: "Shopping"),
            Fixtures.window(1, pid: Fixtures.simulatorPID, frame: CGRect(x: 100, y: 100, width: 400, height: 800), title: "iPhone 17"),
            Fixtures.window(3, pid: Fixtures.settingsPID, frame: CGRect(x: 900, y: 100, width: 400, height: 400))
        ]
        router = ToolRouter(leases: leases, preferences: preferences,
                            catalog: FakeCatalog(windows: windows), resolver: Fixtures.resolver)
    }

    func unlock(_ apps: Set<String> = ["com.apple.iphonesimulator"]) {
        leases.grant(sessions: [session], picked: apps, allowFilePanels: false, denyAgentHosts: true,
                     duration: .seconds(300), method: .touchID)
    }

    func call(_ tool: ToolName, _ args: [String: Any] = [:]) async -> ToolOutcome {
        await router.handle(name: tool.rawValue, arguments: ToolArguments(args), session: session)
    }

    @Test func everyToolButStatusIsLockedWithoutALease() async {
        for tool in ToolName.allCases where !tool.worksWhileLocked {
            let outcome = await call(tool, ["window_id": 1, "x": 1, "y": 1, "text": "a", "key": "a", "ref": "e1",
                                            "value": "v", "bundle_id": "com.apple.iphonesimulator", "query": "a",
                                            "from": ["x": 1, "y": 1], "to": ["x": 2, "y": 2]])
            #expect(outcome.result.isError, "\(tool.rawValue)")
            #expect(outcome.outcome == .refused)
            #expect(outcome.check == "lease")
            #expect(outcome.result.firstText?.contains("ClickRelay is locked") == true)
        }
    }

    @Test func validateScriptWorksWhileLockedAndGrantsNothing() async {
        let outcome = await call(.validateScript, ["script": ["app": "com.apple.iphonesimulator",
                                                              "steps": [["press": "Home"]]]])
        #expect(!outcome.result.isError)
        #expect(outcome.result.firstText?.contains("is valid") == true)
        #expect(leases.leases.isEmpty)
        #expect(leases.requests.isEmpty)
    }

    /// After macOS's prompt wasn't allowed, screenshots are refused without
    /// trying again (a retry could prompt again), and the agent is told to stop.
    @Test func aDeclinedCapturePromptBlocksScreenshotsUntilFixed() async {
        unlock()
        router.captureDeclined = true
        let outcome = await call(.screenshot, ["window_id": 1])
        #expect(outcome.outcome == .error)
        #expect(outcome.result.firstText == CaptureError.declined.message)
        #expect(outcome.result.firstText?.contains("stop") == true)
        #expect(router.captureDeclined)
    }

    /// Menus are found by app, and only an allowed app's.
    @Test func menuSearchNeedsAnAllowedApp() async {
        unlock()
        let missing = await call(.findElements, ["query": "Archive", "in": "menus"])
        #expect(missing.outcome == .error)
        #expect(missing.result.firstText?.contains("bundle_id is required") == true)
        let denied = await call(.findElements, ["query": "New Note", "in": "menus", "bundle_id": "com.apple.Notes"])
        #expect(denied.outcome == .refused)
        // Without "menus", window_id is still needed.
        let noWindow = await call(.findElements, ["query": "Archive"])
        #expect(noWindow.outcome == .error)
    }

    @Test func statusWorksWhileLocked() async throws {
        let outcome = await call(.status)
        #expect(!outcome.result.isError)
        let text = try #require(outcome.result.firstText)
        let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        #expect(json?["locked"] as? Bool == true)
    }

    @Test func statusReportsTheSessionsOwnLease() async throws {
        unlock()
        let outcome = await call(.status)
        let json = try JSONSerialization.jsonObject(with: Data(outcome.result.firstText!.utf8)) as? [String: Any]
        #expect(json?["locked"] as? Bool == false)
        #expect((json?["seconds_left"] as? Int) == 300)
        let apps = json?["allowed_apps"] as? [[String: Any]]
        #expect(apps?.first?["bundle_id"] as? String == "com.apple.iphonesimulator")

        let other = await router.handle(name: ToolName.status.rawValue, arguments: ToolArguments([:]),
                                        session: Fixtures.session("other"))
        let otherJSON = try JSONSerialization.jsonObject(with: Data(other.result.firstText!.utf8)) as? [String: Any]
        #expect(otherJSON?["locked"] as? Bool == true)
    }

    @Test func listWindowsShowsOnlyAllowedApps() async throws {
        unlock()
        let outcome = await call(.listWindows)
        let json = try JSONSerialization.jsonObject(with: Data(outcome.result.firstText!.utf8)) as? [String: Any]
        let windows = try #require(json?["windows"] as? [[String: Any]])
        #expect(windows.count == 1)
        #expect(windows[0]["window_id"] as? Int == 1)
        #expect(windows[0]["title"] as? String == "iPhone 17")
    }

    @Test func listWindowsRefusesADeniedBundle() async {
        unlock()
        let outcome = await call(.listWindows, ["bundle_id": "com.apple.Notes"])
        #expect(outcome.outcome == .refused)
    }

    @Test func clickOnADeniedWindowIsRefused() async {
        unlock()
        let outcome = await call(.click, ["window_id": 2, "x": 10, "y": 10])
        #expect(outcome.outcome == .refused)
        #expect(outcome.check == "window")
        #expect(outcome.result.firstText?.contains("Notes") == true)
    }

    @Test func clickOnACoveredPointIsRefused() async {
        unlock()
        // (200, 200) global is under the Notes window.
        let outcome = await call(.click, ["window_id": 1, "x": 100, "y": 100])
        #expect(outcome.outcome == .refused)
        #expect(outcome.check == "topmost")
        #expect(outcome.result.firstText?.contains("covered by a window from Notes") == true)
    }

    @Test func clickOutsideTheWindowIsRefused() async {
        unlock()
        let outcome = await call(.click, ["window_id": 1, "x": 450, "y": 10])
        #expect(outcome.check == "frame")
    }

    @Test func pixelsNeedAScreenshotFirst() async {
        unlock()
        let outcome = await call(.click, ["window_id": 1, "x": 10, "y": 10, "space": "pixels"])
        #expect(outcome.outcome == .error)
        #expect(outcome.result.firstText?.contains("screenshot first") == true)
    }

    @Test func dragIsCheckedAtTheStart() async {
        unlock()
        let outcome = await call(.drag, ["window_id": 1, "from": ["x": 100, "y": 100], "to": ["x": 300, "y": 600]])
        #expect(outcome.check == "topmost")
    }

    @Test func blockedShortcutsAreRefusedByName() async {
        unlock()
        for (key, modifiers) in [("tab", ["cmd"]), ("space", ["cmd"]), ("q", ["ctrl", "cmd"])] {
            let outcome = await call(.key, ["key": key, "modifiers": modifiers])
            #expect(outcome.check == "shortcut", "\(modifiers) \(key)")
            #expect(outcome.result.firstText?.contains("is blocked") == true)
        }
        let combined = await call(.key, ["key": "cmd+tab"])
        #expect(combined.check == "shortcut")
    }

    @Test func unknownKeysAndModifiers() async {
        unlock()
        #expect(await call(.key, ["key": "launchpad"]).outcome == .error)
        #expect(await call(.key, ["key": "a", "modifiers": ["hyper"]]).outcome == .error)
    }

    @Test func launchOnlyAllowedApps() async {
        unlock()
        let outcome = await call(.launchApp, ["bundle_id": "com.apple.Notes"])
        #expect(outcome.outcome == .refused)
        let settings = await call(.launchApp, ["bundle_id": "com.apple.systempreferences"])
        #expect(settings.outcome == .refused)
    }

    @Test func unknownRefsAreExplained() async {
        unlock()
        let outcome = await call(.press, ["ref": "e9"])
        #expect(outcome.result.firstText?.contains("isn't a current ref") == true)
    }

    @Test func expiredLeaseStopsTheNextCall() async {
        unlock()
        clock.advance(.seconds(301))
        let outcome = await call(.listWindows)
        #expect(outcome.check == "lease")
    }

    @Test func noToolCanExtendOrWidenALease() async {
        unlock()
        let before = leases.leases[session.id]
        for tool in ToolName.allCases {
            _ = await call(tool, ["window_id": 3, "bundle_id": "com.apple.systempreferences", "key": "l",
                                  "modifiers": ["ctrl", "option", "cmd"], "apps": ["com.apple.Notes"],
                                  "wait_seconds": 0, "message": "done"])
        }
        let after = leases.leases[session.id]
        #expect(after?.expiresAt == before?.expiresAt)
        #expect(after?.allowedBundleIDs == before?.allowedBundleIDs)
    }

    @Test func aLockedCallNamesItsTargetButGrantsNothing() async {
        preferences.unlockWaitSeconds = 5
        async let outcome = call(.click, ["window_id": 1, "x": 10, "y": 10])
        while leases.requests.isEmpty { await Task.yield() }
        #expect(leases.requests[0].targetBundleID == "com.apple.iphonesimulator")
        #expect(leases.leases.isEmpty)
        leases.dismissRequest(leases.requests[0].id)
        #expect(await outcome.check == "lease")
    }

    // MARK: Asking and notifying

    @Test func requestAccessWorksWhileLockedAndGrantsNothing() async {
        router.appLookup = { $0 == "Notes" ? "com.apple.Notes" : nil }
        async let outcome = call(.requestAccess, ["apps": ["Notes"], "reason": "Check the list", "wait_seconds": 5])
        while leases.requests.isEmpty { await Task.yield() }
        let request = leases.requests[0]
        #expect(request.explicit)
        #expect(request.apps == ["com.apple.Notes"])
        #expect(request.reason == "Check the list")
        #expect(request.deadline == nil)
        #expect(leases.leases.isEmpty)
        leases.dismissRequest(request.id)
        let result = await outcome
        #expect(result.result.isError)
        #expect(result.result.firstText?.contains("not now") == true)
    }

    @Test func requestAccessStaysUpAfterItsWaitEnds() async {
        router.appLookup = { $0 }
        let outcome = await call(.requestAccess, ["apps": ["com.apple.Notes"], "wait_seconds": 0])
        #expect(outcome.result.firstText?.contains("hasn't answered") == true)
        #expect(leases.requests.count == 1)
        unlock(["com.apple.Notes"])
        #expect(leases.requests.isEmpty)
    }

    @Test func requestAccessRefusesAppsThatCanNeverBeAllowed() async {
        router.appLookup = { $0 }
        let outcome = await call(.requestAccess, ["apps": ["com.apple.systempreferences", "com.apple.Terminal"]])
        #expect(outcome.outcome == .refused)
        #expect(leases.requests.isEmpty)
    }

    @Test func requestAccessForAnAppAlreadyAllowedReturnsAtOnce() async {
        router.appLookup = { $0 }
        unlock()
        let outcome = await call(.requestAccess, ["apps": ["com.apple.iphonesimulator"]])
        #expect(!outcome.result.isError)
        #expect(leases.requests.isEmpty)
    }

    @Test func requestAccessWhileUnlockedWaitsForANewUnlock() async {
        router.appLookup = { $0 }
        unlock()
        async let outcome = call(.requestAccess, ["apps": ["com.apple.Notes"], "wait_seconds": 5])
        while leases.requests.isEmpty { await Task.yield() }
        #expect(leases.leases[session.id]?.allowedBundleIDs == ["com.apple.iphonesimulator"])
        unlock(["com.apple.iphonesimulator", "com.apple.Notes"])
        let result = await outcome
        #expect(!result.result.isError)
        #expect(result.leaseID == leases.leases[session.id]?.id)
    }

    @Test func notifyWorksLockedAndCanGiveAccessBack() async {
        var notices: [AgentNotice] = []
        router.onNotify = { notices.append($0) }
        let locked = await call(.notify, ["message": "All done", "status": "needs_you"])
        #expect(!locked.result.isError)
        #expect(notices.last?.kind == .needsYou)
        #expect(notices.last?.message == "All done")

        unlock()
        _ = await call(.notify, ["message": "Finished", "release_access": true])
        #expect(notices.last?.kind == .done)
        #expect(leases.leases[session.id] == nil)
    }

    @Test func notifyNeedsAMessage() async {
        let outcome = await call(.notify, [:])
        #expect(outcome.result.isError)
    }

    @Test func typedTextIsKeptForTheCallsList() {
        let detail = AppModel.argumentDetail(tool: ToolName.key.rawValue,
                                             arguments: ToolArguments(["key": "z", "modifiers": ["cmd", "shift"]]))
        #expect(detail == "cmd+shift+z")
        #expect(AppModel.oneLine("a\nb") == "a⏎b")
        #expect(AppModel.oneLine(String(repeating: "x", count: 500)).count == 161)
    }

    @Test func unknownToolIsAnError() async {
        let outcome = await router.handle(name: "clickrelay_shell", arguments: ToolArguments([:]), session: session)
        #expect(outcome.result.isError)
    }

    @Test func lockedMessageNamesTheUnlockMethod() {
        preferences.unlockMethod = .authorizeButton
        #expect(router.lockedMessage(waited: false).contains("Authorize button"))
        preferences.unlockMethod = .touchID
        preferences.unlockWaitSeconds = 30
        #expect(router.lockedMessage(waited: true).hasPrefix("ClickRelay is still locked after 30 seconds."))
    }
}

@MainActor
@Suite("Preferences")
struct PreferencesTests {
    @Test func defaults() {
        let preferences = Preferences(defaults: Fixtures.defaults())
        #expect(preferences.leaseDurationMinutes == 5)
        #expect(preferences.unlockWaitSeconds == 30)
        #expect(preferences.idleTimeout == nil)
        #expect(preferences.killShortcut == .defaultKill)
        #expect(preferences.screenshotMaxEdge == 1568)
        #expect(!preferences.allowFilePanels)
        #expect(preferences.auditRetentionDays == 7)
        #expect(preferences.lastAllowedApps.isEmpty)
        #expect(preferences.indicatorStyle == .windows)
        #expect(preferences.showClickHighlights)
        #expect(!preferences.keepTypedText)
    }

    @Test func persists() {
        let defaults = Fixtures.defaults()
        let preferences = Preferences(defaults: defaults)
        preferences.leaseDurationMinutes = 45
        preferences.lastAllowedApps = ["com.apple.iphonesimulator"]
        preferences.setDelivery(.global, for: "com.example.app")
        let reloaded = Preferences(defaults: defaults)
        #expect(reloaded.leaseDurationMinutes == 45)
        #expect(reloaded.lastAllowedApps == ["com.apple.iphonesimulator"])
        #expect(reloaded.delivery(for: "com.example.app") == .global)
        #expect(reloaded.delivery(for: "com.other.app") == .targeted)
    }

    @Test func durationText() {
        #expect(AppModel.durationText(minutes: 5) == "5 minutes")
        #expect(AppModel.durationText(minutes: 60) == "1 hour")
        #expect(AppModel.durationText(minutes: 120) == "2 hours")
        #expect(AppModel.durationText(minutes: 90) == "1 h 30 min")
    }

    @Test func screenshotScaleFitsTheMaxEdge() {
        #expect(Screenshotter.targetScale(points: CGSize(width: 1000, height: 500), backing: 2, maxEdge: 1568) == 1.568)
        #expect(Screenshotter.targetScale(points: CGSize(width: 400, height: 300), backing: 2, maxEdge: 1568) == 2)
    }
}

@MainActor
@Suite("Overlay borders")
struct OverlayActivityTests {
    typealias Activity = OverlayController.Activity

    @Test func pulsesUpThenFadesToTheRestingOutline() {
        let start = Date()
        let activity = Activity(start: start, from: 0)
        #expect(activity.alpha(at: start) == 0)
        #expect(activity.alpha(at: start.addingTimeInterval(Activity.rise + 0.1)) == 1)
        let rested = start.addingTimeInterval(Activity.rise + Activity.hold + Activity.fade + 1)
        #expect(activity.alpha(at: rested) == Activity.resting)
        #expect(!activity.isAnimating(at: rested))
    }

    @Test func aCallMidFadeStartsFromWhereItWas() {
        let start = Date()
        let activity = Activity(start: start, from: 0.4)
        #expect(activity.alpha(at: start) == 0.4)
        #expect(activity.alpha(at: start.addingTimeInterval(Activity.rise / 2)) > 0.4)
    }
}
