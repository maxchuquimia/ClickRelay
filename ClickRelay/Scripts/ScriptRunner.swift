import AppKit
import ApplicationServices
import Foundation

/// One step of a script run, for the audit log and the activity feed. Logged
/// like the single call it stands for, plus the script and step number.
struct ScriptStepLog {
    let session: AgentSession
    let leaseID: UUID
    let script: String
    let step: Int
    let tool: String
    let arguments: [String: Any]
    let outcome: AuditEntry.Outcome
    let check: String?
    let message: String?
    let targetBundleID: String?
    let matchedBy: MatchMethod?
    let durationMs: Int
}

extension MatchCandidate {
    init(_ node: AXNode, rank: Int) {
        self.init(role: node.role, subrole: node.subrole, title: node.title, label: node.label,
                  value: node.value, identifier: node.identifier, enabled: node.enabled,
                  interactive: AXQuery.isInteractive(node), rank: rank)
    }
}

/// `clickrelay_run_script` and `clickrelay_save_script`.
///
/// A run is the same as the agent making each call itself: it needs this
/// session's lease (re-checked before every step and, inside each step, before
/// every event), only acts in allowed apps, and holds the input queue for the
/// whole run so another agent can't type into the middle of it. Nothing in a
/// script can create, extend or widen a lease.
extension ToolRouter {
    private struct StepDone {
        var detail: String?
        var matchedBy: MatchMethod?
        var matched: String?
        var target: String?
        var skipped: String?
    }

    private struct StepFailure: Error {
        let message: String
        let outcome: AuditEntry.Outcome
        let check: String?
    }

    private struct Report {
        var completed = 0
        var failure: (step: Int, summary: String, error: StepFailure)?
        var notes: [String] = []
    }

    private struct Found {
        let node: AXNode
        let pid: pid_t
        let method: MatchMethod
        let line: String
    }

    // MARK: - Run

    func runScript(_ args: ToolArguments, _ context: CallContext) async throws(ToolFailure) -> ToolOutcome {
        var raw = args.value("script")
        if let text = raw as? String, let data = text.data(using: .utf8) {
            raw = try? JSONSerialization.jsonObject(with: data)
        }
        guard let object = raw as? [String: Any] else {
            throw .invalid("Pass the script's path (relative to your working directory), or the script itself as \"script\".")
        }
        let given = ScriptCheck.stringParams(args.value("params"))
        let script: Script
        switch Script.parse(object, params: given) {
        case .success(let parsed): script = parsed
        case .failure(let error): throw .invalid(error.message)
        }

        // Every app the script names must be allowed before anything runs.
        let apps = Set(script.steps.compactMap { $0.app ?? script.app })
        for bundleID in apps.sorted() where !context.lease.policy.allows(bundleID: bundleID) {
            let name = AppCatalog.name(for: bundleID)
            throw .refused(InputRefusal(check: .window, message:
                "The script works in \(name) (\(bundleID)), which isn't allowed. Ask the user to allow \(name), then run it again."))
        }

        let label = args.string("path") ?? script.name
        let started = ContinuousClock.now
        let report = await queue.run { [self] () async -> Report in
            await self.closeMenus(in: apps)
            var report = await self.execute(script, label: label, context)
            if report.failure != nil { self.poster.releaseAll() }
            // Never leave the Mac with a menu open: the app would sit in menu
            // tracking, and the Dock and hover effects stop working until the
            // user closes it.
            if await self.closeMenus(in: apps) > 0 {
                report.notes.append("ClickRelay closed a menu the script left open.")
            }
            return report
        }
        let seconds = Self.seconds(since: started)
        let total = script.steps.count
        var lines: [String] = []
        let outcome: ToolOutcome
        if let failure = report.failure {
            let ran = failure.step == 1 ? "Nothing before it ran."
                : failure.step == 2 ? "Step 1 ran." : "Steps 1 to \(failure.step - 1) ran."
            lines.append("\"\(script.name)\" stopped at step \(failure.step) of \(total) (\(failure.summary)): "
                + failure.error.message + " " + ran)
            lines += report.notes
            var result = ToolOutcome(result: .error(lines.joined(separator: "\n")), outcome: failure.error.outcome,
                                     check: failure.error.check)
            result.targetBundleID = script.app
            outcome = result
        } else {
            lines.append("Ran \"\(script.name)\": all \(total) step\(total == 1 ? "" : "s") in \(ScriptFormat.seconds(seconds)).")
            lines += report.notes
            outcome = .ok(.text(lines.joined(separator: "\n")), target: script.app)
        }
        return outcome
    }

    private func execute(_ script: Script, label: String, _ context: CallContext) async -> Report {
        var report = Report()
        for (index, step) in script.steps.enumerated() {
            let number = index + 1
            let started = ContinuousClock.now
            var done = StepDone()
            var failure: StepFailure?
            if Task.isCancelled {
                failure = StepFailure(message: "The agent disconnected, so the script stopped.", outcome: .error, check: nil)
            } else {
                do {
                    done = try await perform(step, script: script, context)
                } catch let error as StepFailure {
                    failure = error
                } catch {
                    failure = StepFailure(message: "\(error)", outcome: .error, check: nil)
                }
            }
            onScriptStep?(ScriptStepLog(
                session: context.session, leaseID: context.lease.id, script: label, step: number,
                tool: step.action.toolName, arguments: Self.logArguments(step),
                outcome: failure?.outcome ?? .ok, check: failure?.check,
                message: failure?.message ?? done.skipped,
                targetBundleID: done.target ?? step.app ?? script.app, matchedBy: done.matchedBy,
                durationMs: Int(Self.seconds(since: started) * 1000)))
            if let failure {
                report.failure = (number, step.action.summary, failure)
                return report
            }
            report.completed += 1
            // A moment for the app to catch up before the next step, as a
            // person's pace would give it.
            if step.action.isInput, number < script.steps.count {
                try? await Task.sleep(for: Self.settle)
            }
            if let skipped = done.skipped {
                report.notes.append("Step \(number) was optional and skipped: \(skipped)")
            }
            if let method = done.matchedBy, method == .model || method == .partial, let matched = done.matched {
                let how = method == .model ? "by the on-device model" : "by partial text"
                report.notes.append("Step \(number) matched \(matched) \(how). If that's the right one, "
                    + "put its exact title or identifier in the script so it matches directly.")
            }
            if let detail = done.detail { report.notes.append("Step \(number): \(detail)") }
        }
        return report
    }

    /// Runs one step. Throws `StepFailure` (an untyped throw, so ToolFailure
    /// from the shared tool code is converted here).
    private func perform(_ step: ScriptStep, script: Script, _ context: CallContext) async throws -> StepDone {
        let app = step.app ?? script.app
        let window = step.window ?? script.window
        do throws(ToolFailure) {
            try ensureLease(context)
            switch step.action {
            case .pause, .waitFor, .focusWindow, .launchApp:
                break
            default:
                if let lost = focusLost[context.session.id] {
                    throw .refused(InputRefusal(check: .focus, message:
                        "Focus moved to \(lost), which isn't allowed, so input is paused. Add a focus_window step before this one."))
                }
            }

            var done = StepDone(target: app)
            switch step.action {
            case .pause(let seconds):
                try await pause(seconds, context)
                return done

            case .launchApp:
                guard let app else { throw .invalid("This step needs an app.") }
                _ = try await launchApp(ToolArguments(["bundle_id": app]), context)

            case .focusWindow:
                guard let app else { throw .invalid("This step needs an app.") }
                switch try await waitForWindow(app: app, title: window, timeout: step.effectiveTimeout, context) {
                case .success(let found):
                    _ = try await focusWindow(ToolArguments(["window_id": Int(found.id)]), context)
                case .failure(let missing):
                    if step.optional { done.skipped = missing.message; return done }
                    throw .failed(missing.message)
                }

            case .type(let text):
                try checkFrontmost(app, context)
                _ = try await type(ToolArguments(["text": text]), context)

            case .key(let name, let modifiers):
                try checkFrontmost(app, context)
                _ = try await key(ToolArguments(["key": name, "modifiers": modifiers]), context)

            case .press(let target, _), .focus(let target), .setValue(let target, _), .waitFor(let target):
                guard let app else { throw .invalid("This step needs an app.") }
                let found: Found
                switch try await find(target, step: step, app: app, window: window, context) {
                case .success(let element): found = element
                case .failure(let missing):
                    if step.optional { done.skipped = missing.message; return done }
                    throw .failed(missing.message)
                }
                done.matchedBy = found.method
                done.matched = found.line
                done.target = resolver.bundleID(for: found.pid) ?? app
                switch step.action {
                case .press(let target, let action):
                    if target.scope == .menus {
                        let node = found.node
                        let pid = found.pid
                        let opensMenu = await Task.detached { AXQuery.opensMenu(node) }.value
                        if opensMenu, action == nil || action?.lowercased() == "axpress" {
                            // Pressing it would only open the menu, and leave
                            // it stuck open. The item inside works without it.
                            done.detail = "ClickRelay presses menu items directly, so it didn't open "
                                + "\(Self.name(of: node)). You can remove this step."
                            return done
                        }
                        _ = await Task.detached { AXQuery.closeOpenMenus(pid: pid) }.value
                    }
                    _ = try await performPress(found.node.element, pid: found.pid, requested: action ?? "AXPress", context)
                case .focus:
                    _ = try await performPress(found.node.element, pid: found.pid, requested: "focus", context)
                case .setValue(_, let value):
                    _ = try await performSetValue(found.node.element, pid: found.pid, value: value, context)
                default:
                    return done   // wait_for only waits
                }
            }
            if let note = afterInput(context) { done.detail = note }
            return done
        } catch {
            switch error {
            case .refused(let refusal):
                throw StepFailure(message: refusal.message, outcome: .refused, check: refusal.check.rawValue)
            case .invalid(let message):
                throw StepFailure(message: message, outcome: .error, check: "arguments")
            case .failed(let message):
                throw StepFailure(message: message, outcome: .error, check: nil)
            }
        }
    }

    // MARK: - Finding things

    private struct Missing: Error {
        let message: String
    }

    /// Polls for the element until it's found or the step's timeout passes.
    /// Exact tiers on every poll; the on-device model only for a tie (at once)
    /// or a miss (once, at the end).
    private func find(_ target: ElementTarget, step: ScriptStep, app: String, window: String?,
                      _ context: CallContext) async throws(ToolFailure) -> Result<Found, Missing> {
        let deadline = ContinuousClock.now + .milliseconds(Int(step.effectiveTimeout * 1000))
        let appName = AppCatalog.name(for: app)
        while true {
            try ensureLease(context)
            let gathered = await gather(target.scope, app: app, window: window, context)
            let timedOut = ContinuousClock.now >= deadline || Task.isCancelled
            let isTie: Bool
            switch ElementMatcher.match(target, in: gathered.candidates) {
            case .unique(let index, let method):
                return .success(try found(index, method, gathered))
            case .ambiguous:
                isTie = true
            case .noMatch:
                guard timedOut else {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                isTie = false
            }
            let result = await ElementMatcher.pick(target, step: step.action.summary, in: gathered.candidates,
                                                   allowModel: step.modelMayGuess, chooser: chooser)
            switch result {
            case .found(let index, let method):
                return .success(try found(index, method, gathered))
            case .notFound(let closest, let note):
                let lines = closest.map { gathered.candidates[$0].line }.joined(separator: "; ")
                var message: String
                let waited = step.effectiveTimeout > 0
                    ? " after waiting \(ScriptFormat.seconds(step.effectiveTimeout))" : ""
                if isTie {
                    message = "Several elements in \(appName) fit equally: \(lines). Add an identifier, "
                        + "role or more of the title to the step."
                } else if let problem = gathered.problem {
                    message = problem
                    if step.effectiveTimeout > 0 {
                        message += " ClickRelay waited \(ScriptFormat.seconds(step.effectiveTimeout)) for it."
                    }
                } else {
                    message = "No element in \(appName) matched\(waited)."
                    if !closest.isEmpty { message += " Closest: \(lines)." }
                }
                if let note { message += " (The on-device model couldn't help: \(note).)" }
                return .failure(Missing(message: message))
            }
        }
    }

    private func found(_ index: Int, _ method: MatchMethod, _ gathered: Gathered) throws(ToolFailure) -> Found {
        let node = gathered.nodes[index]
        guard let pid = node.element.pid else {
            throw .failed("The element went away as it was found. Run the script again.")
        }
        return Found(node: node, pid: pid, method: method, line: gathered.candidates[index].line)
    }

    private struct Gathered {
        var nodes: [AXNode] = []
        var candidates: [MatchCandidate] = []
        /// Why there was nothing to look in (app not running, no window).
        var problem: String?
    }

    /// Every element the step could mean: the app's on-screen windows front
    /// to back, or its menu bar.
    private func gather(_ scope: ElementTarget.Scope, app: String, window title: String?,
                        _ context: CallContext) async -> Gathered {
        var gathered = Gathered()
        let appName = AppCatalog.name(for: app)
        let pids = NSRunningApplication.runningApplications(withBundleIdentifier: app)
            .map(\.processIdentifier)
            .filter { context.lease.policy.allows(pid: $0, resolver: resolver) }
        guard !pids.isEmpty else {
            gathered.problem = "\(appName) isn't running. Add a launch_app step before this one, or open it first."
            return gathered
        }
        // An app the user is working in for a hand-off is never read.
        if pids.contains(where: { handOffs.blocking(pid: $0) != nil }) {
            gathered.problem = "The user is working in \(appName) for a hand-off, so ClickRelay won't read it "
                + "until they're done. Run the script again after that."
            return gathered
        }
        switch scope {
        case .menus:
            let nodes = await Task.detached { () -> [AXNode] in
                pids.flatMap { pid -> [AXNode] in
                    guard let bar = AXQuery.menuBar(pid: pid) else { return [] }
                    return AXQuery.walk(root: bar, windowOrigin: .zero, maxDepth: 10, interactiveOnly: false,
                                        limit: 6000)
                }
            }.value
            gathered.nodes = nodes
            gathered.candidates = nodes.map { MatchCandidate($0, rank: 0) }
            if nodes.isEmpty { gathered.problem = "ClickRelay couldn't read \(appName)'s menu bar with Accessibility." }
        case .windows:
            let windows = catalog.snapshot().windows.filter { window in
                window.isAppWindow && pids.contains(window.pid)
                    && (title == nil || window.title.localizedCaseInsensitiveContains(title!))
            }
            guard !windows.isEmpty else {
                gathered.problem = title.map { "\(appName) has no window on screen with \"\($0)\" in its title." }
                    ?? "\(appName) has no window on screen. Add a focus_window or launch_app step first."
                return gathered
            }
            for (rank, window) in windows.prefix(8).enumerated() {
                guard let root = try? await axWindow(window) else { continue }
                let origin = window.frame.origin
                let nodes = await Task.detached {
                    AXQuery.walk(root: root, windowOrigin: origin, maxDepth: 40, interactiveOnly: false)
                }.value
                gathered.nodes += nodes
                gathered.candidates += nodes.map { MatchCandidate($0, rank: rank) }
            }
        }
        return gathered
    }

    private func waitForWindow(app: String, title: String?, timeout: Double,
                               _ context: CallContext) async throws(ToolFailure) -> Result<WindowInfo, Missing> {
        let deadline = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
        while true {
            try ensureLease(context)
            let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: app).map(\.processIdentifier))
            let window = catalog.snapshot().windows.first { window in
                window.isAppWindow && pids.contains(window.pid)
                    && context.lease.policy.allows(pid: window.pid, resolver: resolver)
                    && (title == nil || window.title.localizedCaseInsensitiveContains(title!))
            }
            if let window { return .success(window) }
            if ContinuousClock.now >= deadline || Task.isCancelled {
                let name = AppCatalog.name(for: app)
                if pids.isEmpty { return .failure(Missing(message: "\(name) isn't running. Add a launch_app step first.")) }
                return .failure(Missing(message: title.map { "\(name) has no window with \"\($0)\" in its title." }
                    ?? "\(name) has no window on screen."))
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Keystrokes in a script go to the app the script (or step) names, not
    /// whichever allowed app happens to be in front.
    private func checkFrontmost(_ app: String?, _ context: CallContext) throws(ToolFailure) {
        guard let app else { return }
        let front = NSWorkspace.shared.frontmostApplication
        guard front?.bundleIdentifier != app else { return }
        let frontName = front?.localizedName ?? "another app"
        throw .refused(InputRefusal(check: .frontmost, message:
            "This step types into \(AppCatalog.name(for: app)), but \(frontName) is frontmost. Add a focus_window step before it."))
    }

    /// The pause after each input step.
    static let settle: Duration = .milliseconds(150)

    /// Closes menus left open in the script's apps (skipping one the user is
    /// working in for a hand-off). Restoring, like `releaseAll`, so it runs
    /// even when the run stopped because the lease ended.
    @discardableResult
    private func closeMenus(in apps: Set<String>) async -> Int {
        let pids = apps.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            .map(\.processIdentifier)
            .filter { handOffs.blocking(pid: $0) == nil }
        guard !pids.isEmpty else { return 0 }
        return await Task.detached {
            pids.reduce(0) { $0 + AXQuery.closeOpenMenus(pid: $1) }
        }.value
    }

    private static func name(of node: AXNode) -> String {
        let text = [node.title, node.label].compactMap { $0 }.first { !$0.isEmpty }
        return text.map { "\"\($0)\"" } ?? "the menu"
    }

    private func pause(_ seconds: Double, _ context: CallContext) async throws(ToolFailure) {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < deadline, !Task.isCancelled {
            try ensureLease(context)
            try? await Task.sleep(for: .milliseconds(min(100, max(1, Int((deadline - ContinuousClock.now) / .milliseconds(1))))))
        }
        try ensureLease(context)
    }

    // MARK: - Logging

    /// Shaped like the single call each step stands for, so the audit log's
    /// redaction (typed text, set values) applies the same way.
    private static func logArguments(_ step: ScriptStep) -> [String: Any] {
        switch step.action {
        case .type(let text): return ["text": text]
        case .setValue(let target, let value): return ["element": target.jsonValue, "value": value]
        default: return step.jsonObject
        }
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    // MARK: - Recording and saving

    /// Notes a successful single call as a script step for `save_script`.
    func recordForScript(_ tool: ToolName, _ args: ToolArguments, _ context: CallContext) {
        let session = context.session.id
        switch tool {
        case .press, .setValue:
            guard let ref = args.string("ref"), let entry = elements.entry(ref, session: session),
                  let pid = entry.element.pid else { return }
            let target = ElementTarget.describing(entry.node)
            let action: ScriptAction
            if tool == .setValue {
                action = .setValue(target, value: args.string("value") ?? "")
            } else {
                let requested = args.string("action") ?? "AXPress"
                if ["focus", "axfocus", "axfocused"].contains(requested.lowercased()) {
                    action = .focus(target)
                } else {
                    action = .press(target, action: requested.lowercased() == "axpress" || requested.lowercased() == "press"
                                    ? nil : requested)
                }
            }
            recorder.record(ScriptStep(action: action, app: resolver.bundleID(for: pid)), session: session)
        case .type:
            guard let text = args.string("text"), !text.isEmpty else { return }
            let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            recorder.record(ScriptStep(action: .type(text), app: app), session: session)
        case .key:
            guard var name = args.string("key"), !name.isEmpty else { return }
            var modifiers = args.strings("modifiers") ?? []
            if name.count > 1, name.contains("+") {
                let parts = name.split(separator: "+").map(String.init)
                name = parts.last ?? name
                modifiers += parts.dropLast()
            }
            let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            recorder.record(ScriptStep(action: .key(name, modifiers: modifiers), app: app), session: session)
        case .focusWindow:
            guard let raw = args.int("window_id"), raw > 0, raw <= Int(UInt32.max),
                  let window = catalog.snapshot().window(CGWindowID(raw)),
                  let app = resolver.bundleID(for: window.pid) else { return }
            recorder.record(ScriptStep(action: .focusWindow, app: app), session: session)
        case .launchApp:
            guard let app = args.string("bundle_id") else { return }
            recorder.record(ScriptStep(action: .launchApp, app: app), session: session)
        case .click, .drag, .scroll:
            recorder.skip(session: session)
        default:
            break
        }
    }

    /// Builds the script from the session's recorded calls. The bridge writes
    /// the file (the last text block) into the agent's project; the app never
    /// writes there.
    func saveScript(_ args: ToolArguments, _ context: CallContext) throws(ToolFailure) -> ToolOutcome {
        let session = context.session.id
        guard let name = args.string("name")?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            throw .invalid("name is required.")
        }
        var steps = recorder.steps(for: session)
        if let last = args.int("last"), last > 0 { steps = Array(steps.suffix(last)) }
        guard !steps.isEmpty else {
            throw .invalid("There's nothing to save: you haven't made any press, set_value, type, key, "
                + "focus_window or launch_app calls since you connected or last saved.")
        }
        var params: [String: String] = [:]
        if let raw = args.value("params") as? [String: Any] {
            for (param, value) in raw {
                if let text = ToolArguments(["v": value]).string("v") { params[param] = text }
            }
        }
        let built = ScriptBuilder.build(name: name, description: args.string("description"), steps: steps,
                                        params: params, skipped: recorder.skippedCount(for: session))
        recorder.clear(session: session)
        var lines = ["Recorded \(steps.count) step\(steps.count == 1 ? "" : "s") as \"\(name)\"."]
        lines += built.warnings
        let file = String(decoding: built.script.fileData, as: UTF8.self)
        return .ok(ToolResult(content: [.text(lines.joined(separator: "\n")), .text(file)], isError: false),
                   target: built.script.app)
    }
}
