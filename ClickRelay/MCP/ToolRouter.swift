import AppKit
import ApplicationServices
import Foundation

/// A finished call, with what the audit log and activity feed need.
nonisolated struct ToolOutcome: Sendable {
    var result: ToolResult
    var outcome: AuditEntry.Outcome
    var check: String?
    var targetBundleID: String?
    var windowID: CGWindowID?
    var thumbnail: Data?
    var leaseID: UUID?
    /// What the call did, in a few words for its row in the calls list:
    /// the text typed, the keys pressed. Kept in memory only.
    var detail: String?

    static func ok(_ result: ToolResult, target: String? = nil, window: CGWindowID? = nil,
                   thumbnail: Data? = nil, detail: String? = nil) -> ToolOutcome {
        ToolOutcome(result: result, outcome: .ok, targetBundleID: target, windowID: window, thumbnail: thumbnail,
                    detail: detail)
    }
}

nonisolated enum ToolFailure: Error {
    /// A check said no. `isError`, with the reason for the model.
    case refused(InputRefusal)
    /// The arguments don't make sense.
    case invalid(String)
    /// Something went wrong that isn't a refusal.
    case failed(String)
}

/// Where a session's last screenshot came from, so `space: "pixels"` can be
/// turned back into points.
nonisolated struct CaptureGeometry: Sendable {
    let windowID: CGWindowID?
    let origin: CGPoint
    let scale: Double
}

/// Runs tool calls: the lease gate (with the wait for an unlock), then each
/// tool, with the allowlist checks before anything is captured or posted.
@MainActor
final class ToolRouter {
    let leases: LeaseController
    let preferences: Preferences
    let elements = ElementStore()
    let poster = InputPoster()
    let queue = InputQueue()
    let catalog: WindowCatalog
    let resolver: ProcessResolver
    let handOffs: HandOffController

    /// ClickRelay's overlay windows, ignored by the topmost check.
    var overlayWindowIDs: () -> Set<CGWindowID> = { [] }
    /// macOS's capture prompt wasn't allowed. Screenshots are refused without
    /// asking ScreenCaptureKit (a retry could prompt again) until a test
    /// screenshot from ClickRelay's window goes through.
    var captureDeclined = false
    /// A click landed here (global point), for the optional highlight.
    var onClick: ((CGPoint) -> Void)?
    /// An agent called `clickrelay_notify`.
    var onNotify: ((AgentNotice) -> Void)?
    /// Turns an app name or bundle ID from an agent into a bundle ID.
    var appLookup: @MainActor (String) -> String? = { AppCatalog.resolve($0) }
    /// A step of a script run finished, for the audit log and activity feed.
    var onScriptStep: ((ScriptStepLog) -> Void)?
    /// Picks a script step's element when exact matching can't.
    var chooser: any ElementChooser = OnDeviceChooser()
    /// Each session's input calls, for `clickrelay_save_script`.
    let recorder = ScriptRecorder()

    private var lastCapture: [String: CaptureGeometry] = [:]
    /// Sessions whose input is paused because focus moved to a denied app,
    /// with that app's name.
    var focusLost: [String: String] = [:]

    init(leases: LeaseController, preferences: Preferences,
         catalog: WindowCatalog = SystemWindowCatalog(),
         resolver: ProcessResolver = SystemProcessResolver(),
         handOffs: HandOffController = HandOffController()) {
        self.leases = leases
        self.preferences = preferences
        self.catalog = catalog
        self.resolver = resolver
        self.handOffs = handOffs
    }

    /// Drops a session's per-lease state. Called when its lease ends.
    func leaseEnded(sessionID: String) {
        elements.invalidate(session: sessionID)
        lastCapture[sessionID] = nil
        focusLost[sessionID] = nil
        handOffs.finish(sessionID: sessionID, .locked)
    }

    // MARK: - Entry

    func handle(name: String, arguments: ToolArguments, session: AgentSession) async -> ToolOutcome {
        guard let tool = ToolName(rawValue: name) else {
            return ToolOutcome(result: .error("There's no tool called \(name)."), outcome: .error)
        }
        switch tool {
        case .status: return .ok(.json(status(session: session)))
        case .requestAccess: return await requestAccess(arguments, session: session)
        case .notify: return notify(arguments, session: session)
        case .validateScript:
            // Checks text only; nothing is captured, read on screen or posted. The
            // bridge normally answers this itself.
            let result = ScriptCheck.result(arguments.value("script"), params: arguments.value("params"),
                                            label: arguments.string("path"), isInstalled: { id in
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
            })
            return ToolOutcome(result: result, outcome: result.isError ? .error : .ok)
        default: break
        }

        var lease = leases.activeLease(for: session.id)
        if lease == nil {
            lease = await leases.waitForUnlock(session: session, tool: name,
                                               targetBundleID: requestTarget(tool, arguments),
                                               timeout: preferences.unlockWait)
        }
        guard let lease else {
            return ToolOutcome(result: .error(lockedMessage(waited: true)), outcome: .refused, check: "lease")
        }
        leases.recordCall(sessionID: session.id)

        let context = CallContext(session: session, lease: lease,
                                  guard: InputGuard(policy: lease.policy, resolver: resolver,
                                                    ignoredWindowIDs: overlayWindowIDs()))
        do throws(ToolFailure) {
            var outcome: ToolOutcome
            if tool == .runScript {
                if let refusal = pausedRefusal(session.id) { throw .refused(refusal) }
                outcome = try await runScript(arguments, context)
            } else if tool.isInput {
                if let refusal = pausedRefusal(session.id) { throw .refused(refusal) }
                if tool != .focusWindow && tool != .launchApp, let app = focusLost[session.id] {
                    throw .refused(InputRefusal(check: .focus, message: focusLostMessage(app)))
                }
                let result = await queue.run { [self] () async -> Result<ToolOutcome, ToolFailure> in
                    do throws(ToolFailure) {
                        return .success(try await self.runInput(tool, arguments, context))
                    } catch {
                        // A sequence that failed partway lets go of anything held.
                        self.poster.releaseAll()
                        return .failure(error)
                    }
                }
                outcome = try result.get()
                recordForScript(tool, arguments, context)
                if let note = afterInput(context) {
                    outcome.result.content.append(.text(note))
                }
            } else {
                outcome = try await runRead(tool, arguments, context)
            }
            outcome.leaseID = lease.id
            return outcome
        } catch {
            var outcome: ToolOutcome
            switch error {
            case .refused(let refusal):
                outcome = ToolOutcome(result: .error(refusal.message), outcome: .refused, check: refusal.check.rawValue)
            case .invalid(let message):
                outcome = ToolOutcome(result: .error(message), outcome: .error, check: "arguments")
            case .failed(let message):
                outcome = ToolOutcome(result: .error(message), outcome: .error)
            }
            outcome.leaseID = lease.id
            return outcome
        }
    }

    struct CallContext {
        let session: AgentSession
        let lease: Lease
        let `guard`: InputGuard
    }

    private func runRead(_ tool: ToolName, _ args: ToolArguments,
                         _ context: CallContext) async throws(ToolFailure) -> ToolOutcome {
        switch tool {
        case .listWindows: return try listWindows(args, context)
        case .screenshot: return try await screenshot(args, context)
        case .getUITree: return try await uiTree(args, context)
        case .findElements: return try await findElements(args, context)
        case .handOff: return try await handOff(args, context)
        case .saveScript: return try saveScript(args, context)
        default: throw .failed("\(tool.rawValue) isn't a read tool")
        }
    }

    private func runInput(_ tool: ToolName, _ args: ToolArguments,
                          _ context: CallContext) async throws(ToolFailure) -> ToolOutcome {
        switch tool {
        case .press: return try await press(args, context)
        case .setValue: return try await setValue(args, context)
        case .click: return try await click(args, context)
        case .drag: return try await drag(args, context)
        case .scroll: return try await scroll(args, context)
        case .type: return try await type(args, context)
        case .key: return try await key(args, context)
        case .focusWindow: return try await focusWindow(args, context)
        case .launchApp: return try await launchApp(args, context)
        default: throw .failed("\(tool.rawValue) isn't an input tool")
        }
    }

    // MARK: - Messages

    /// The app a locked call is aimed at, for the "asking for access" card.
    /// Window metadata only; nothing is captured or posted.
    private func requestTarget(_ tool: ToolName, _ arguments: ToolArguments) -> String? {
        if tool == .launchApp { return arguments.string("bundle_id") }
        if tool == .runScript { return (arguments.value("script") as? [String: Any])?["app"] as? String }
        guard let raw = arguments.int("window_id"), raw > 0, raw <= Int(UInt32.max),
              let window = catalog.snapshot().window(CGWindowID(raw)) else { return nil }
        return resolver.bundleID(for: window.pid)
    }

    func lockedMessage(waited: Bool) -> String {
        let how = preferences.unlockMethod == .authorizeButton ? "the Authorize button" : "Touch ID"
        let seconds = preferences.unlockWaitSeconds
        let lead = waited && seconds > 0
            ? "ClickRelay is still locked after \(seconds) seconds." : "ClickRelay is locked."
        return lead + " Call clickrelay_request_access with the apps you need, or ask the user to unlock it "
            + "in ClickRelay (\(how))."
    }

    private func focusLostMessage(_ app: String) -> String {
        "Focus moved to \(app), which isn't allowed, so input is paused. Call clickrelay_focus_window "
            + "on an allowed window to continue."
    }

    /// Re-checks the lease between events in a sequence, so a lease that ends
    /// mid-drag stops it.
    func ensureLease(_ context: CallContext) throws(ToolFailure) {
        guard let current = leases.activeLease(for: context.session.id), current.id == context.lease.id else {
            throw .refused(InputRefusal(check: .lease, message: lockedMessage(waited: false)))
        }
        // A hand-off that opens mid-sequence stops it at the next event.
        if let refusal = pausedRefusal(context.session.id) { throw .refused(refusal) }
    }

    /// While the user has the Mac for a hand-off, no agent posts input: a
    /// click anywhere could move focus away from the field they're typing in.
    private func pausedRefusal(_ sessionID: String) -> InputRefusal? {
        guard let open = handOffs.handOffs[sessionID] ?? handOffs.handOffs.values.first else { return nil }
        if open.sessionID == sessionID {
            return InputRefusal(check: .handOff, message:
                "You handed window \(open.windowID) to the user, so input is paused until they're done. "
                + "Call clickrelay_hand_off again with window_id \(open.windowID) to wait for their answer.")
        }
        return InputRefusal(check: .handOff, message:
            "The user is doing something in \(open.appName) for another agent, so input is paused until "
            + "they're done. Try again in a minute. You can still take screenshots of other apps' windows.")
    }

    /// Refuses reads of an app the user is working in for a hand-off.
    private func checkNotHandedOff(_ window: WindowInfo, _ context: CallContext,
                                   allowingOwn: Bool = false) throws(ToolFailure) {
        guard let open = handOffs.blocking(pid: window.pid) else { return }
        if allowingOwn, open.sessionID == context.session.id { return }
        let mine = open.sessionID == context.session.id
        throw .refused(InputRefusal(check: .handOff, message:
            "The user is working in \(open.appName)\(mine ? " for you" : " for another agent"), so ClickRelay "
            + "won't show or read it until they're done."
            + (mine ? " Call clickrelay_hand_off again with window_id \(open.windowID) to wait for them." : " Try again in a minute.")))
    }

    /// After each input call, checks where focus went. If it moved to a
    /// denied app (a link opened a browser, say), further input waits for
    /// `focus_window`.
    func afterInput(_ context: CallContext) -> String? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        if front.processIdentifier == getpid() || !context.lease.policy.allows(pid: front.processIdentifier, resolver: resolver) {
            let name = front.localizedName ?? front.bundleIdentifier ?? "another app"
            focusLost[context.session.id] = name
            return focusLostMessage(name)
        }
        return nil
    }

    // MARK: - Status

    private func status(session: AgentSession) -> [String: Any] {
        var object: [String: Any] = [:]
        let permissions = Permissions.current
        if !permissions.allGranted {
            object["permissions_missing"] = permissions.missing
        }
        guard let lease = leases.activeLease(for: session.id) else {
            object["locked"] = true
            object["message"] = lockedMessage(waited: false)
            return object
        }
        let seconds = Int(lease.remaining(at: leases.clock.now).components.seconds)
        object["locked"] = false
        object["seconds_left"] = seconds
        object["allowed_apps"] = lease.allowedBundleIDs.sorted().map { id -> [String: Any] in
            ["bundle_id": id, "name": AppCatalog.name(for: id), "running": AppCatalog.isRunning(id)]
        }
        let front = NSWorkspace.shared.frontmostApplication
        let inputAllowed = front.map { lease.policy.allows(pid: $0.processIdentifier, resolver: resolver) } ?? false
        object["frontmost_app"] = front?.localizedName ?? NSNull()
        object["input_allowed"] = inputAllowed && focusLost[session.id] == nil
        if let app = focusLost[session.id] { object["note"] = focusLostMessage(app) }
        else if !inputAllowed { object["note"] = "The frontmost app isn't allowed. Call clickrelay_focus_window before clicking or typing." }
        else { object["note"] = "Keep going until the time runs out. If it does, call clickrelay_request_access." }
        if let open = handOffs.handOffs[session.id] {
            object["input_allowed"] = false
            object["hand_off"] = ["window_id": Int(open.windowID), "app": open.appName, "answered": false]
            object["note"] = "The user hasn't finished in window \(open.windowID) yet. Call clickrelay_hand_off again with that window_id to wait for them."
        } else if let paused = pausedRefusal(session.id) {
            object["input_allowed"] = false
            object["note"] = paused.message
        } else if let unread = handOffs.takeUnread(sessionID: session.id) {
            let answer = handOffOutcome(unread.answer, windowID: unread.handOff.windowID,
                                        since: unread.handOff.createdAt, target: nil, detail: nil, waited: 0,
                                        answeredAt: unread.at)
            object["hand_off"] = ["window_id": Int(unread.handOff.windowID), "app": unread.handOff.appName,
                                  "answered": true, "answer": answer.result.firstText ?? ""]
        }
        return object
    }

    // MARK: - Asking the user

    private func requestAccess(_ args: ToolArguments, session: AgentSession) async -> ToolOutcome {
        let names = (args.strings("apps") ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(12)
        var apps: [String] = []
        var unknown: [String] = []
        var forbidden: [String] = []
        for name in names {
            guard let id = appLookup(name) else { unknown.append(name); continue }
            if let reason = Denylist.reason(for: id, agentHosts: session.hostBundleIDs) {
                forbidden.append("\(AppCatalog.name(for: id)) (\(reason.lowercasedFirst))")
            } else if !apps.contains(id) {
                apps.append(id)
            }
        }
        var notes: [String] = []
        if !unknown.isEmpty {
            notes.append("ClickRelay couldn't find \(AppModel.list(unknown)) on this Mac. Use the bundle ID or the name shown in Finder.")
        }
        if !forbidden.isEmpty { notes.append("These can never be allowed for you: \(AppModel.list(forbidden)).") }
        let detail = apps.isEmpty ? nil : AppModel.list(apps.map(AppCatalog.name(for:)))
        if !names.isEmpty && apps.isEmpty {
            return ToolOutcome(result: .error((notes + ["Nothing was asked."]).joined(separator: " ")),
                               outcome: .refused, check: "request", detail: detail)
        }
        if let lease = leases.activeLease(for: session.id), !apps.isEmpty,
           apps.allSatisfy({ lease.policy.allows(bundleID: $0) }) {
            var object = status(session: session)
            object["note"] = "You already have \(detail ?? "these apps"). Carry on."
            return .ok(.json(object), detail: detail)
        }

        let reason = args.string("reason")?.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(Self.maxReasonLength).description
        let wait = min(300, max(0, args.int("wait_seconds") ?? 120))
        let answer = await leases.requestAccess(session: session, apps: apps,
                                                reason: reason?.isEmpty == false ? reason : nil,
                                                timeout: .seconds(wait))
        switch answer {
        case .granted(let lease):
            var object = status(session: session)
            let missing = apps.filter { !lease.policy.allows(bundleID: $0) }
            notes.insert(missing.isEmpty
                ? "The user unlocked ClickRelay for you. Carry on."
                : "The user unlocked ClickRelay but didn't allow \(AppModel.list(missing.map(AppCatalog.name(for:)))). Work with the apps you have, or tell them in chat why you need it.",
                at: 0)
            object["note"] = notes.joined(separator: " ")
            var outcome = ToolOutcome.ok(.json(object), detail: detail)
            outcome.leaseID = lease.id
            return outcome
        case .dismissed:
            return ToolOutcome(result: .error("The user said not now. Don't ask again unless they bring it up; tell them in chat what you needed and why."),
                               outcome: .refused, check: "request", detail: detail)
        case .timedOut:
            return ToolOutcome(result: .error((["The user hasn't answered yet. The request stays on their screen. Call clickrelay_request_access again to keep waiting, or tell them in chat what you need."] + notes).joined(separator: " ")),
                               outcome: .refused, check: "request", detail: detail)
        case .disconnected:
            return ToolOutcome(result: .error("The request ended because this session disconnected."),
                               outcome: .error, detail: detail)
        }
    }

    static let maxReasonLength = 200
    static let maxNoticeLength = 300

    private func notify(_ args: ToolArguments, session: AgentSession) -> ToolOutcome {
        guard let raw = args.string("message")?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return ToolOutcome(result: .error("message is required: a sentence or two for the user."),
                               outcome: .error, check: "arguments")
        }
        let message = String(raw.prefix(Self.maxNoticeLength))
        let kind: AgentNotice.Kind = switch args.string("status")?.lowercased() {
        case "needs_you", "needs-you", "needsyou", "blocked", "stopped", "question": .needsYou
        default: .done
        }
        onNotify?(AgentNotice(sessionID: session.id, kind: kind, message: message, date: Date()))
        var text = "The user can see your message in ClickRelay."
        if args.bool("release_access") == true, leases.leases[session.id] != nil {
            leases.lock(sessionID: session.id, reason: .released)
            text += " Your access is now locked."
        }
        return .ok(.text(text), detail: message)
    }

    // MARK: - Handing off to the user

    private func handOff(_ args: ToolArguments, _ context: CallContext) async throws(ToolFailure) -> ToolOutcome {
        guard let raw = args.string("message")?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            throw .invalid("message is required: a sentence or two telling the user what to do.")
        }
        let message = String(raw.prefix(Self.maxNoticeLength))
        let window = try allowedWindow(try windowArgument(args), context, allowingOwnHandOff: true)
        if let open = handOffs.blocking(pid: window.pid), open.sessionID != context.session.id {
            throw .refused(InputRefusal(check: .handOff, message:
                "The user is already doing something in \(open.appName) for another agent. Try again in a minute."))
        }
        if let other = handOffs.handOffs.values.first(where: { $0.sessionID != context.session.id }) {
            throw .refused(InputRefusal(check: .handOff, message:
                "The user is busy in \(other.appName) for another agent. Try again once they're done."))
        }
        var element: AXElement?
        var elementFrame: CGRect?
        if let ref = args.string("ref"), !ref.isEmpty {
            guard let entry = elements.entry(ref, session: context.session.id) else {
                throw .invalid("\(ref) isn't a current ref. Get one with clickrelay_find_elements on window \(window.id), or leave ref out to point at the whole window.")
            }
            guard entry.windowID == window.id else {
                throw .invalid("\(ref) is in window \(entry.windowID), not \(window.id). Use a ref from this window, or leave ref out.")
            }
            element = entry.element
            let ax = entry.element
            let global = await Task.detached { AXQuery.frame(of: ax.element) }.value
            elementFrame = global.map { $0.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY) }
        }
        try ensureLeaseOnly(context)
        let wait = min(300, max(0, args.int("wait_seconds") ?? 300))
        // Answered while nobody was waiting: that's the answer to this call.
        if handOffs.handOffs[context.session.id] == nil,
           let unread = handOffs.takeUnread(sessionID: context.session.id), unread.handOff.windowID == window.id {
            return handOffOutcome(unread.answer, windowID: window.id, since: unread.handOff.createdAt,
                                  target: unread.handOff.bundleID, detail: message, waited: wait,
                                  answeredAt: unread.at)
        }
        let started = handOffs.handOffs[context.session.id].flatMap { $0.windowID == window.id ? $0.createdAt : nil }
            ?? Date()
        let handOff = HandOff(id: UUID(), sessionID: context.session.id, windowID: window.id, pid: window.pid,
                              bundleID: resolver.bundleID(for: window.pid),
                              appName: resolver.appName(for: window.pid) ?? window.ownerName,
                              message: message, element: element, elementFrame: elementFrame,
                              createdAt: Date())
        // Whatever an agent was holding down goes before the user takes over.
        poster.releaseAll()
        let answer = await handOffs.start(handOff, timeout: .seconds(wait))
        return handOffOutcome(answer, windowID: window.id, since: started, target: handOff.bundleID,
                              detail: message, waited: wait)
    }

    private func handOffOutcome(_ answer: HandOffAnswer, windowID: CGWindowID, since: Date, target: String?,
                                detail: String?, waited: Int, answeredAt: Date = Date()) -> ToolOutcome {
        func with(_ note: String?) -> String {
            guard let note, !note.isEmpty else { return "" }
            return " Their note: \"\(note)\"."
        }
        func refused(_ text: String) -> ToolOutcome {
            var outcome = ToolOutcome(result: .error(text), outcome: .refused, check: InputRefusal.Check.handOff.rawValue)
            outcome.targetBundleID = target
            outcome.windowID = windowID
            outcome.detail = detail
            return outcome
        }
        switch answer {
        case .done(let note):
            let seconds = max(1, Int(answeredAt.timeIntervalSince(since).rounded()))
            return .ok(.text("The user finished in window \(windowID) after \(seconds) seconds.\(with(note)) "
                             + "Take a screenshot to see where things are now, then carry on."),
                       target: target, window: windowID, detail: detail)
        case .cantDo(let note):
            return refused("The user couldn't do this.\(with(note)) Don't ask again for the same thing. "
                           + "Try another way, or tell them with clickrelay_notify what you needed.")
        case .timedOut:
            let wait = waited >= 60 && waited % 60 == 0
                ? (waited == 60 ? "a minute" : "\(waited / 60) minutes") : "\(waited) seconds"
            return refused("The user hasn't answered after \(wait). It's still on their screen, and input stays "
                           + "paused until they do. Call clickrelay_hand_off again with window_id \(windowID) to keep waiting.")
        case .windowClosed:
            return refused("Window \(windowID) closed before the user said they were done. "
                           + "Call clickrelay_list_windows to see what's on screen now.")
        case .locked:
            var outcome = refused(lockedMessage(waited: false))
            outcome.check = InputRefusal.Check.lease.rawValue
            return outcome
        case .replaced:
            return refused("You handed off another window, so this one was closed.")
        }
    }

    /// The lease check without the hand-off pause, for starting a hand-off.
    private func ensureLeaseOnly(_ context: CallContext) throws(ToolFailure) {
        guard let current = leases.activeLease(for: context.session.id), current.id == context.lease.id else {
            throw .refused(InputRefusal(check: .lease, message: lockedMessage(waited: false)))
        }
    }

    // MARK: - Windows

    func windowArgument(_ args: ToolArguments) throws(ToolFailure) -> CGWindowID {
        guard let raw = args.int("window_id"), raw > 0, raw <= Int(UInt32.max) else {
            throw .invalid("window_id is required: a number from clickrelay_list_windows or clickrelay_screenshot.")
        }
        return CGWindowID(raw)
    }

    /// The window, from a fresh snapshot, if it's on screen and allowed.
    func allowedWindow(_ id: CGWindowID, _ context: CallContext,
                       allowingOwnHandOff: Bool = false) throws(ToolFailure) -> WindowInfo {
        let snapshot = catalog.snapshot()
        guard let window = snapshot.window(id) else {
            throw .refused(InputRefusal(check: .window, message:
                "Window \(id) isn't on screen (closed, minimised or on another Space). Call clickrelay_list_windows for current windows."))
        }
        guard context.lease.policy.allows(pid: window.pid, resolver: resolver) else {
            let app = resolver.appName(for: window.pid) ?? window.ownerName
            throw .refused(InputRefusal(check: .window, message:
                "Window \(id) belongs to \(app), which isn't allowed. Use a window from an allowed app, or ask the user to allow \(app)."))
        }
        try checkNotHandedOff(window, context, allowingOwn: allowingOwnHandOff)
        return window
    }

    private func listWindows(_ args: ToolArguments, _ context: CallContext) throws(ToolFailure) -> ToolOutcome {
        let only = args.string("bundle_id")
        if let only, !context.lease.policy.allows(bundleID: only) {
            throw .refused(InputRefusal(check: .window, message:
                "\(only) isn't one of the allowed apps. Call clickrelay_status to see which are."))
        }
        let snapshot = catalog.snapshot()
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var frontmostWindowID: CGWindowID?
        var list: [[String: Any]] = []
        for window in snapshot.windows where window.isAppWindow {
            guard context.lease.policy.allows(pid: window.pid, resolver: resolver) else { continue }
            let bundleID = resolver.bundleID(for: window.pid) ?? ""
            if let only, bundleID != only { continue }
            if frontmostWindowID == nil, window.pid == frontPID, window.layer == 0 { frontmostWindowID = window.id }
            var entry: [String: Any] = [
                "window_id": Int(window.id),
                "app": resolver.appName(for: window.pid) ?? window.ownerName,
                "bundle_id": bundleID,
                "title": window.title,
                "frame": ["x": Int(window.frame.minX), "y": Int(window.frame.minY),
                          "width": Int(window.frame.width), "height": Int(window.frame.height)],
                "frontmost": window.id == frontmostWindowID
            ]
            if handOffs.blocking(pid: window.pid) != nil { entry["user_working"] = true }
            list.append(entry)
        }
        var object: [String: Any] = ["windows": list]
        if list.isEmpty {
            object["note"] = "No allowed app has a window on screen. Open one with clickrelay_launch_app."
        } else if let open = handOffs.handOffs.values.first {
            object["note"] = "The user is working in \(open.appName) (user_working), so its windows can't be captured or read and input is paused until they're done."
        }
        return .ok(.json(object), target: only)
    }

    // MARK: - Screenshot

    private func screenshot(_ args: ToolArguments, _ context: CallContext) async throws(ToolFailure) -> ToolOutcome {
        let format = CaptureFormat(rawValue: args.string("format")?.lowercased().replacingOccurrences(of: "jpg", with: "jpeg") ?? "png") ?? .png
        let maxEdge = min(4096, max(256, args.int("max_edge") ?? preferences.screenshotMaxEdge))
        if captureDeclined { throw .failed(CaptureError.declined.message) }
        let capture: CaptureResult
        var target: String?
        do {
            if args.value("window_id") != nil {
                let id = try windowArgument(args)
                let window = try allowedWindow(id, context)
                target = resolver.bundleID(for: window.pid)
                capture = try await Screenshotter.captureWindow(id: id, policy: context.lease.policy,
                                                                maxEdge: maxEdge, format: format)
            } else {
                let titles = Dictionary(catalog.snapshot().windows.map { ($0.id, $0.title) },
                                        uniquingKeysWith: { first, _ in first })
                capture = try await Screenshotter.captureDisplay(policy: context.lease.policy, maxEdge: maxEdge,
                                                                 format: format, windowTitles: titles,
                                                                 excludingPIDs: handOffs.blockedPIDs)
            }
        } catch let error as CaptureError {
            if error == .declined { captureDeclined = true }
            throw .failed(error.message)
        } catch let error as ToolFailure {
            throw error
        } catch {
            throw .failed(error.localizedDescription)
        }
        lastCapture[context.session.id] = CaptureGeometry(windowID: capture.windowID, origin: capture.origin,
                                                          scale: capture.scale)
        var info: [String: Any] = [
            "scale": (capture.scale * 1000).rounded() / 1000,
            "origin": ["x": Int(capture.origin.x), "y": Int(capture.origin.y)],
            "width": capture.pixelWidth,
            "height": capture.pixelHeight
        ]
        if let id = capture.windowID {
            info["window_id"] = Int(id)
            info["how_to_click"] = "Window points = pixel / scale. Pass them to clickrelay_click with this window_id, or pass the pixels with space \"pixels\"."
        } else {
            info["windows"] = capture.windows.map { window -> [String: Any] in
                ["window_id": Int(window.id), "app": window.app, "title": window.title,
                 "rect_pixels": [Int(window.pixelRect.minX), Int(window.pixelRect.minY),
                                 Int(window.pixelRect.width), Int(window.pixelRect.height)]]
            }
            info["how_to_click"] = "Screen point = origin + pixel / scale. To click, use the window_id under that point, with space \"pixels\" and these image pixels, or window points."
        }
        let infoText = String(decoding: (try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
        let result = ToolResult(content: [.image(data: capture.data, mimeType: format.mimeType), .text(infoText)],
                                isError: false)
        return .ok(result, target: target, window: capture.windowID, thumbnail: capture.thumbnail)
    }

    // MARK: - Accessibility tree

    func axWindow(_ window: WindowInfo) async throws(ToolFailure) -> AXElement {
        let pid = window.pid, id = window.id, frame = window.frame, title = window.title
        let element = await Task.detached {
            AXQuery.windowElement(pid: pid, windowID: id, frame: frame, title: title)
        }.value
        guard let element else {
            throw .failed("ClickRelay couldn't read window \(window.id) with Accessibility. Check ClickRelay has Accessibility permission, or use clickrelay_screenshot and coordinates.")
        }
        return element
    }

    private func uiTree(_ args: ToolArguments, _ context: CallContext) async throws(ToolFailure) -> ToolOutcome {
        let window = try allowedWindow(try windowArgument(args), context)
        let root = try await axWindow(window)
        let depth = min(40, max(1, args.int("max_depth") ?? 6))
        let interactive = (args.string("filter") ?? "interactive").lowercased() != "all"
        let origin = window.frame.origin
        let nodes = await Task.detached {
            AXQuery.walk(root: root, windowOrigin: origin, maxDepth: depth, interactiveOnly: interactive)
        }.value
        let refs = elements.register(nodes, session: context.session.id, windowID: window.id, replacingWindow: true)
        var object: [String: Any] = [
            "window_id": Int(window.id),
            "elements": zip(nodes, refs).map { $0.json(ref: $1) }
        ]
        if nodes.count >= AXQuery.nodeLimit { object["truncated"] = true }
        if nodes.isEmpty {
            object["note"] = interactive
                ? "No interactive elements found. Try filter \"all\" or a larger max_depth."
                : "The window has no Accessibility elements. Use clickrelay_screenshot and coordinates."
        }
        return .ok(.json(object), target: resolver.bundleID(for: window.pid), window: window.id)
    }

    private func findElements(_ args: ToolArguments, _ context: CallContext) async throws(ToolFailure) -> ToolOutcome {
        guard let query = args.string("query"), !query.isEmpty else {
            throw .invalid("query is required: text to look for in titles, labels, values or identifiers.")
        }
        let role = args.string("role")
        if args.string("in")?.lowercased() == "menus" {
            return try await findMenuItems(query: query, role: role, bundleID: args.string("bundle_id"), context)
        }
        let window = try allowedWindow(try windowArgument(args), context)
        let root = try await axWindow(window)
        let origin = window.frame.origin
        let nodes = await Task.detached {
            AXQuery.walk(root: root, windowOrigin: origin, maxDepth: 40, interactiveOnly: false)
        }.value
        let matches = nodes.filter { node in
            node.matches(query) && (role == nil || node.role.caseInsensitiveCompare(role!) == .orderedSame)
        }.prefix(50)
        let refs = elements.register(Array(matches), session: context.session.id, windowID: window.id,
                                     replacingWindow: false)
        var object: [String: Any] = [
            "window_id": Int(window.id),
            "elements": zip(matches, refs).map { $0.json(ref: $1) }
        ]
        if matches.isEmpty { object["note"] = "Nothing matched \"\(query)\". Try a shorter query or clickrelay_get_ui_tree." }
        return .ok(.json(object), target: resolver.bundleID(for: window.pid), window: window.id)
    }

    /// `find_elements` with `in: "menus"`: the app's menu bar, which isn't
    /// part of any window. The menus stay closed; their items are read and
    /// pressed without opening them.
    private func findMenuItems(query: String, role: String?, bundleID: String?,
                               _ context: CallContext) async throws(ToolFailure) -> ToolOutcome {
        guard let bundleID, !bundleID.isEmpty else {
            throw .invalid("bundle_id is required with in \"menus\": the app whose menu bar to search, e.g. com.apple.dt.Xcode.")
        }
        let name = AppCatalog.name(for: bundleID)
        guard context.lease.policy.allows(bundleID: bundleID) else {
            throw .refused(InputRefusal(check: .window, message:
                "\(name) isn't allowed. Ask the user to allow \(name) if you need it."))
        }
        let pids = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .map(\.processIdentifier)
            .filter { context.lease.policy.allows(pid: $0, resolver: resolver) }
        guard !pids.isEmpty else {
            throw .failed("\(name) isn't running. Open it with clickrelay_launch_app first.")
        }
        if let open = pids.lazy.compactMap({ self.handOffs.blocking(pid: $0) }).first {
            throw .refused(InputRefusal(check: .handOff, message:
                "The user is working in \(open.appName), so ClickRelay won't read it until they're done. Try again in a minute."))
        }
        let found = await Task.detached { () -> [(AXNode, Bool)] in
            let nodes = pids.flatMap { pid -> [AXNode] in
                guard let bar = AXQuery.menuBar(pid: pid) else { return [] }
                return AXQuery.walk(root: bar, windowOrigin: .zero, maxDepth: 10, interactiveOnly: false, limit: 6000)
            }
            let matches = nodes.filter { node in
                node.role != "AXMenu" && node.matches(query)
                    && (role == nil || node.role.caseInsensitiveCompare(role!) == .orderedSame)
            }.prefix(50)
            return matches.map { ($0, AXQuery.opensMenu($0)) }
        }.value
        let refs = elements.register(found.map(\.0), session: context.session.id,
                                     windowID: ElementStore.menuBar, replacingWindow: false)
        let items = zip(found, refs).map { pair, ref -> [String: Any] in
            var json = pair.0.json(ref: ref)
            json["frame"] = nil   // Closed menus have no useful frame.
            if pair.1 { json["opens_menu"] = true }
            return json
        }
        var object: [String: Any] = ["menus_of": bundleID, "elements": items]
        object["note"] = items.isEmpty
            ? "Nothing in \(name)'s menus matched \"\(query)\". Try a shorter query."
            : "Press a menu item's ref with clickrelay_press; its menu doesn't need to be open. Items with opens_menu only open a submenu, so press the item you want inside it instead."
        return .ok(.json(object), target: bundleID)
    }

    private func element(_ args: ToolArguments, _ context: CallContext) throws(ToolFailure) -> (AXElement, pid_t, CGWindowID) {
        guard let ref = args.string("ref"), !ref.isEmpty else {
            throw .invalid("ref is required: an element ref like e42 from clickrelay_get_ui_tree or clickrelay_find_elements.")
        }
        guard let entry = elements.entry(ref, session: context.session.id) else {
            throw .invalid("\(ref) isn't a current ref. Refs last until the next clickrelay_get_ui_tree on their window; get new ones and try again.")
        }
        guard let pid = entry.element.pid else {
            throw .failed("\(ref) no longer exists (its window may have closed). Get new refs and try again.")
        }
        if let refusal = context.guard.checkElement(pid: pid) { throw .refused(refusal) }
        return (entry.element, pid, entry.windowID)
    }

    private func press(_ args: ToolArguments, _ context: CallContext) async throws(ToolFailure) -> ToolOutcome {
        let (element, pid, windowID) = try element(args, context)
        let requested = args.string("action") ?? "AXPress"
        if windowID == ElementStore.menuBar {
            return try await pressMenuItem(element, pid: pid, requested: requested, ref: args.string("ref") ?? "", context)
        }
        let text = try await performPress(element, pid: pid, requested: requested, context)
        let isFocus = ["focus", "axfocus", "axfocused"].contains(requested.lowercased())
        return .ok(.text(text), target: resolver.bundleID(for: pid), window: windowID,
                   detail: "\(isFocus ? "focus" : Self.axAction(requested)) \(args.string("ref") ?? "")")
    }

    /// A menu item from `find_elements` in "menus". Never opens a menu: an
    /// app with a menu opened through Accessibility stays in menu tracking,
    /// ignoring posted keys and holding the mouse until someone closes it.
    private func pressMenuItem(_ element: AXElement, pid: pid_t, requested: String, ref: String,
                               _ context: CallContext) async throws(ToolFailure) -> ToolOutcome {
        let bundleID = resolver.bundleID(for: pid)
        let action = Self.axAction(requested)
        if action == "AXPress" {
            let opens = await Task.detached { () -> Bool in
                AXQuery.opensMenu(AXQuery.describe(element.element, windowOrigin: .zero, depth: 0))
            }.value
            if opens {
                throw .invalid("\(ref) only opens a menu, and ClickRelay doesn't open menus (an open menu gets stuck). "
                    + "Press the item you want inside it directly: find it with clickrelay_find_elements, in \"menus\".")
            }
        }
        _ = await Task.detached { AXQuery.closeOpenMenus(pid: pid) }.value
        let text = try await performPress(element, pid: pid, requested: requested, context)
        _ = await Task.detached { AXQuery.closeOpenMenus(pid: pid) }.value
        return .ok(.text(text), target: bundleID, detail: "\(action) \(ref)")
    }

    /// `press` → `AXPress`.
    static func axAction(_ requested: String) -> String {
        requested.hasPrefix("AX") ? requested : "AX" + requested.prefix(1).uppercased() + requested.dropFirst()
    }

    /// An AX action (or focus) on an element already checked as allowed.
    /// Shared by `clickrelay_press` and script steps.
    func performPress(_ element: AXElement, pid: pid_t, requested: String,
                      _ context: CallContext) async throws(ToolFailure) -> String {
        if let refusal = context.guard.checkElement(pid: pid) { throw .refused(refusal) }
        let isFocus = ["focus", "axfocus", "axfocused"].contains(requested.lowercased())
        let action = Self.axAction(requested)
        try ensureLease(context)
        let error: AXError = await Task.detached {
            if isFocus {
                return AXUIElementSetAttributeValue(element.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
            let available = AXQuery.actions(of: element.element)
            guard available.contains(action) else { return .actionUnsupported }
            return AXUIElementPerformAction(element.element, action as CFString)
        }.value
        switch error {
        case .success:
            return isFocus ? "Focused." : "Done: \(action)."
        case .actionUnsupported:
            let available = await Task.detached { AXQuery.actions(of: element.element) }.value
            throw .invalid("That element doesn't support \(action). It supports: \(available.isEmpty ? "no actions" : available.joined(separator: ", ")).")
        default:
            throw .failed("The app didn't accept \(isFocus ? "focus" : action) (AX error \(error.rawValue)). Take a screenshot to see what happened.")
        }
    }

    private func setValue(_ args: ToolArguments, _ context: CallContext) async throws(ToolFailure) -> ToolOutcome {
        let (element, pid, windowID) = try element(args, context)
        guard let value = args.string("value") else { throw .invalid("value is required.") }
        let text = try await performSetValue(element, pid: pid, value: value, context)
        return .ok(.text(text), target: resolver.bundleID(for: pid), window: windowID, detail: value)
    }

    /// Sets an element's AX value. Shared by `clickrelay_set_value` and scripts.
    func performSetValue(_ element: AXElement, pid: pid_t, value: String,
                         _ context: CallContext) async throws(ToolFailure) -> String {
        if let refusal = context.guard.checkElement(pid: pid) { throw .refused(refusal) }
        try ensureLease(context)
        let error: AXError = await Task.detached {
            var settable: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(element.element, kAXValueAttribute as CFString, &settable) == .success,
                  settable.boolValue else { return .attributeUnsupported }
            let current = AXQuery.copy(element.element, kAXValueAttribute)
            let newValue: CFTypeRef
            if current is NSNumber, let number = Double(value) {
                newValue = NSNumber(value: number)
            } else {
                newValue = value as CFString
            }
            return AXUIElementSetAttributeValue(element.element, kAXValueAttribute as CFString, newValue)
        }.value
        switch error {
        case .success:
            return "Value set."
        case .attributeUnsupported:
            throw .invalid("That element's value can't be set directly. Focus it (clickrelay_press with action \"focus\") and use clickrelay_type instead.")
        default:
            throw .failed("The app didn't accept the value (AX error \(error.rawValue)).")
        }
    }

    // MARK: - Coordinate input

    private func globalPoint(x: Double, y: Double, space: String?, window: WindowInfo,
                             _ context: CallContext) throws(ToolFailure) -> CGPoint {
        switch space?.lowercased() {
        case nil, "points", "point":
            return CGPoint(x: window.frame.minX + x, y: window.frame.minY + y)
        case "pixels", "pixel":
            guard let capture = lastCapture[context.session.id] else {
                throw .invalid("space \"pixels\" needs a screenshot first. Take one with clickrelay_screenshot, or use window points.")
            }
            if let captured = capture.windowID {
                guard captured == window.id else {
                    throw .invalid("Your last screenshot was of window \(captured), not \(window.id). Take a screenshot of this window, or use points.")
                }
                // Relative to the window's current position, in case it moved.
                return CGPoint(x: window.frame.minX + x / capture.scale, y: window.frame.minY + y / capture.scale)
            }
            return CGPoint(x: capture.origin.x + x / capture.scale, y: capture.origin.y + y / capture.scale)
        default:
            throw .invalid("space must be \"points\" or \"pixels\".")
        }
    }

    /// Runs the four checks for one event, against a fresh snapshot.
    private func check(_ point: CGPoint, windowID: CGWindowID, _ context: CallContext) throws(ToolFailure) -> WindowInfo {
        try ensureLease(context)
        let result = context.guard.checkPoint(windowID: windowID, point: point, snapshot: catalog.snapshot(),
                                              elementPID: { AXQuery.elementPID(at: $0) })
        switch result {
        case .success(let window): return window
        case .failure(let refusal): throw .refused(refusal)
        }
    }

    private func modifiers(_ args: ToolArguments) throws(ToolFailure) -> Set<Modifier> {
        switch Modifier.parse(args.strings("modifiers") ?? []) {
        case .success(let set): return set
        case .failure(let error):
            throw .invalid("Unknown modifier \"\(error.name)\". Use cmd, shift, option, ctrl or fn.")
        }
    }

    private func click(_ args: ToolArguments, _ context: CallContext) async throws(ToolFailure) -> ToolOutcome {
        let id = try windowArgument(args)
        guard let x = args.double("x"), let y = args.double("y") else { throw .invalid("x and y are required.") }
        let button = MouseButton(rawValue: args.string("button")?.lowercased() ?? "left") ?? .left
        let count = min(3, max(1, args.int("count") ?? 1))
        let modifiers = try modifiers(args)
        let flags = Modifier.flags(modifiers)
        let window = try allowedWindow(id, context)
        let point = try globalPoint(x: x, y: y, space: args.string("space"), window: window, context)

        for click in 1...count {
            _ = try check(point, windowID: id, context)
            poster.mouseDown(button, at: point, clickCount: click, flags: flags)
            try? await Task.sleep(for: .milliseconds(15))
            do throws(ToolFailure) {
                _ = try check(point, windowID: id, context)
            } catch {
                poster.releaseAll()
                throw error
            }
            poster.mouseUp(button, at: point, clickCount: click, flags: flags)
            if click < count { try? await Task.sleep(for: .milliseconds(40)) }
        }
        onClick?(point)
        let local = CGPoint(x: point.x - window.frame.minX, y: point.y - window.frame.minY)
        let what = count == 1 ? "Clicked" : count == 2 ? "Double-clicked" : "Triple-clicked"
        return .ok(.text("\(what) at \(InputGuard.format(local)) in window \(id)."),
                   target: resolver.bundleID(for: window.pid), window: id,
                   detail: "\(what.lowercased()) at \(InputGuard.format(local))")
    }

    private func drag(_ args: ToolArguments, _ context: CallContext) async throws(ToolFailure) -> ToolOutcome {
        let id = try windowArgument(args)
        guard let from = args.point("from"), let to = args.point("to") else {
            throw .invalid("from and to are required, each as {\"x\": …, \"y\": …}.")
        }
        let window = try allowedWindow(id, context)
        let space = args.string("space")
        let start = try globalPoint(x: from.x, y: from.y, space: space, window: window, context)
        let end = try globalPoint(x: to.x, y: to.y, space: space, window: window, context)
        let duration = min(10_000, max(50, args.int("duration_ms") ?? 300))
        let steps = max(5, min(200, duration / 16))
        let pause = Duration.milliseconds(duration / steps)

        _ = try check(start, windowID: id, context)
        poster.moveMouse(to: start)
        poster.mouseDown(.left, at: start, clickCount: 1, flags: [])
        var last = start
        for step in 1...steps {
            try? await Task.sleep(for: pause)
            let t = Double(step) / Double(steps)
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            do throws(ToolFailure) {
                _ = try check(point, windowID: id, context)
            } catch {
                poster.mouseUp(.left, at: last, clickCount: 1, flags: [])
                poster.releaseAll()
                if case .refused(let refusal) = error {
                    throw .refused(InputRefusal(check: refusal.check, message:
                        "The drag stopped at step \(step) of \(steps) and the button was released. " + refusal.message))
                }
                throw error
            }
            poster.mouseDragged(.left, to: point)
            last = point
        }
        poster.mouseUp(.left, at: end, clickCount: 1, flags: [])
        onClick?(end)
        return .ok(.text("Dragged in window \(id)."), target: resolver.bundleID(for: window.pid), window: id)
    }

    private func scroll(_ args: ToolArguments, _ context: CallContext) async throws(ToolFailure) -> ToolOutcome {
        let id = try windowArgument(args)
        guard let x = args.double("x"), let y = args.double("y") else { throw .invalid("x and y are required.") }
        let dx = max(-200, min(200, args.int("dx") ?? 0))
        let dy = max(-200, min(200, args.int("dy") ?? 0))
        guard dx != 0 || dy != 0 else { throw .invalid("Give dx or dy (lines to scroll).") }
        let window = try allowedWindow(id, context)
        let point = try globalPoint(x: x, y: y, space: args.string("space"), window: window, context)
        _ = try check(point, windowID: id, context)
        poster.scroll(dx: dx, dy: dy, at: point)
        return .ok(.text("Scrolled \(dy != 0 ? "\(dy) lines \(dy > 0 ? "down" : "up")" : "")\(dx != 0 && dy != 0 ? " and " : "")\(dx != 0 ? "\(abs(dx)) lines \(dx > 0 ? "right" : "left")" : "")."),
                   target: resolver.bundleID(for: window.pid), window: id)
    }

    // MARK: - Keyboard

    /// The frontmost app, if keyboard input may go to it now.
    func keyboardTarget(_ context: CallContext) throws(ToolFailure) -> (InputPoster.InputTarget, pid_t, String?) {
        try ensureLease(context)
        let front = NSWorkspace.shared.frontmostApplication
        if let refusal = context.guard.checkKeyboard(frontmostPID: front?.processIdentifier) {
            throw .refused(refusal)
        }
        guard let front else { throw .failed("No frontmost app.") }
        let bundleID = front.bundleIdentifier
        let delivery = bundleID.map(preferences.delivery(for:)) ?? .targeted
        return (delivery == .targeted ? .process(front.processIdentifier) : .system, front.processIdentifier, bundleID)
    }

    /// Between typed characters, unless the agent asks otherwise. Faster
    /// than this, browsers drop or reorder keys.
    static let defaultTypeDelayMs = 10
    /// After the last character, before the call returns.
    static let typeSettle: Duration = .milliseconds(150)

    func type(_ args: ToolArguments, _ context: CallContext) async throws(ToolFailure) -> ToolOutcome {
        guard let text = args.string("text"), !text.isEmpty else { throw .invalid("text is required.") }
        guard text.count <= 20_000 else { throw .invalid("That's too much text for one call; send it in parts of up to 20,000 characters.") }
        let delay = min(1000, max(0, args.int("delay_ms") ?? Self.defaultTypeDelayMs))
        let (target, pid, bundleID) = try keyboardTarget(context)
        var typed = 0
        for character in text {
            // Before every keystroke: the lease, and that the same allowed app
            // is still frontmost (what Global delivery relies on).
            let (_, currentPID, _) = try keyboardTarget(context)
            guard currentPID == pid else {
                throw .refused(InputRefusal(check: .frontmost, message:
                    "The frontmost app changed after \(typed) characters, so typing stopped. Call clickrelay_focus_window and send the rest."))
            }
            poster.type(character, target: target)
            typed += 1
            try? await Task.sleep(for: .milliseconds(max(delay, 4)))
        }
        // Apps like browsers handle keys asynchronously; without this a click
        // straight after (on Save, say) can land before the last keys do.
        try? await Task.sleep(for: Self.typeSettle)
        return .ok(.text("Typed \(typed) characters."), target: bundleID, detail: text)
    }

    func key(_ args: ToolArguments, _ context: CallContext) async throws(ToolFailure) -> ToolOutcome {
        guard let name = args.string("key"), !name.isEmpty else { throw .invalid("key is required, e.g. return or a.") }
        var modifiers = try modifiers(args)
        // "cmd+shift+z" in the key itself.
        var keyName = name
        if name.count > 1, name.contains("+") {
            let parts = name.split(separator: "+").map(String.init)
            keyName = parts.last ?? name
            switch Modifier.parse(Array(parts.dropLast())) {
            case .success(let more): modifiers.formUnion(more)
            case .failure(let error): throw .invalid("Unknown modifier \"\(error.name)\" in \(name).")
            }
        }
        guard let code = KeyMap.keyCode(for: keyName) else {
            throw .invalid("Unknown key \"\(keyName)\". Use a letter, digit, return, tab, space, delete, escape, an arrow (left, right, up, down), home, end, page_up, page_down, or f1 to f20.")
        }
        let front = NSWorkspace.shared.frontmostApplication
        let frontAllowed = front.map { context.lease.policy.allows(pid: $0.processIdentifier, resolver: resolver) } ?? false
        if let refusal = ShortcutPolicy.refusal(key: keyName, modifiers: modifiers, frontmostAllowed: frontAllowed) {
            throw .refused(InputRefusal(check: .shortcut, message: refusal))
        }
        let (target, _, bundleID) = try keyboardTarget(context)
        poster.press(code, modifiers: modifiers, target: target)
        let described = ShortcutPolicy.describe(key: KeyMap.normalize(keyName), modifiers: modifiers)
        return .ok(.text("Pressed \(described)."), target: bundleID, detail: described)
    }

    // MARK: - Focus and launch

    func focusWindow(_ args: ToolArguments, _ context: CallContext) async throws(ToolFailure) -> ToolOutcome {
        let window = try allowedWindow(try windowArgument(args), context)
        let element = try? await axWindow(window)
        try ensureLease(context)
        let pid = window.pid
        await Task.detached {
            if let element {
                AXUIElementPerformAction(element.element, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(element.element, kAXMainAttribute as CFString, kCFBooleanTrue)
            }
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }.value
        NSRunningApplication(processIdentifier: pid)?.activate()
        // Activation is asynchronous; give it a moment to land.
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        let bundleID = resolver.bundleID(for: pid)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            throw .failed("macOS didn't bring \(resolver.appName(for: pid) ?? "the app") to the front. Try again, or ask the user to click its window.")
        }
        focusLost[context.session.id] = nil
        return .ok(.text("Window \(window.id) is frontmost; keyboard input will go to \(resolver.appName(for: pid) ?? "it")."),
                   target: bundleID, window: window.id)
    }

    func launchApp(_ args: ToolArguments, _ context: CallContext) async throws(ToolFailure) -> ToolOutcome {
        guard let bundleID = args.string("bundle_id"), !bundleID.isEmpty else { throw .invalid("bundle_id is required.") }
        guard context.lease.policy.allows(bundleID: bundleID), !AccessPolicy.filePanelServices.contains(bundleID) else {
            throw .refused(InputRefusal(check: .window, message:
                "\(bundleID) isn't one of the allowed apps, so it can't be opened. Ask the user to allow it."))
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw .failed("\(bundleID) isn't installed on this Mac.")
        }
        try ensureLease(context)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let launched: Result<pid_t, ToolFailure> = await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                if let app { continuation.resume(returning: .success(app.processIdentifier)) }
                else { continuation.resume(returning: .failure(.failed("\(bundleID) didn't open: \(error?.localizedDescription ?? "unknown error").")))}
            }
        }
        _ = try launched.get()
        focusLost[context.session.id] = nil
        return .ok(.text("Opened \(AppCatalog.name(for: bundleID)). Call clickrelay_list_windows once its window is up."),
                   target: bundleID)
    }
}
