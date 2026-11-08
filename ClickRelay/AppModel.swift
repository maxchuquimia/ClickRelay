import AppKit
import Observation

/// One row of the activity feed.
struct ActivityItem: Identifiable {
    let id = UUID()
    let date: Date
    let sessionID: String
    let sessionName: String
    let tool: String
    let target: String?
    let outcome: AuditEntry.Outcome
    let message: String?
    let thumbnail: NSImage?
    /// What it typed, pressed or said, when that's short enough to show.
    var detail: String? = nil
    /// The full screenshot as the agent got it, for Quick Look. Kept only for
    /// the most recent screenshots (`fullImageLimit`).
    var image: (data: Data, fileExtension: String)?
    /// For a step run by a script: "export-log.json, step 3".
    var script: String? = nil
}

/// What an agent said with `clickrelay_notify`.
struct AgentNotice: Identifiable, Equatable, Sendable {
    enum Kind: Sendable { case done, needsYou }

    var id: String { sessionID }
    let sessionID: String
    let kind: Kind
    let message: String
    let date: Date
}

/// How a session's last lease ended, for its locked card.
struct LockRecord: Equatable {
    let date: Date
    let reason: LockReason
    let apps: [String]
    let allowFilePanels: Bool
    let minutes: Int
    let calls: Int
    let refused: Int
}

/// The root coordinator: leases, sessions, the MCP server, the audit log and
/// what the windows show. Start here to trace any feature.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let preferences: Preferences
    let leases: LeaseController
    let handOffs: HandOffController
    let authenticator: SystemAuthenticator
    @ObservationIgnored let router: ToolRouter
    @ObservationIgnored let auditLog: AuditLog
    @ObservationIgnored private(set) var server: MCPServer!
    @ObservationIgnored let overlay: OverlayController
    @ObservationIgnored private(set) var alertPanel: AlertPanelController!
    @ObservationIgnored private var handOffPanels: HandOffPanelController!
    /// Hand-offs the user has already been alerted to.
    @ObservationIgnored private var shownHandOffs: Set<UUID> = []
    @ObservationIgnored private var triggers: LockTriggerMonitor!
    @ObservationIgnored private let killShortcut = KillShortcut()
    @ObservationIgnored private let notifier = ExpiryNotifier()
    @ObservationIgnored private var attentionRequest: Int?
    /// Requests the alert panel has already popped up for.
    @ObservationIgnored private var shownRequests: Set<UUID> = []
    @ObservationIgnored private var badgeTimer: Timer?
    @ObservationIgnored private var started = false

    /// Connected agents, oldest first.
    private(set) var sessions: [AgentSession] = []
    /// Newest first, capped.
    private(set) var activity: [ActivityItem] = []
    private(set) var permissions = Permissions.current
    private(set) var serverError: String?
    /// Programs the socket turned away that are still running.
    private(set) var rejectedPeers = 0
    /// Of those, agents still using a ClickRelay bridge from before an update.
    private(set) var outdatedBridges = 0
    /// Last unlock failure, shown under the unlock buttons.
    var unlockError: String?

    /// Sessions that disconnected after making calls, newest first, so their
    /// calls can still be read. Cleared at launch.
    private(set) var pastSessions: [AgentSession] = []
    /// How each session's last lease ended.
    private(set) var lastLocks: [String: LockRecord] = [:]
    /// Requests that ran out of time before the user answered, by session.
    private(set) var gaveUp: [String: AccessRequest] = [:]
    /// What each agent last said with `clickrelay_notify`, until the user
    /// dismisses it or the agent makes another call.
    private(set) var notices: [String: AgentNotice] = [:]
    /// What the user has typed so far as a note back on each open hand-off.
    var handOffNotes: [String: String] = [:]
    static let maxHandOffNote = 300

    /// The agent shown in the main window.
    private(set) var selectedSessionID: String?
    /// When the user last touched the unlock card, so an arriving request
    /// doesn't swap it out from under them.
    @ObservationIgnored private var lastCardEdit: Date?

    // The unlock card's choices, for whichever agent is shown.
    var selectedApps: Set<String> = [] { didSet { lastCardEdit = Date() } }
    var selectedFilePanels = false { didSet { lastCardEdit = Date() } }
    var selectedMinutes = 5 { didSet { lastCardEdit = Date() } }

    /// Opens (or brings back) the main window. Set by the window itself,
    /// since SwiftUI only hands out `openWindow` to views.
    @ObservationIgnored var openMainWindow: (() -> Void)?

    /// Across all sessions, newest dropped last.
    static let activityLimit = 2000
    /// Full-size screenshots kept for Quick Look; older ones keep only their thumbnail.
    static let fullImageLimit = 40

    /// Where Quick Look previews are written. In the per-user temporary
    /// folder (not readable by other users), and removed at quit.
    static var previewDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: "ClickRelay-Previews", directoryHint: .isDirectory)
    }

    /// A file Quick Look can open for this item's screenshot.
    func previewURL(for item: ActivityItem) -> URL? {
        guard let image = item.image else { return nil }
        let directory = Self.previewDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let url = directory.appending(path: "\(item.id.uuidString).\(image.fileExtension)")
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: image.data,
                                           attributes: [.posixPermissions: 0o600])
        }
        return url
    }

    func activity(for sessionID: String) -> [ActivityItem] {
        activity.filter { $0.sessionID == sessionID }
    }

    func clearActivity(for sessionID: String) {
        activity.removeAll { $0.sessionID == sessionID }
        if pastSessions.contains(where: { $0.id == sessionID }) {
            pastSessions.removeAll { $0.id == sessionID }
            if selectedSessionID == sessionID { select(sessions.first?.id) }
        }
    }

    /// A connected or past session by ID.
    func anySession(_ id: String) -> AgentSession? {
        session(id) ?? pastSessions.first { $0.id == id }
    }

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    init(preferences: Preferences = Preferences(), auditLog: AuditLog = AuditLog()) {
        self.preferences = preferences
        self.auditLog = auditLog
        let authenticator = SystemAuthenticator()
        self.authenticator = authenticator
        let leases = LeaseController(authenticator: authenticator)
        self.leases = leases
        let handOffs = HandOffController()
        self.handOffs = handOffs
        self.router = ToolRouter(leases: leases, preferences: preferences, handOffs: handOffs)
        self.overlay = OverlayController(preferences: preferences)
        self.server = MCPServer(backend: self)
        self.alertPanel = AlertPanelController(model: self)
        self.handOffPanels = HandOffPanelController(model: self)
        handOffs.onChanged = { [weak self] in self?.handOffsChanged() }
        self.triggers = LockTriggerMonitor(
            onTrigger: { [weak self] reason in self?.leases.lockAll(reason: reason) },
            onAppTerminated: { [weak self] bundleID in self?.appTerminated(bundleID) })
        wireLeaseHooks()
        selectedApps = Set(preferences.lastAllowedApps)
        selectedFilePanels = preferences.allowFilePanels
        selectedMinutes = preferences.leaseDurationMinutes
        lastCardEdit = nil
    }

    /// Sessions without a lease, which the unlock screen offers.
    var lockedSessions: [AgentSession] {
        sessions.filter { leases.leases[$0.id] == nil }
    }

    /// Unlocks the agent on screen with what's ticked on its card. If it's
    /// asking, its waiting call continues.
    func unlockSelected(sessionID: String) async {
        await unlock(sessionIDs: [sessionID], apps: Array(selectedApps),
                     allowFilePanels: selectedFilePanels, minutes: selectedMinutes)
        if leases.leases[sessionID] != nil { gaveUp[sessionID] = nil }
    }

    // MARK: - Selection

    /// Shows an agent's card. Its draft starts from how it was last unlocked,
    /// or the last apps used anywhere.
    func select(_ sessionID: String?) {
        guard sessionID != selectedSessionID else { return }
        selectedSessionID = sessionID
        unlockError = nil
        resetDraft(for: sessionID)
    }

    private func resetDraft(for sessionID: String?) {
        if let sessionID, let record = lastLocks[sessionID] {
            selectedApps = Set(record.apps)
            selectedFilePanels = record.allowFilePanels
        } else {
            selectedApps = Set(preferences.lastAllowedApps)
            selectedFilePanels = preferences.allowFilePanels
        }
        selectedMinutes = preferences.leaseDurationMinutes
        lastCardEdit = nil
    }

    /// Whether the user touched the card in the last few seconds.
    private var isEditingCard: Bool {
        lastCardEdit.map { Date().timeIntervalSince($0) < 8 } ?? false
    }

    /// Ticks the apps another session's lease has.
    func useApps(from sessionID: String) {
        guard let lease = leases.leases[sessionID] else { return }
        selectedApps = lease.allowedBundleIDs.subtracting(AccessPolicy.filePanelServices)
        selectedFilePanels = !lease.allowedBundleIDs.isDisjoint(with: AccessPolicy.filePanelServices)
    }

    /// The allowlist can't change during a lease, so "Change apps" locks the
    /// agent and leaves its current apps ticked for the next unlock.
    func changeApps(sessionID: String) {
        guard let lease = leases.leases[sessionID] else { return }
        lock(sessionID: sessionID)
        selectedApps = lease.allowedBundleIDs.subtracting(AccessPolicy.filePanelServices)
        selectedFilePanels = !lease.allowedBundleIDs.isDisjoint(with: AccessPolicy.filePanelServices)
    }

    func dismissGaveUp(sessionID: String) {
        gaveUp[sessionID] = nil
    }

    // MARK: - Notices and alerts

    private func noticeArrived(_ notice: AgentNotice) {
        notices[notice.sessionID] = notice
        NSApp.requestUserAttention(.informationalRequest)
        alertPanel.show()
    }

    func dismissNotice(sessionID: String) {
        notices[sessionID] = nil
        alertPanel.refresh()
    }

    /// Everything waiting for the user, for the panel under the menu bar
    /// item: hand-offs, then requests, oldest first, then notices, newest first.
    var alerts: [AgentAlert] {
        handOffs.handOffs.values.sorted { $0.createdAt < $1.createdAt }.map(AgentAlert.handOff)
            + leases.requests.map(AgentAlert.request)
            + notices.values.sorted { $0.date > $1.date }.map(AgentAlert.notice)
    }

    // MARK: - Hand-offs

    private func handOffsChanged() {
        let open = handOffs.handOffs
        overlay.handOffRings = open.values.map {
            OverlayController.HandOffRing(windowID: $0.windowID, elementFrame: $0.elementFrame)
        }
        handOffPanels.update()
        for sessionID in handOffNotes.keys where open[sessionID] == nil { handOffNotes[sessionID] = nil }
        let new = open.values.filter { !shownHandOffs.contains($0.id) }
        shownHandOffs = Set(open.values.map(\.id))
        alertPanel.refresh(showingNew: !new.isEmpty)
        guard let first = new.first, !Self.isRunningTests else { return }
        NSApp.requestUserAttention(.informationalRequest)
        if selectedSessionID != first.sessionID, !isEditingCard { select(first.sessionID) }
    }

    /// The user pressed Done or Can't Do This, with whatever note they wrote.
    func answerHandOff(sessionID: String, done: Bool) {
        let note = handOffNotes[sessionID]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = note.flatMap { $0.isEmpty ? nil : String($0.prefix(Self.maxHandOffNote)) }
        handOffs.finish(sessionID: sessionID, done ? .done(note: trimmed) : .cantDo(note: trimmed))
    }

    /// Brings the hand-off's window to the front for the user.
    func showHandOff(sessionID: String) {
        guard let handOff = handOffs.handOffs[sessionID] else { return }
        let pid = handOff.pid, id = handOff.windowID
        guard let window = SystemWindowCatalog().snapshot().window(id) else {
            NSRunningApplication(processIdentifier: pid)?.activate()
            return
        }
        Task {
            await Task.detached {
                if let element = AXQuery.windowElement(pid: pid, windowID: id, frame: window.frame, title: window.title) {
                    AXUIElementPerformAction(element.element, kAXRaiseAction as CFString)
                }
            }.value
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
    }

    /// Once a second: a closed window ends its hand-off, the idle lock
    /// doesn't count time the user spends on one, and the ring and callout
    /// follow the element as it moves.
    private func checkHandOffs() {
        guard handOffs.isAnyOpen else { return }
        let snapshot = SystemWindowCatalog().snapshot()
        for (sessionID, handOff) in handOffs.handOffs {
            leases.recordCall(sessionID: sessionID)
            guard Self.windowExists(handOff.windowID) else {
                handOffs.finish(sessionID: sessionID, .windowClosed)
                continue
            }
            if let element = handOff.element, let window = snapshot.window(handOff.windowID) {
                let origin = window.frame.origin
                Task { [weak self] in
                    let frame = await Task.detached { AXQuery.frame(of: element.element) }.value
                    guard let frame else { return }
                    self?.handOffs.updateElementFrame(sessionID: sessionID,
                                                      frame.offsetBy(dx: -origin.x, dy: -origin.y))
                }
            }
        }
        handOffPanels.update()
    }

    /// Whether a window still exists, on any Space, minimised or not.
    private static func windowExists(_ id: CGWindowID) -> Bool {
        let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] ?? []
        return list.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }
    }

    /// Opens the main window on an agent.
    func reveal(sessionID: String) {
        select(sessionID)
        openMainWindow?()
        showMainWindow(activate: true)
    }

    func request(for sessionID: String) -> AccessRequest? {
        leases.requests.first { $0.session.id == sessionID }
    }

    // MARK: - Lifecycle

    func start() {
        guard !started, !Self.isRunningTests else { return }
        started = true
        AXQuery.configureTimeout()
        leases.idleTimeout = preferences.idleTimeout
        leases.startTimer()
        triggers.start()
        applyKillShortcut()
        notifier.configure()
        notifier.onExtend = { [weak self] sessionID in
            Task { await self?.extend(sessionID: sessionID) }
        }
        notifier.onLock = { [weak self] sessionID in
            self?.lock(sessionID: sessionID)
        }
        router.overlayWindowIDs = { [weak self] in self?.overlay.windowIDs ?? [] }
        router.onNotify = { [weak self] notice in self?.noticeArrived(notice) }
        overlay.tagProvider = { [weak self] bundleID in self?.overlayTag(for: bundleID) }
        router.onScriptStep = { [weak self] step in
            self?.recordScriptStep(step)
        }
        router.onClick = { [weak self] point in
            guard let self, self.preferences.showClickHighlights else { return }
            self.overlay.flashClick(at: point)
        }
        server.onStateChanged = { [weak self] in
            guard let self else { return }
            self.serverError = self.server.lastError
            self.rejectedPeers = self.server.rejectedPeers.count
            self.outdatedBridges = self.server.outdatedBridges.count
        }
        server.start()
        let retention = preferences.auditRetentionDays
        Task { await auditLog.purge(olderThanDays: retention) }
        badgeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateBadge() }
        }
    }

    func shutdown() {
        try? FileManager.default.removeItem(at: Self.previewDirectory)
        leases.lockAll(reason: .appQuit)
        server?.stop()
        let log = auditLog
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await log.flush()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 1)
    }

    func refreshPermissions() {
        permissions = Permissions.current
        // Without both permissions nothing can be checked properly, so end
        // every lease rather than run half-blind.
        if !permissions.allGranted, leases.isAnyUnlocked {
            leases.lockAll(reason: .permissionRevoked)
        }
    }

    func finishSetup() {
        preferences.setupFinished = true
    }

    func applyKillShortcut() {
        killShortcut.register(preferences.killShortcut) { [weak self] in
            MainActor.assumeIsolated { self?.leases.lockAll(reason: .killShortcut) }
        }
    }

    /// While Settings records a new kill shortcut.
    func suspendKillShortcut() {
        killShortcut.unregister()
    }

    func applyIdleTimeout() {
        leases.idleTimeout = preferences.idleTimeout
    }

    // MARK: - Unlocking

    var unlockBlockedReason: String? {
        if !permissions.allGranted {
            return "ClickRelay needs \(permissions.missing.joined(separator: " and ")) before it can unlock."
        }
        if sessions.isEmpty { return "No agent is connected yet." }
        return nil
    }

    /// Why the card's Unlock button is disabled, if it is.
    func cardBlockedReason(sessionID: String) -> String? {
        if let reason = unlockBlockedReason { return reason }
        if session(sessionID) == nil { return "This agent has disconnected." }
        if selectedApps.filter({ !Denylist.isDenied($0) }).isEmpty { return "Tick at least one app." }
        return nil
    }

    /// Why an app can't be ticked for this session, if it can't.
    func deniedReason(_ bundleID: String, for session: AgentSession?) -> String? {
        Denylist.reason(for: bundleID, agentHosts: session?.hostBundleIDs ?? [])
    }

    /// "allow Claude Code in ~/xcode/Foo to see and control Simulator and Safari for 5 minutes"
    func unlockReason(sessions: [AgentSession], apps: [String], minutes: Int) -> String {
        let who = sessions.count == 1 ? sessions[0].displayName : "\(sessions.count) agents"
        return "allow \(who) to see and control \(Self.list(apps.map(AppCatalog.name(for:)))) for \(Self.durationText(minutes: minutes))"
    }

    /// "Simulator", "Simulator and Safari", "Notes, Simulator and Safari".
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return "no apps"
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }

    /// "5 min", "1 h", "1 h 30 min", for buttons.
    static func shortDuration(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        if minutes % 60 == 0 { return "\(minutes / 60) h" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    static func durationText(minutes: Int) -> String {
        if minutes % 60 == 0 { return minutes == 60 ? "1 hour" : "\(minutes / 60) hours" }
        if minutes > 60 { return "\(minutes / 60) h \(minutes % 60) min" }
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    func unlock(sessionIDs: [String], apps: [String], allowFilePanels: Bool, minutes: Int) async {
        unlockError = nil
        if let reason = unlockBlockedReason {
            unlockError = reason
            return
        }
        let chosen = sessions.filter { sessionIDs.contains($0.id) }
        guard !chosen.isEmpty else {
            unlockError = "Pick which agent to unlock for."
            return
        }
        let allowed = apps.filter { !Denylist.isDenied($0) }
        guard !allowed.isEmpty else {
            unlockError = "Pick at least one app to allow."
            return
        }
        preferences.lastAllowedApps = allowed
        preferences.leaseDurationMinutes = minutes
        preferences.allowFilePanels = allowFilePanels
        notifier.requestAuthorizationIfNeeded()
        let outcome = await leases.unlock(
            sessions: chosen, picked: Set(allowed), allowFilePanels: allowFilePanels,
            denyAgentHosts: true, duration: .seconds(minutes * 60),
            method: preferences.unlockMethod,
            reason: unlockReason(sessions: chosen, apps: allowed, minutes: minutes))
        if case .failed(let message) = outcome { unlockError = message }
    }

    func extend(sessionID: String) async {
        guard let lease = leases.leases[sessionID] else { return }
        let minutes = preferences.leaseDurationMinutes
        let agent = sessions.first { $0.id == sessionID }?.displayName ?? "the agent"
        let apps = lease.allowedBundleIDs.subtracting(AccessPolicy.filePanelServices).sorted()
        let reason = "give \(agent) \(Self.durationText(minutes: minutes)) more with "
            + apps.map(AppCatalog.name(for:)).joined(separator: ", ")
        let outcome = await leases.extend(sessionID: sessionID, by: .seconds(minutes * 60), reason: reason)
        if case .failed(let message) = outcome { unlockError = message }
    }

    func lockNow() {
        leases.lockAll(reason: .lockNow)
    }

    func lock(sessionID: String) {
        leases.lock(sessionID: sessionID, reason: .lockNow)
    }

    func session(_ id: String) -> AgentSession? {
        sessions.first { $0.id == id }
    }

    // MARK: - Lease hooks

    private func wireLeaseHooks() {
        leases.onLeaseStarted = { [weak self] lease in
            guard let self else { return }
            let session = self.session(lease.sessionID)
            self.log(AuditEntry(timestamp: Date(), event: .unlocked, leaseID: lease.id.uuidString,
                                sessionID: lease.sessionID, client: session?.clientName,
                                workingDirectory: session?.workingDirectory,
                                apps: lease.allowedBundleIDs.sorted(),
                                leaseSeconds: Int((lease.expiresAt - lease.startedAt).components.seconds),
                                method: lease.method.rawValue))
            self.leasesChanged()
        }
        leases.onLeaseExtended = { [weak self] lease, duration in
            guard let self else { return }
            self.notifier.clear(sessionID: lease.sessionID)
            self.log(AuditEntry(timestamp: Date(), event: .extended, leaseID: lease.id.uuidString,
                                sessionID: lease.sessionID, client: self.session(lease.sessionID)?.clientName,
                                leaseSeconds: Int(duration.components.seconds), method: lease.method.rawValue))
            self.leasesChanged()
        }
        leases.onLeaseEnded = { [weak self] lease, reason in
            guard let self else { return }
            // Let go of anything held and drop element refs before anything else.
            self.router.poster.releaseAll()
            self.router.leaseEnded(sessionID: lease.sessionID)
            self.notifier.clear(sessionID: lease.sessionID)
            self.recordLock(lease, reason: reason)
            self.log(AuditEntry(timestamp: Date(), event: .locked, leaseID: lease.id.uuidString,
                                sessionID: lease.sessionID, client: self.session(lease.sessionID)?.clientName,
                                reason: reason.rawValue))
            self.leasesChanged()
        }
        leases.onExpiryWarning = { [weak self] lease in
            guard let self else { return }
            let agent = self.session(lease.sessionID)?.displayName ?? "The agent"
            let apps = lease.allowedBundleIDs.subtracting(AccessPolicy.filePanelServices)
                .sorted().map(AppCatalog.name(for:))
            let until = Date().addingTimeInterval(Double(lease.remaining(at: self.leases.clock.now).components.seconds))
            self.notifier.notifyExpiring(sessionID: lease.sessionID, agent: agent, apps: apps, until: until,
                                         extendMinutes: self.preferences.leaseDurationMinutes)
        }
        leases.onRequestsChanged = { [weak self] requests in
            self?.requestsChanged(requests)
        }
        leases.onRequestTimedOut = { [weak self] request in
            guard let self, self.session(request.session.id) != nil else { return }
            self.gaveUp[request.session.id] = request
        }
    }

    private func recordLock(_ lease: Lease, reason: LockReason) {
        let calls = activity.filter { $0.sessionID == lease.sessionID && $0.date >= lease.startedDate }
        let seconds = Int((lease.expiresAt - lease.startedAt).components.seconds)
        lastLocks[lease.sessionID] = LockRecord(
            date: Date(), reason: reason,
            apps: lease.allowedBundleIDs.subtracting(AccessPolicy.filePanelServices).sorted(),
            allowFilePanels: !lease.allowedBundleIDs.isDisjoint(with: AccessPolicy.filePanelServices),
            minutes: max(1, seconds / 60), calls: calls.count,
            refused: calls.filter { $0.outcome != .ok }.count)
    }

    private func leasesChanged() {
        let allowed = leases.leases.values.reduce(into: Set<String>()) { $0.formUnion($1.allowedBundleIDs) }
        overlay.update(allowedBundleIDs: allowed)
        updateBadge()
    }

    /// The tab on the overlay border: who can use this app and for how long.
    func overlayTag(for bundleID: String) -> String? {
        let holding = leases.leases.values.filter { $0.allowedBundleIDs.contains(bundleID) }
        guard let longest = holding.map({ $0.remaining(at: leases.clock.now) }).max() else { return nil }
        let time = Self.clock(longest)
        if holding.count > 1 { return "\(holding.count) agents · \(time)" }
        let name = session(holding[0].sessionID)?.shortName ?? "Agent"
        return "\(name) · \(time)"
    }

    /// "3:41".
    static func clock(_ duration: Duration) -> String {
        let seconds = max(0, Int(duration.components.seconds))
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// The menu bar item's title: the longest time left, or nothing. Set by
    /// the one-second badge timer (a TimelineView in a MenuBarExtra label
    /// loops forever).
    private(set) var menuBarTime: String?

    private func requestsChanged(_ requests: [AccessRequest]) {
        for request in requests { gaveUp[request.session.id] = nil }
        // Show the asking agent, unless the user is busy with another card.
        if let first = requests.first, selectedSessionID != first.session.id,
           selectedSessionID.flatMap(request(for:)) == nil, !isEditingCard {
            select(first.session.id)
        }
        alertPanel.refresh(showingNew: requests.contains { request in
            !shownRequests.contains(request.id) })
        shownRequests = Set(requests.map(\.id))
        if requests.isEmpty {
            if let attentionRequest { NSApp.cancelUserAttentionRequest(attentionRequest) }
            attentionRequest = nil
        } else if attentionRequest == nil {
            // Keeps bouncing until ClickRelay is activated.
            attentionRequest = NSApp.requestUserAttention(.criticalRequest)
            showMainWindow(activate: false)
        }
    }

    /// Shows the main window, reopening it if it was closed.
    private(set) var checkingDirectCapture = false

    /// Whether setup still has something to do: a missing permission, or the
    /// direct-capture prompt not yet answered.
    var needsSetup: Bool {
        !permissions.allGranted || !preferences.directCaptureConfirmed
    }

    /// Triggers macOS's direct-capture prompt now, during setup.
    func confirmDirectCapture() async {
        guard permissions.screenRecording, !checkingDirectCapture else { return }
        checkingDirectCapture = true
        unlockError = nil
        let failure = await Screenshotter.probeDirectCapture()
        checkingDirectCapture = false
        preferences.directCaptureConfirmed = failure == nil
        if failure == nil { router.captureDeclined = false }
        if let failure {
            unlockError = "The test screenshot didn't go through (\(failure)). If macOS asked, choose Allow. "
                + "If it keeps failing, quit and reopen ClickRelay, then try again."
        }
    }

    func showMainWindow(activate: Bool) {
        let windows = NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("main") == true }
        if windows.isEmpty { openMainWindow?() }
        for window in windows { activate ? window.makeKeyAndOrderFront(nil) : window.orderFront(nil) }
        if activate { NSApp.activate() }
    }

    private func updateBadge() {
        // A permission turned off mid-lease locks within a second, not only
        // when ClickRelay next comes to the front.
        if leases.isAnyUnlocked { refreshPermissions() }
        let remaining = leases.leases.keys.compactMap { leases.remaining(for: $0) }.max()
        let title = remaining.map(Self.clock)
        if title != menuBarTime { menuBarTime = title }
        if let remaining {
            let minutes = Int((Double(remaining.components.seconds) / 60).rounded(.up))
            NSApp.dockTile.badgeLabel = "\(max(1, minutes))"
        } else {
            NSApp.dockTile.badgeLabel = nil
        }
        leases.tick()
        checkHandOffs()
        if rejectedPeers > 0 { server.forgetExitedPeers() }
    }

    private func appTerminated(_ bundleID: String?) {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        leases.appTerminated(bundleID: bundleID, runningBundleIDs: running)
    }

    // MARK: - Audit

    private func log(_ entry: AuditEntry, thumbnail: Data? = nil) {
        let log = auditLog
        Task { await log.append(entry, thumbnail: thumbnail) }
    }

    func showLogInFinder() {
        let url = AuditLog.defaultDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static func screenshot(in result: ToolResult) -> (data: Data, fileExtension: String)? {
        for content in result.content {
            if case .image(let data, let mimeType) = content {
                return (data, mimeType == "image/jpeg" ? "jpg" : "png")
            }
        }
        return nil
    }

    func clearActivity() {
        activity = []
        pastSessions = []
    }
}

// MARK: - MCPBackend

extension AppModel: MCPBackend {
    func sessionConnected(_ session: AgentSession) {
        sessions.removeAll { $0.id == session.id }
        sessions.append(session)
        preferences.hasConnectedAgent = true
        if selectedSessionID == nil || anySession(selectedSessionID!) == nil { select(session.id) }
    }

    func sessionDisconnected(_ sessionID: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let session = sessions.remove(at: index)
        leases.lock(sessionID: sessionID, reason: .disconnected)
        handOffs.finish(sessionID: sessionID, .locked)
        handOffs.forget(sessionID: sessionID)
        gaveUp[sessionID] = nil
        if notices[sessionID]?.kind == .needsYou { notices[sessionID] = nil }
        alertPanel.refresh()
        if activity.contains(where: { $0.sessionID == sessionID }) {
            pastSessions.insert(session, at: 0)
        } else if selectedSessionID == sessionID {
            select(sessions.first?.id)
        }
    }

    func callTool(name: String, arguments: ToolArguments, session: AgentSession) async -> ToolResult {
        let started = ContinuousClock.now
        if name != ToolName.notify.rawValue, notices[session.id] != nil {
            // It's working again, so whatever it said before is old news.
            notices[session.id] = nil
            alertPanel.refresh()
        }
        let outcome = await router.handle(name: name, arguments: arguments, session: session)
        let elapsed = ContinuousClock.now - started
        let milliseconds = Int(elapsed.components.seconds * 1000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)

        if name == ToolName.screenshot.rawValue {
            if outcome.outcome == .ok {
                preferences.directCaptureConfirmed = true
            } else if router.captureDeclined {
                // Brings back the bar with Take Test Screenshot, which asks
                // macOS to show its prompt again.
                preferences.directCaptureConfirmed = false
            }
        }
        let message = outcome.outcome == .ok ? nil : outcome.result.firstText
        log(AuditEntry(timestamp: Date(), event: .call, leaseID: outcome.leaseID?.uuidString,
                       sessionID: session.id, client: session.clientName,
                       workingDirectory: session.workingDirectory, tool: name,
                       arguments: AuditLog.loggedArguments(tool: name, arguments: arguments.raw,
                                                           keepText: preferences.keepTypedText),
                       targetBundleID: outcome.targetBundleID, windowID: outcome.windowID,
                       outcome: outcome.outcome, check: outcome.check, message: message,
                       durationMs: milliseconds),
            thumbnail: outcome.thumbnail)

        let item = ActivityItem(
            date: Date(), sessionID: session.id, sessionName: session.displayName,
            tool: name.replacingOccurrences(of: "clickrelay_", with: ""),
            target: outcome.targetBundleID.map(AppCatalog.name(for:)),
            outcome: outcome.outcome, message: message,
            thumbnail: outcome.thumbnail.flatMap { NSImage(data: $0) },
            detail: (outcome.detail ?? Self.argumentDetail(tool: name, arguments: arguments)).map(Self.oneLine),
            image: Self.screenshot(in: outcome.result))
        noteOverlayActivity(tool: name, outcome: outcome)
        addActivity(item)
        return outcome.result
    }

    /// A step a script ran: logged like the call it stands for, marked with
    /// the script and step number.
    private func recordScriptStep(_ step: ScriptStepLog) {
        let name = step.tool
        log(AuditEntry(timestamp: Date(), event: .call, leaseID: step.leaseID.uuidString,
                       sessionID: step.session.id, client: step.session.clientName,
                       workingDirectory: step.session.workingDirectory, tool: name,
                       arguments: AuditLog.loggedArguments(tool: name, arguments: step.arguments,
                                                           keepText: preferences.keepTypedText),
                       targetBundleID: step.targetBundleID, outcome: step.outcome, check: step.check,
                       message: step.message, durationMs: step.durationMs,
                       script: step.script, step: step.step, matchedBy: step.matchedBy?.rawValue))
        let item = ActivityItem(
            date: Date(), sessionID: step.session.id, sessionName: step.session.displayName,
            tool: name.replacingOccurrences(of: "clickrelay_", with: ""),
            target: step.targetBundleID.map(AppCatalog.name(for:)),
            outcome: step.outcome, message: step.message, thumbnail: nil,
            detail: Self.argumentDetail(tool: name, arguments: ToolArguments(step.arguments)).map(Self.oneLine),
            image: nil,
            script: "\(MCPLocal.abbreviatingHome(step.script)), step \(step.step)"
                + (step.matchedBy == .model ? ", matched by the on-device model" : ""))
        // Each step lights its app's window, like the single call would.
        if step.outcome == .ok, ToolName(rawValue: name) != nil {
            overlay.noteAction(windowID: nil, bundleID: step.targetBundleID, wholeDisplay: false)
        }
        addActivity(item)
    }

    private func addActivity(_ item: ActivityItem) {
        activity.insert(item, at: 0)
        if item.image != nil {
            var kept = 0
            for index in activity.indices where activity[index].image != nil {
                kept += 1
                if kept > Self.fullImageLimit { activity[index].image = nil }
            }
        }
        if activity.count > Self.activityLimit { activity.removeLast(activity.count - Self.activityLimit) }
    }

    /// Lights up the border of the window a call used.
    private func noteOverlayActivity(tool name: String, outcome: ToolOutcome) {
        guard outcome.outcome == .ok, let tool = ToolName(rawValue: name) else { return }
        switch tool {
        case .status, .listWindows, .requestAccess, .notify, .handOff, .saveScript, .validateScript: return
        default: break
        }
        overlay.noteAction(windowID: outcome.windowID, bundleID: outcome.targetBundleID,
                           wholeDisplay: tool == .screenshot && outcome.windowID == nil)
    }

    /// What a call asked for, when it didn't get as far as saying what it did
    /// (it was refused, say).
    static func argumentDetail(tool: String, arguments: ToolArguments) -> String? {
        switch ToolName(rawValue: tool) {
        case .type: return arguments.string("text")
        case .setValue: return arguments.string("value")
        case .notify, .handOff: return arguments.string("message")
        case .key:
            guard let key = arguments.string("key") else { return nil }
            return ((arguments.strings("modifiers") ?? []) + [key]).joined(separator: "+")
        default: return nil
        }
    }

    /// Typed text can run to pages; the calls list shows the start of it on
    /// one line.
    static func oneLine(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\r\n", with: "⏎").replacingOccurrences(of: "\n", with: "⏎")
            .replacingOccurrences(of: "\t", with: "⇥")
        return flat.count > 160 ? String(flat.prefix(160)) + "…" : flat
    }
}
