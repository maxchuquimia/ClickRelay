import CoreGraphics
import Foundation
import Testing
@testable import ClickRelay

/// `clickrelay_hand_off`: the user gets the Mac for a moment, every agent's
/// input pauses, and the app they're in can't be captured or read.
@MainActor
@Suite("Hand-off")
struct HandOffTests {
    let clock = FakeClock()
    let leases: LeaseController
    let preferences: Preferences
    let router: ToolRouter
    let session = Fixtures.session()
    let other = Fixtures.session("session-b")

    init() {
        leases = LeaseController(clock: clock, authenticator: FakeAuthenticator())
        preferences = Preferences(defaults: Fixtures.defaults())
        preferences.unlockWaitSeconds = 0
        let windows = [
            Fixtures.window(2, pid: Fixtures.notesPID, frame: CGRect(x: 150, y: 150, width: 200, height: 200)),
            Fixtures.window(1, pid: Fixtures.simulatorPID, frame: CGRect(x: 100, y: 100, width: 400, height: 800),
                            title: "iPhone 17")
        ]
        router = ToolRouter(leases: leases, preferences: preferences,
                            catalog: FakeCatalog(windows: windows), resolver: Fixtures.resolver)
        let router = router
        leases.onLeaseEnded = { lease, _ in router.leaseEnded(sessionID: lease.sessionID) }
        leases.grant(sessions: [session, other], picked: ["com.apple.iphonesimulator", "com.apple.Notes"],
                     allowFilePanels: false, denyAgentHosts: true, duration: .seconds(300), method: .touchID)
    }

    func call(_ tool: ToolName, _ args: [String: Any] = [:], as who: AgentSession? = nil) async -> ToolOutcome {
        await router.handle(name: tool.rawValue, arguments: ToolArguments(args), session: who ?? session)
    }

    func waitForOpen() async {
        while router.handOffs.handOffs.isEmpty { await Task.yield() }
    }

    func json(_ outcome: ToolOutcome) throws -> [String: Any] {
        let text = try #require(outcome.result.firstText)
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test func pausesInputAndHidesTheAppUntilTheUserIsDone() async throws {
        async let handed = call(.handOff, ["window_id": 1, "message": "Enter your password", "wait_seconds": 5])
        await waitForOpen()
        #expect(router.handOffs.handOffs[session.id]?.appName == "Simulator")

        // Every agent's input waits, in any app.
        for who in [session, other] {
            #expect(await call(.click, ["window_id": 2, "x": 10, "y": 10], as: who).check == "hand_off")
            #expect(await call(.type, ["text": "x"], as: who).check == "hand_off")
            #expect(await call(.focusWindow, ["window_id": 1], as: who).check == "hand_off")
            // A script is only its single calls, so it waits too.
            let script: [String: Any] = ["app": "com.apple.Notes", "steps": [["press": "New Note"]]]
            #expect(await call(.runScript, ["script": script], as: who).check == "hand_off")
        }
        // The app they're in can't be seen or read.
        #expect(await call(.screenshot, ["window_id": 1], as: other).check == "hand_off")
        #expect(await call(.getUITree, ["window_id": 1]).check == "hand_off")
        #expect(await call(.findElements, ["window_id": 1, "query": "a"]).check == "hand_off")
        let windows = try json(await call(.listWindows))["windows"] as? [[String: Any]] ?? []
        #expect(windows.first { $0["window_id"] as? Int == 1 }?["user_working"] as? Bool == true)
        #expect(try json(await call(.status))["input_allowed"] as? Bool == false)

        router.handOffs.finish(sessionID: session.id, .done(note: "Used my work account"))
        let result = await handed
        #expect(!result.result.isError)
        #expect(result.result.firstText?.contains("Used my work account") == true)
        #expect(router.handOffs.handOffs.isEmpty)
        #expect(await call(.click, ["window_id": 1, "x": 10, "y": 10]).check != "hand_off")
    }

    @Test func cantDoIsARefusalWithTheNote() async {
        async let handed = call(.handOff, ["window_id": 1, "message": "Solve the CAPTCHA", "wait_seconds": 5])
        await waitForOpen()
        router.handOffs.finish(sessionID: session.id, .cantDo(note: "No access"))
        let result = await handed
        #expect(result.result.isError)
        #expect(result.result.firstText?.contains("couldn't do this") == true)
        #expect(result.result.firstText?.contains("No access") == true)
    }

    @Test func itStaysOpenAfterTheWaitAndTheAnswerComesLater() async throws {
        let first = await call(.handOff, ["window_id": 1, "message": "Enter the code", "wait_seconds": 0])
        #expect(first.result.firstText?.contains("hasn't answered") == true)
        #expect(router.handOffs.handOffs[session.id] != nil)

        router.handOffs.finish(sessionID: session.id, .done(note: nil))
        let again = await call(.handOff, ["window_id": 1, "message": "Enter the code", "wait_seconds": 5])
        #expect(!again.result.isError)
        #expect(again.result.firstText?.contains("finished") == true)
        #expect(router.handOffs.handOffs.isEmpty)
    }

    @Test func anAnswerNobodyWaitedForShowsInStatusOnce() async throws {
        _ = await call(.handOff, ["window_id": 1, "message": "Approve it", "wait_seconds": 0])
        router.handOffs.finish(sessionID: session.id, .done(note: "Approved"))
        let status = try json(await call(.status))
        let handOff = status["hand_off"] as? [String: Any]
        #expect(handOff?["answered"] as? Bool == true)
        #expect((handOff?["answer"] as? String)?.contains("Approved") == true)
        #expect(try json(await call(.status))["hand_off"] == nil)
    }

    @Test func lockingEndsItWithTheLockedMessage() async {
        async let handed = call(.handOff, ["window_id": 1, "message": "Enter your password", "wait_seconds": 5])
        await waitForOpen()
        leases.lock(sessionID: session.id, reason: .lockNow)
        let result = await handed
        #expect(result.check == "lease")
        #expect(router.handOffs.handOffs.isEmpty)
    }

    @Test func oneHandOffAtATime() async {
        _ = await call(.handOff, ["window_id": 1, "message": "Enter your password", "wait_seconds": 0])
        let second = await call(.handOff, ["window_id": 2, "message": "And this", "wait_seconds": 0], as: other)
        #expect(second.check == "hand_off")
        #expect(router.handOffs.handOffs.count == 1)
    }

    @Test func handingOffAnotherWindowReplacesTheFirst() async {
        async let first = call(.handOff, ["window_id": 1, "message": "One", "wait_seconds": 5])
        await waitForOpen()
        _ = await call(.handOff, ["window_id": 2, "message": "Two", "wait_seconds": 0])
        #expect(await first.result.firstText?.contains("another window") == true)
        #expect(router.handOffs.handOffs[session.id]?.windowID == 2)
    }

    @Test func needsAnAllowedWindowAndAMessage() async {
        #expect(await call(.handOff, ["window_id": 1]).check == "arguments")
        #expect(await call(.handOff, ["window_id": 99, "message": "x"]).check == "window")
        #expect(await call(.handOff, ["window_id": 1, "ref": "e5", "message": "x"]).check == "arguments")
        #expect(router.handOffs.handOffs.isEmpty)
    }

    @Test func itNeverChangesALease() async {
        let before = leases.leases[session.id]
        _ = await call(.handOff, ["window_id": 1, "message": "Enter your password", "wait_seconds": 0])
        router.handOffs.finish(sessionID: session.id, .done(note: nil))
        #expect(leases.leases[session.id]?.expiresAt == before?.expiresAt)
        #expect(leases.leases[session.id]?.allowedBundleIDs == before?.allowedBundleIDs)
    }
}
