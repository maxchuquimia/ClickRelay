import Foundation
import Observation

/// How a person at the Mac proves they're there.
nonisolated enum UnlockMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    /// `.deviceOwnerAuthenticationWithBiometrics`.
    case touchID
    /// `.deviceOwnerAuthentication`: Touch ID, or the login password.
    case touchIDOrPassword
    /// A press-and-hold on a button that refuses automated presses.
    case authorizeButton

    var id: String { rawValue }

    var label: String {
        switch self {
        case .touchID: "Touch ID"
        case .touchIDOrPassword: "Touch ID or password"
        case .authorizeButton: "Authorize button"
        }
    }
}

/// Why a lease ended. Recorded in the audit log.
nonisolated enum LockReason: String, Codable, Sendable {
    case expired
    case lockNow
    case killShortcut
    case screenLocked
    case screensaver
    case sleep
    case sessionResigned
    case allowedAppsQuit
    case idle
    case disconnected
    case replaced
    case appQuit
    case permissionRevoked
    /// The agent said it was done and gave its access back.
    case released

    var label: String {
        switch self {
        case .expired: "time ran out"
        case .lockNow: "Lock now"
        case .killShortcut: "kill shortcut"
        case .screenLocked: "screen locked"
        case .screensaver: "screensaver started"
        case .sleep: "Mac went to sleep"
        case .sessionResigned: "switched user"
        case .allowedAppsQuit: "every allowed app quit"
        case .idle: "no calls for a while"
        case .disconnected: "agent disconnected"
        case .replaced: "unlocked again"
        case .appQuit: "ClickRelay quit"
        case .permissionRevoked: "a permission was turned off"
        case .released: "the agent finished"
        }
    }

    /// Whether this ends every session's lease at once.
    var isGlobal: Bool {
        switch self {
        case .lockNow, .killShortcut, .screenLocked, .screensaver, .sleep, .sessionResigned, .appQuit,
             .permissionRevoked:
            true
        case .expired, .allowedAppsQuit, .idle, .disconnected, .replaced, .released:
            false
        }
    }
}

/// One unlock for one agent session. Lives only in memory: quitting or
/// crashing the app always leaves ClickRelay locked.
nonisolated struct Lease: Identifiable, Sendable, Equatable {
    let id: UUID
    let sessionID: String
    let policy: AccessPolicy
    let startedAt: ContinuousClock.Instant
    var expiresAt: ContinuousClock.Instant
    let method: UnlockMethod
    /// Wall-clock start, for display and the log.
    let startedDate: Date
    /// The last tool call, for the idle lock.
    var lastCallAt: ContinuousClock.Instant
    /// Whether the one-minute warning has gone out for the current expiry.
    var warned = false

    var allowedBundleIDs: Set<String> { policy.allowedBundleIDs }

    func remaining(at now: ContinuousClock.Instant) -> Duration {
        max(.zero, expiresAt - now)
    }

    /// Wall-clock expiry, for countdowns on screen. Worked out from the start
    /// so it doesn't drift between redraws.
    var endDate: Date {
        let length = expiresAt - startedAt
        return startedDate.addingTimeInterval(Double(length.components.seconds)
                                              + Double(length.components.attoseconds) / 1e18)
    }
}

/// A connected agent, as the bridge introduced it.
nonisolated struct AgentSession: Identifiable, Sendable, Equatable {
    /// The bridge's session ID.
    let id: String
    var clientName: String
    var workingDirectory: String?
    var termProgram: String?
    var parentPID: Int32?
    /// The terminal or editor the agent runs in (`Denylist.agentHostApps`).
    var hostBundleIDs: Set<String>
    var connectedAt: Date

    /// "Claude Code in ~/xcode/Foo".
    var displayName: String {
        guard let workingDirectory else { return clientName }
        return "\(clientName) in \(MCPLocal.abbreviatingHome(workingDirectory))"
    }
}

/// The user's attention, asked for by an agent: a call held while locked, or
/// an explicit `clickrelay_request_access`.
nonisolated struct AccessRequest: Identifiable, Sendable, Equatable {
    let id: UUID
    let session: AgentSession
    var tool: String
    /// The app the call is aimed at, when ClickRelay can tell (a window ID or
    /// a bundle ID in its arguments). Only shown to the user; it never ticks
    /// anything.
    var targetBundleID: String? = nil
    /// Apps the agent asked for by name. Shown only, never ticked.
    var apps: [String] = []
    /// The agent's own words about why, shown in quotes.
    var reason: String? = nil
    let createdAt: Date
    /// When the last waiting call gives up. `nil` for an explicit request,
    /// which stays on screen until the user answers it.
    var deadline: Date? = nil
    /// Made with `clickrelay_request_access` rather than by a locked call.
    var explicit = false

    /// Every app the request names, the call's target first.
    var namedApps: [String] {
        var list: [String] = []
        for id in [targetBundleID].compactMap({ $0 }) + apps where !list.contains(id) { list.append(id) }
        return list
    }
}

/// How a wait on a request ended.
nonisolated enum RequestOutcome: Sendable, Equatable {
    case granted(Lease)
    /// The user chose Not Now.
    case dismissed
    /// This call's wait ran out. An explicit request stays on screen.
    case timedOut
    /// The session went away.
    case disconnected

    var lease: Lease? {
        if case .granted(let lease) = self { return lease }
        return nil
    }
}

/// Time source for leases, so tests can move time on.
protocol LeaseClock: Sendable {
    var now: ContinuousClock.Instant { get }
}

nonisolated struct SystemLeaseClock: LeaseClock {
    var now: ContinuousClock.Instant { .now }
}

nonisolated enum AuthOutcome: Sendable, Equatable {
    case success
    case cancelled
    case failed(String)
}

/// Asks the person at the Mac to confirm, by whichever method is set.
@MainActor
protocol Authenticator: AnyObject {
    func authenticate(method: UnlockMethod, reason: String) async -> AuthOutcome
}

/// Owns every lease. All access goes through `activeLease(for:)`: no lease
/// means every tool except `clickrelay_status` fails.
@MainActor
@Observable
final class LeaseController {
    private(set) var leases: [String: Lease] = [:]
    /// Calls waiting for an unlock, oldest first. The main window shows the
    /// first as a banner.
    private(set) var requests: [AccessRequest] = []

    /// Optional idle lock: no calls for this long ends the lease.
    var idleTimeout: Duration?

    @ObservationIgnored let clock: LeaseClock
    @ObservationIgnored weak var authenticator: Authenticator?

    // Hooks for the app: cleanup, audit, notifications, Dock attention.
    @ObservationIgnored var onLeaseStarted: ((Lease) -> Void)?
    @ObservationIgnored var onLeaseExtended: ((Lease, Duration) -> Void)?
    @ObservationIgnored var onLeaseEnded: ((Lease, LockReason) -> Void)?
    @ObservationIgnored var onExpiryWarning: ((Lease) -> Void)?
    @ObservationIgnored var onRequestsChanged: (([AccessRequest]) -> Void)?
    /// A request ran out of time before the user answered (not dismissed).
    @ObservationIgnored var onRequestTimedOut: ((AccessRequest) -> Void)?

    /// Waiting calls by request, then by waiter. Each has its own timeout.
    @ObservationIgnored private var waiters: [UUID: [UUID: CheckedContinuation<RequestOutcome, Never>]] = [:]
    @ObservationIgnored private var timer: DispatchSourceTimer?

    /// How long before expiry the warning goes out.
    static let warningLead: Duration = .seconds(60)

    init(clock: LeaseClock = SystemLeaseClock(), authenticator: Authenticator? = nil) {
        self.clock = clock
        self.authenticator = authenticator
    }

    // MARK: - Reading

    /// The session's lease if it's still valid. Re-checks expiry and idle on
    /// every call, so a missed timer tick can't keep a lease alive.
    func activeLease(for sessionID: String) -> Lease? {
        guard let lease = leases[sessionID] else { return nil }
        if let reason = endReason(for: lease) {
            end(sessionID: sessionID, reason: reason)
            return nil
        }
        return lease
    }

    var isAnyUnlocked: Bool { !leases.isEmpty }

    func remaining(for sessionID: String) -> Duration? {
        leases[sessionID].map { $0.remaining(at: clock.now) }
    }

    /// Notes a tool call, for the idle lock.
    func recordCall(sessionID: String) {
        guard leases[sessionID] != nil else { return }
        leases[sessionID]?.lastCallAt = clock.now
    }

    // MARK: - Unlocking

    /// Asks the person to confirm, then grants each session its own lease with
    /// the same apps and duration. Nothing an agent sends can reach this: only
    /// the main window and the request banner call it.
    @discardableResult
    func unlock(sessions: [AgentSession], picked: Set<String>, allowFilePanels: Bool,
                denyAgentHosts: Bool, duration: Duration, method: UnlockMethod,
                reason: String) async -> AuthOutcome {
        guard !sessions.isEmpty, duration > .zero else { return .failed("Nothing to unlock") }
        guard let authenticator else { return .failed("No way to confirm it's you") }
        let outcome = await authenticator.authenticate(method: method, reason: reason)
        guard outcome == .success else { return outcome }
        grant(sessions: sessions, picked: picked, allowFilePanels: allowFilePanels,
              denyAgentHosts: denyAgentHosts, duration: duration, method: method)
        return .success
    }

    /// Creates the leases. Separate from `unlock` so tests can skip the
    /// authenticator; never call it from anything an agent can reach.
    func grant(sessions: [AgentSession], picked: Set<String>, allowFilePanels: Bool,
               denyAgentHosts: Bool, duration: Duration, method: UnlockMethod) {
        let now = clock.now
        for session in sessions {
            if leases[session.id] != nil { end(sessionID: session.id, reason: .replaced) }
            let policy = AccessPolicy.build(picked: picked, allowFilePanels: allowFilePanels,
                                            agentHosts: session.hostBundleIDs,
                                            denyAgentHosts: denyAgentHosts)
            let lease = Lease(id: UUID(), sessionID: session.id, policy: policy,
                              startedAt: now, expiresAt: now + duration, method: method,
                              startedDate: Date(), lastCallAt: now)
            leases[session.id] = lease
            onLeaseStarted?(lease)
            resolveRequests(for: session.id, with: .granted(lease))
        }
    }

    /// Adds `duration` to a lease, after the person confirms again.
    @discardableResult
    func extend(sessionID: String, by duration: Duration, reason: String) async -> AuthOutcome {
        guard let lease = activeLease(for: sessionID) else { return .failed("Already locked") }
        guard let authenticator else { return .failed("No way to confirm it's you") }
        let outcome = await authenticator.authenticate(method: lease.method, reason: reason)
        guard outcome == .success else { return outcome }
        applyExtension(sessionID: sessionID, by: duration)
        return .success
    }

    func applyExtension(sessionID: String, by duration: Duration) {
        // The lease may have ended while the prompt was up.
        guard var lease = activeLease(for: sessionID) else { return }
        lease.expiresAt = max(lease.expiresAt, clock.now) + duration
        lease.warned = false
        leases[sessionID] = lease
        onLeaseExtended?(lease, duration)
        // An agent asking for more time has its answer.
        resolveRequests(for: sessionID, with: .granted(lease))
    }

    // MARK: - Locking

    func lock(sessionID: String, reason: LockReason) {
        end(sessionID: sessionID, reason: reason)
        if reason == .disconnected { resolveRequests(for: sessionID, with: .disconnected) }
    }

    /// Ends every session's lease at once.
    func lockAll(reason: LockReason) {
        for sessionID in Array(leases.keys) { end(sessionID: sessionID, reason: reason) }
    }

    /// An app quit. A lease ends when an app it allows quits and none of its
    /// allowed apps are left running. A lease for apps that weren't running
    /// yet (to be opened with `launch_app`) isn't ended by unrelated quits.
    func appTerminated(bundleID: String?, runningBundleIDs: Set<String>) {
        guard let bundleID else { return }
        for lease in Array(leases.values) where lease.allowedBundleIDs.contains(bundleID) {
            let userApps = lease.allowedBundleIDs.subtracting(AccessPolicy.filePanelServices)
            if userApps.isDisjoint(with: runningBundleIDs) {
                end(sessionID: lease.sessionID, reason: .allowedAppsQuit)
            }
        }
    }

    private func end(sessionID: String, reason: LockReason) {
        guard let lease = leases.removeValue(forKey: sessionID) else { return }
        onLeaseEnded?(lease, reason)
    }

    private func endReason(for lease: Lease) -> LockReason? {
        let now = clock.now
        if now >= lease.expiresAt { return .expired }
        if let idleTimeout, now - lease.lastCallAt >= idleTimeout { return .idle }
        return nil
    }

    // MARK: - Timer

    /// Checks expiry once a second. Every call checks again on its own, so
    /// this only has to be close.
    func startTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.resume()
        self.timer = timer
    }

    func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    func tick() {
        let now = clock.now
        for lease in Array(leases.values) {
            if let reason = endReason(for: lease) {
                end(sessionID: lease.sessionID, reason: reason)
            } else if !lease.warned, lease.remaining(at: now) <= Self.warningLead {
                leases[lease.sessionID]?.warned = true
                onExpiryWarning?(lease)
            }
        }
    }

    // MARK: - Waiting for an unlock

    /// Holds a call made while locked until the user unlocks this session or
    /// `timeout` passes. Calls from the same session share one request (one
    /// card, one Dock bounce); each gives up on its own.
    func waitForUnlock(session: AgentSession, tool: String, targetBundleID: String? = nil,
                       timeout: Duration) async -> Lease? {
        if let lease = activeLease(for: session.id) { return lease }
        guard timeout > .zero else { return nil }
        let now = Date()
        let deadline = now.addingTimeInterval(Self.seconds(timeout))
        let id: UUID
        if let index = requests.firstIndex(where: { $0.session.id == session.id }) {
            id = requests[index].id
            if !requests[index].explicit, let current = requests[index].deadline,
               deadline.timeIntervalSince(current) >= 1 {
                requests[index].deadline = deadline
                onRequestsChanged?(requests)
            }
        } else {
            let request = AccessRequest(id: UUID(), session: session, tool: tool, targetBundleID: targetBundleID,
                                        createdAt: now, deadline: deadline)
            id = request.id
            requests.append(request)
            onRequestsChanged?(requests)
        }
        return await wait(on: id, timeout: timeout).lease
    }

    /// `clickrelay_request_access`: puts a request on screen (or adds to the
    /// session's current one) that stays until the user answers, and waits up
    /// to `timeout` for that answer. Works with or without a lease; only an
    /// unlock from the window resolves it. Never grants anything itself.
    func requestAccess(session: AgentSession, apps: [String], reason: String?,
                       timeout: Duration) async -> RequestOutcome {
        let id: UUID
        if let index = requests.firstIndex(where: { $0.session.id == session.id }) {
            var request = requests[index]
            for app in apps where !request.apps.contains(app) { request.apps.append(app) }
            if let reason { request.reason = reason }
            request.tool = "clickrelay_request_access"
            request.explicit = true
            request.deadline = nil
            requests[index] = request
            id = request.id
        } else {
            let request = AccessRequest(id: UUID(), session: session, tool: "clickrelay_request_access",
                                        apps: apps, reason: reason, createdAt: Date(), explicit: true)
            requests.append(request)
            id = request.id
        }
        onRequestsChanged?(requests)
        guard timeout > .zero else { return .timedOut }
        return await wait(on: id, timeout: timeout)
    }

    private func wait(on requestID: UUID, timeout: Duration) async -> RequestOutcome {
        let waiterID = UUID()
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.waiterTimedOut(requestID: requestID, waiterID: waiterID)
        }
        return await withCheckedContinuation { continuation in
            waiters[requestID, default: [:]][waiterID] = continuation
        }
    }

    /// One call stopped waiting. A request made by locked calls goes when the
    /// last of them gives up; an explicit one stays for the user.
    private func waiterTimedOut(requestID: UUID, waiterID: UUID) {
        guard let continuation = waiters[requestID]?.removeValue(forKey: waiterID) else { return }
        continuation.resume(returning: .timedOut)
        guard waiters[requestID]?.isEmpty ?? true,
              let index = requests.firstIndex(where: { $0.id == requestID }),
              !requests[index].explicit else { return }
        waiters[requestID] = nil
        let request = requests.remove(at: index)
        onRequestsChanged?(requests)
        onRequestTimedOut?(request)
    }

    /// The user chose Not Now.
    func dismissRequest(_ id: UUID) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        requests.remove(at: index)
        onRequestsChanged?(requests)
        for waiter in (waiters.removeValue(forKey: id) ?? [:]).values { waiter.resume(returning: .dismissed) }
    }

    private func resolveRequests(for sessionID: String, with outcome: RequestOutcome) {
        let matching = requests.filter { $0.session.id == sessionID }
        guard !matching.isEmpty else { return }
        requests.removeAll { $0.session.id == sessionID }
        onRequestsChanged?(requests)
        for request in matching {
            for waiter in (waiters.removeValue(forKey: request.id) ?? [:]).values { waiter.resume(returning: outcome) }
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
