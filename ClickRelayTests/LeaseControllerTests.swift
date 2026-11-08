import Foundation
import Testing
@testable import ClickRelay

@MainActor
@Suite("Leases")
struct LeaseControllerTests {
    let clock = FakeClock()
    let auth = FakeAuthenticator()
    let controller: LeaseController
    var ended: [(Lease, LockReason)] { endedBox.value }
    private let endedBox = Box<[(Lease, LockReason)]>([])

    final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    init() {
        controller = LeaseController(clock: clock, authenticator: auth)
        let box = endedBox
        controller.onLeaseEnded = { lease, reason in box.value.append((lease, reason)) }
    }

    private func grant(_ session: AgentSession = Fixtures.session(), minutes: Int = 5,
                       apps: Set<String> = ["com.apple.iphonesimulator"]) {
        controller.grant(sessions: [session], picked: apps, allowFilePanels: false,
                         denyAgentHosts: true, duration: .seconds(minutes * 60), method: .touchID)
    }

    @Test func noLeaseMeansLocked() {
        #expect(controller.activeLease(for: "session-a") == nil)
        #expect(!controller.isAnyUnlocked)
    }

    @Test func unlockNeedsTheAuthenticator() async {
        auth.outcome = .cancelled
        let outcome = await controller.unlock(sessions: [Fixtures.session()], picked: ["com.apple.iphonesimulator"],
                                              allowFilePanels: false, denyAgentHosts: true,
                                              duration: .seconds(300), method: .touchID, reason: "test")
        #expect(outcome == .cancelled)
        #expect(controller.activeLease(for: "session-a") == nil)

        auth.outcome = .success
        let second = await controller.unlock(sessions: [Fixtures.session()], picked: ["com.apple.iphonesimulator"],
                                             allowFilePanels: false, denyAgentHosts: true,
                                             duration: .seconds(300), method: .touchID, reason: "test")
        #expect(second == .success)
        #expect(controller.activeLease(for: "session-a")?.allowedBundleIDs == ["com.apple.iphonesimulator"])
        #expect(auth.prompts.count == 2)
    }

    @Test func leaseExpiresOnTheNextCallEvenWithoutATick() {
        grant(minutes: 5)
        clock.advance(.seconds(299))
        #expect(controller.activeLease(for: "session-a") != nil)
        clock.advance(.seconds(1))
        #expect(controller.activeLease(for: "session-a") == nil)
        #expect(ended.map(\.1) == [.expired])
    }

    @Test func tickExpiresAndWarnsOnce() {
        var warnings = 0
        controller.onExpiryWarning = { _ in warnings += 1 }
        grant(minutes: 5)
        clock.advance(.seconds(230))
        controller.tick()
        #expect(warnings == 0)
        clock.advance(.seconds(15))   // 55 s left
        controller.tick()
        controller.tick()
        #expect(warnings == 1)
        clock.advance(.seconds(60))
        controller.tick()
        #expect(controller.leases.isEmpty)
        #expect(ended.map(\.1) == [.expired])
    }

    @Test func extendAddsTimeAfterConfirming() async {
        grant(minutes: 5)
        clock.advance(.seconds(240))
        let outcome = await controller.extend(sessionID: "session-a", by: .seconds(300), reason: "more")
        #expect(outcome == .success)
        #expect(controller.remaining(for: "session-a") == .seconds(360))
        clock.advance(.seconds(359))
        #expect(controller.activeLease(for: "session-a") != nil)
    }

    @Test func extendRefusedWithoutConfirmation() async {
        grant(minutes: 5)
        auth.outcome = .failed("no")
        let outcome = await controller.extend(sessionID: "session-a", by: .seconds(300), reason: "more")
        #expect(outcome == .failed("no"))
        #expect(controller.remaining(for: "session-a") == .seconds(300))
    }

    @Test func extendResetsTheWarning() async {
        var warnings = 0
        controller.onExpiryWarning = { _ in warnings += 1 }
        grant(minutes: 2)
        clock.advance(.seconds(70))
        controller.tick()
        #expect(warnings == 1)
        _ = await controller.extend(sessionID: "session-a", by: .seconds(120), reason: "more")
        clock.advance(.seconds(120))
        controller.tick()
        #expect(warnings == 2)
    }

    @Test func extendingALockedSessionDoesNothing() async {
        let outcome = await controller.extend(sessionID: "nobody", by: .seconds(60), reason: "x")
        #expect(outcome == .failed("Already locked"))
        #expect(auth.prompts.isEmpty)
    }

    @Test(arguments: [LockReason.lockNow, .killShortcut, .screenLocked, .screensaver, .sleep,
                      .sessionResigned, .appQuit, .permissionRevoked])
    func globalTriggersEndEveryLease(reason: LockReason) {
        grant(Fixtures.session("a"))
        grant(Fixtures.session("b"))
        #expect(controller.leases.count == 2)
        controller.lockAll(reason: reason)
        #expect(controller.leases.isEmpty)
        #expect(ended.count == 2)
        #expect(ended.allSatisfy { $0.1 == reason })
        #expect(reason.isGlobal)
    }

    @Test func idleTimeoutLocks() {
        controller.idleTimeout = .seconds(120)
        grant(minutes: 30)
        clock.advance(.seconds(100))
        controller.recordCall(sessionID: "session-a")
        clock.advance(.seconds(100))
        controller.tick()
        #expect(controller.activeLease(for: "session-a") != nil)
        clock.advance(.seconds(20))
        controller.tick()
        #expect(controller.activeLease(for: "session-a") == nil)
        #expect(ended.map(\.1) == [.idle])
    }

    @Test func idleIsOffByDefault() {
        grant(minutes: 30)
        clock.advance(.seconds(29 * 60))
        #expect(controller.activeLease(for: "session-a") != nil)
    }

    @Test func leasesBelongToOneSession() {
        grant(Fixtures.session("a"))
        #expect(controller.activeLease(for: "a") != nil)
        #expect(controller.activeLease(for: "b") == nil)
        controller.lock(sessionID: "a", reason: .lockNow)
        #expect(controller.activeLease(for: "a") == nil)
    }

    @Test func expiryIsPerLease() {
        grant(Fixtures.session("a"), minutes: 1)
        grant(Fixtures.session("b"), minutes: 10)
        clock.advance(.seconds(61))
        controller.tick()
        #expect(controller.activeLease(for: "a") == nil)
        #expect(controller.activeLease(for: "b") != nil)
    }

    @Test func unlockingAgainReplacesTheLease() {
        grant(apps: ["com.apple.iphonesimulator"])
        let first = controller.activeLease(for: "session-a")
        grant(apps: ["com.apple.Safari"])
        let second = controller.activeLease(for: "session-a")
        #expect(first?.id != second?.id)
        #expect(second?.allowedBundleIDs == ["com.apple.Safari"])
        #expect(ended.map(\.1) == [.replaced])
    }

    @Test func allowlistLeavesOutDeniedAppsAndTheTerminal() {
        grant(apps: ["com.apple.iphonesimulator", "com.apple.systempreferences", "com.apple.Terminal",
                     "io.mergeable.ClickRelay", "com.1password.1password"])
        #expect(controller.activeLease(for: "session-a")?.allowedBundleIDs == ["com.apple.iphonesimulator"])
    }

    @Test func lockWhenEveryAllowedAppQuits() {
        grant(apps: ["com.apple.iphonesimulator", "com.apple.Safari"])
        controller.appTerminated(bundleID: "com.apple.Safari", runningBundleIDs: ["com.apple.iphonesimulator"])
        #expect(controller.activeLease(for: "session-a") != nil)
        controller.appTerminated(bundleID: "com.apple.iphonesimulator", runningBundleIDs: ["com.apple.Notes"])
        #expect(controller.activeLease(for: "session-a") == nil)
        #expect(ended.map(\.1) == [.allowedAppsQuit])
    }

    @Test func unrelatedQuitsDontLock() {
        grant(apps: ["com.apple.iphonesimulator"])   // not running yet
        controller.appTerminated(bundleID: "com.apple.Notes", runningBundleIDs: [])
        #expect(controller.activeLease(for: "session-a") != nil)
    }

    // MARK: Waiting for an unlock

    @Test func waitingCallContinuesWhenUnlocked() async {
        let session = Fixtures.session()
        async let waited = controller.waitForUnlock(session: session, tool: "clickrelay_screenshot", timeout: .seconds(5))
        // Let the wait register.
        while controller.requests.isEmpty { await Task.yield() }
        #expect(controller.requests.first?.session.id == session.id)
        grant(session)
        let lease = await waited
        #expect(lease?.sessionID == session.id)
        #expect(controller.requests.isEmpty)
    }

    @Test func callsFromOneSessionShareOneRequest() async {
        let session = Fixtures.session()
        var changes = 0
        controller.onRequestsChanged = { _ in changes += 1 }
        async let first = controller.waitForUnlock(session: session, tool: "a", timeout: .seconds(5))
        async let second = controller.waitForUnlock(session: session, tool: "b", timeout: .seconds(5))
        while controller.requests.isEmpty { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
        #expect(controller.requests.count == 1)
        grant(session)
        let results = await [first, second]
        #expect(results.allSatisfy { $0 != nil })
        #expect(changes == 2)   // appeared once, cleared once
    }

    @Test func waitTimesOut() async {
        let lease = await controller.waitForUnlock(session: Fixtures.session(), tool: "x", timeout: .milliseconds(50))
        #expect(lease == nil)
        #expect(controller.requests.isEmpty)
    }

    @Test func unlockForAnotherSessionDoesntReleaseTheWait() async {
        async let waited = controller.waitForUnlock(session: Fixtures.session("a"), tool: "x", timeout: .milliseconds(200))
        while controller.requests.isEmpty { await Task.yield() }
        grant(Fixtures.session("b"))
        #expect(await waited == nil)
    }

    @Test func disconnectEndsTheWait() async {
        async let waited = controller.waitForUnlock(session: Fixtures.session("a"), tool: "x", timeout: .seconds(5))
        while controller.requests.isEmpty { await Task.yield() }
        controller.lock(sessionID: "a", reason: .disconnected)
        #expect(await waited == nil)
    }

    @Test func dismissingTheBannerEndsTheWait() async {
        async let waited = controller.waitForUnlock(session: Fixtures.session("a"), tool: "x", timeout: .seconds(5))
        while controller.requests.isEmpty { await Task.yield() }
        controller.dismissRequest(controller.requests[0].id)
        #expect(await waited == nil)
    }

    @Test func requestCarriesItsTargetAndDeadline() async {
        async let waited = controller.waitForUnlock(session: Fixtures.session("a"), tool: "clickrelay_click",
                                                    targetBundleID: "com.apple.iphonesimulator",
                                                    timeout: .seconds(30))
        while controller.requests.isEmpty { await Task.yield() }
        let request = controller.requests[0]
        #expect(request.targetBundleID == "com.apple.iphonesimulator")
        let deadline = try? #require(request.deadline)
        #expect(abs((deadline?.timeIntervalSince(request.createdAt) ?? 0) - 30) < 0.01)
        controller.dismissRequest(request.id)
        #expect(await waited == nil)
    }

    @Test func timeoutIsReportedButDismissingIsnt() async {
        let timedOut = Box<[String]>([])
        controller.onRequestTimedOut = { timedOut.value.append($0.session.id) }

        async let dismissed = controller.waitForUnlock(session: Fixtures.session("a"), tool: "x", timeout: .seconds(5))
        while controller.requests.isEmpty { await Task.yield() }
        controller.dismissRequest(controller.requests[0].id)
        #expect(await dismissed == nil)
        #expect(timedOut.value.isEmpty)

        let lease = await controller.waitForUnlock(session: Fixtures.session("b"), tool: "x", timeout: .milliseconds(50))
        #expect(lease == nil)
        #expect(timedOut.value == ["b"])
    }

    @Test func explicitRequestsMergeAndOutlastTheirWait() async {
        let session = Fixtures.session("a")
        let first = await controller.requestAccess(session: session, apps: ["com.apple.Notes"], reason: "one",
                                                   timeout: .milliseconds(20))
        #expect(first == .timedOut)
        #expect(controller.requests.count == 1)
        _ = await controller.requestAccess(session: session, apps: ["com.apple.Safari", "com.apple.Notes"],
                                           reason: nil, timeout: .zero)
        #expect(controller.requests.count == 1)
        #expect(controller.requests[0].apps == ["com.apple.Notes", "com.apple.Safari"])
        #expect(controller.requests[0].reason == "one")
    }

    @Test func aLockedCallJoiningAnExplicitRequestDoesntEndIt() async {
        let session = Fixtures.session("a")
        _ = await controller.requestAccess(session: session, apps: [], reason: nil, timeout: .zero)
        let lease = await controller.waitForUnlock(session: session, tool: "x", timeout: .milliseconds(20))
        #expect(lease == nil)
        #expect(controller.requests.count == 1)
    }

    @Test func extendingAnswersARequestForMoreTime() async {
        let session = Fixtures.session("a")
        grant(session)
        async let answer = controller.requestAccess(session: session, apps: [], reason: "nearly there",
                                                    timeout: .seconds(5))
        while controller.requests.isEmpty { await Task.yield() }
        controller.applyExtension(sessionID: session.id, by: .seconds(60))
        #expect(await answer.lease != nil)
        #expect(controller.requests.isEmpty)
    }

    @Test func zeroWaitFailsAtOnce() async {
        let lease = await controller.waitForUnlock(session: Fixtures.session(), tool: "x", timeout: .zero)
        #expect(lease == nil)
        #expect(controller.requests.isEmpty)
    }

    @Test func aNewControllerStartsLocked() {
        grant()
        let fresh = LeaseController(clock: clock, authenticator: auth)
        #expect(fresh.leases.isEmpty)
    }
}
