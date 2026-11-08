import Foundation

/// A reusable list of steps an agent keeps beside its project and runs in one
/// `clickrelay_run_script` call, so repeated UI work costs one tool call
/// instead of screenshots and trees. Elements are described (role, title,
/// identifier…), not referred to by ref, so a script survives across runs.
///
/// Running a script is the same as making its calls one by one: it needs the
/// session's lease, every step goes through the usual checks, and nothing in
/// it can create, extend or widen a lease.
///
/// File format (JSON):
///
///     {
///       "name": "export-log",
///       "app": "com.apple.dt.Xcode",
///       "params": { "scheme": "Scheme to pick" },
///       "steps": [
///         { "press": { "role": "menu_item", "title": "{{scheme}}" }, "timeout_s": 5 },
///         { "key": "cmd+b" }
///       ]
///     }
nonisolated struct Script: Sendable, Equatable {
    var name: String
    var description: String?
    /// The app steps act in, unless a step names its own.
    var app: String?
    /// Only windows whose title contains this, unless a step names its own.
    var window: String?
    var params: [ScriptParam] = []
    var steps: [ScriptStep]

    static let maxSteps = 200
}

nonisolated struct ScriptParam: Sendable, Equatable {
    var name: String
    var description: String?
    var defaultValue: String?
}

nonisolated struct ScriptStep: Sendable, Equatable {
    var action: ScriptAction
    var app: String?
    var window: String?
    /// Seconds to wait for the element to appear. Nil: the action's default.
    var timeout: Double?
    /// When the element isn't found, skip the step instead of stopping.
    var optional = false

    static let defaultTimeout: Double = 3
    static let defaultWaitTimeout: Double = 10
    static let maxTimeout: Double = 120
    /// wait_for can wait longer, for builds, uploads and the like.
    static let maxWaitTimeout: Double = 900

    var timeoutCap: Double { action.isWait ? Self.maxWaitTimeout : Self.maxTimeout }

    var effectiveTimeout: Double {
        min(timeoutCap, max(0, timeout ?? (action.isWait ? Self.defaultWaitTimeout : Self.defaultTimeout)))
    }

    /// Whether the on-device model may guess when nothing matches. Only for
    /// an element described with a hint, and never on an optional step or a
    /// wait_for, where a wrong guess is worse than skipping or waiting: a
    /// "Done" that isn't there must not press "Cancel". (A tie between
    /// elements that all match is always the model's to break.)
    var modelMayGuess: Bool {
        guard let target = action.target, target.hint != nil else { return false }
        return !optional && !action.isWait
    }
}

nonisolated enum ScriptAction: Sendable, Equatable {
    case press(ElementTarget, action: String?)
    case focus(ElementTarget)
    case setValue(ElementTarget, value: String)
    case waitFor(ElementTarget)
    case type(String)
    case key(String, modifiers: [String])
    case focusWindow
    case launchApp
    /// Seconds.
    case pause(Double)

    var target: ElementTarget? {
        switch self {
        case .press(let target, _), .focus(let target), .setValue(let target, _), .waitFor(let target):
            return target
        case .type, .key, .focusWindow, .launchApp, .pause:
            return nil
        }
    }

    var isKeyboard: Bool {
        switch self {
        case .type, .key: return true
        default: return false
        }
    }

    var isWait: Bool {
        if case .waitFor = self { return true }
        return false
    }

    /// Steps that act on the app (rather than look or wait).
    var isInput: Bool {
        switch self {
        case .press, .focus, .setValue, .type, .key, .focusWindow, .launchApp: return true
        case .waitFor, .pause: return false
        }
    }

    /// The single-call tool this step stands for, for the audit log.
    var toolName: String {
        switch self {
        case .press: return ToolName.press.rawValue
        case .focus: return ToolName.press.rawValue
        case .setValue: return ToolName.setValue.rawValue
        case .waitFor: return "clickrelay_wait_for"
        case .type: return ToolName.type.rawValue
        case .key: return ToolName.key.rawValue
        case .focusWindow: return ToolName.focusWindow.rawValue
        case .launchApp: return ToolName.launchApp.rawValue
        case .pause: return "clickrelay_wait"
        }
    }

    /// Short, for result text: `press AXButton "Save"`.
    var summary: String {
        switch self {
        case .press(let target, let action):
            return (action.map { "\($0) on" } ?? "press") + " " + target.summary
        case .focus(let target): return "focus " + target.summary
        case .setValue(let target, _): return "set the value of " + target.summary
        case .waitFor(let target): return "wait for " + target.summary
        case .type(let text):
            // Unfilled when validating without values: show which param it types.
            if text.contains("{{") { return "type \(text)" }
            return "type \(text.count) characters"
        case .key(let key, let modifiers): return "press " + (modifiers + [key]).joined(separator: "+")
        case .focusWindow: return "focus the window"
        case .launchApp: return "open the app"
        case .pause(let seconds): return "wait \(ScriptFormat.seconds(seconds))"
        }
    }
}

/// How a script describes an element. Every field given must match.
nonisolated struct ElementTarget: Sendable, Equatable {
    enum Scope: String, Sendable {
        /// The app's on-screen windows, front to back (sheets and popovers included).
        case windows
        /// The app's menu bar and its menus.
        case menus
    }

    /// Normalised to `AXButton` form.
    var role: String?
    /// Matches the element's title or its label (AXDescription).
    var title: String?
    var label: String?
    var value: String?
    var identifier: String?
    /// Free text for the on-device model when the fields above aren't enough.
    var hint: String?
    var enabled: Bool?
    var scope: Scope = .windows

    var hasText: Bool { title != nil || label != nil || value != nil || identifier != nil }

    var summary: String {
        var parts: [String] = [role ?? "element"]
        if let identifier { parts.append("#\(identifier)") }
        if let title { parts.append("\"\(title)\"") }
        if let label { parts.append("label \"\(label)\"") }
        if let value { parts.append("value \"\(value)\"") }
        if title == nil && label == nil && value == nil && identifier == nil, let hint { parts.append("(\(hint))") }
        if scope == .menus { parts.append("in the menus") }
        return parts.joined(separator: " ")
    }

    /// `button`, `menu_item`, `AXMenuItem` → `AXButton`, `AXMenuItem`.
    static func normaliseRole(_ role: String) -> String {
        let trimmed = role.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("AX") { return trimmed }
        let words = trimmed.split(whereSeparator: { $0 == "_" || $0 == " " || $0 == "-" })
        return "AX" + words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    /// Menu roles are found in the menu bar unless the script says otherwise.
    static func defaultScope(forRole role: String?) -> Scope {
        guard let role = role?.lowercased() else { return .windows }
        return ["axmenubaritem", "axmenuitem", "axmenu", "axmenubar"].contains(role) ? .menus : .windows
    }
}

/// A problem with a script, written for the model: what's wrong and where.
nonisolated struct ScriptError: Error, Equatable, Sendable {
    let message: String
}

// MARK: - Parsing

extension Script {
    /// Reads a script and fills in `{{param}}` values. Every declared param
    /// needs a value (given or default), and every value given must be declared,
    /// so a typo fails before anything runs.
    static func parse(_ object: [String: Any], params given: [String: String] = [:]) -> Result<Script, ScriptError> {
        check(object, params: given, requireParams: true).result
    }

    /// `parse`, plus warnings about things that are allowed but probably
    /// mistakes (unknown keys, role-only elements). With `requireParams`
    /// false, a param with no value stays as `{{name}}`, for validating a
    /// script before the values are known.
    static func check(_ object: [String: Any], params given: [String: String] = [:],
                      requireParams: Bool) -> (result: Result<Script, ScriptError>, warnings: [String]) {
        var parser = ScriptParser(object: object, given: given, requireParams: requireParams)
        do {
            return (.success(try parser.parse()), parser.warnings.items)
        } catch let error as ScriptError {
            return (.failure(error), parser.warnings.items)
        } catch {
            return (.failure(ScriptError(message: "\(error)")), parser.warnings.items)
        }
    }

    /// The script as a JSON-ready object, in the file format.
    var jsonObject: [String: Any] {
        var object: [String: Any] = ["name": name, "steps": steps.map(\.jsonObject)]
        if let description { object["description"] = description }
        if let app { object["app"] = app }
        if let window { object["window"] = window }
        if !params.isEmpty {
            var declared: [String: Any] = [:]
            for param in params {
                if let defaultValue = param.defaultValue {
                    var entry: [String: Any] = ["default": defaultValue]
                    if let description = param.description { entry["description"] = description }
                    declared[param.name] = entry
                } else {
                    declared[param.name] = param.description ?? ""
                }
            }
            object["params"] = declared
        }
        return object
    }

    /// Pretty-printed JSON for a file.
    var fileData: Data {
        let data = (try? JSONSerialization.data(withJSONObject: jsonObject,
                                                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{}".utf8)
        return data + Data([0x0A])
    }
}

extension ScriptStep {
    var jsonObject: [String: Any] {
        var object: [String: Any]
        switch action {
        case .press(let target, let action):
            object = ["press": target.jsonValue]
            if let action { object["action"] = action }
        case .focus(let target): object = ["focus": target.jsonValue]
        case .setValue(let target, let value): object = ["set_value": target.jsonValue, "value": value]
        case .waitFor(let target): object = ["wait_for": target.jsonValue]
        case .type(let text): object = ["type": text]
        case .key(let key, let modifiers):
            object = ["key": (modifiers + [key]).joined(separator: "+")]
        case .focusWindow: object = ["focus_window": true]
        case .launchApp: object = ["launch_app": true]
        case .pause(let seconds): object = ["wait": seconds]
        }
        if let app { object["app"] = app }
        if let window { object["window"] = window }
        if let timeout { object["timeout_s"] = timeout }
        if optional { object["optional"] = true }
        return object
    }
}

extension ElementTarget {
    var jsonValue: Any {
        var object: [String: Any] = [:]
        if let role { object["role"] = role }
        if let title { object["title"] = title }
        if let label { object["label"] = label }
        if let value { object["value"] = value }
        if let identifier { object["identifier"] = identifier }
        if let hint { object["hint"] = hint }
        if let enabled { object["enabled"] = enabled }
        if scope != Self.defaultScope(forRole: role) { object["in"] = scope.rawValue }
        return object
    }
}

private nonisolated struct ScriptParser {
    final class Warnings {
        var items: [String] = []
    }

    let object: [String: Any]
    let given: [String: String]
    let requireParams: Bool
    let warnings = Warnings()
    private var values: [String: String] = [:]

    init(object: [String: Any], given: [String: String], requireParams: Bool) {
        self.object = object
        self.given = given
        self.requireParams = requireParams
    }

    static let scriptKeys: Set<String> = ["name", "description", "app", "window", "params", "steps"]
    static let stepKeys: Set<String> = Set(actionKeys).union(["app", "window", "timeout_s", "optional", "note",
                                                              "action", "value", "modifiers"])
    static let elementKeys: Set<String> = ["role", "title", "label", "value", "identifier", "hint", "enabled", "in"]

    /// Keys ClickRelay doesn't read (a typo like "titel" or "timeout"), so
    /// the validator can point them out instead of them being ignored.
    private func warnUnknown(_ object: [String: Any], known: Set<String>, at place: String) {
        for key in object.keys.sorted() where !known.contains(Self.snakeCase(key)) {
            warnings.items.append("\(place) has \"\(key)\", which ClickRelay ignores. Known keys: "
                + known.sorted().joined(separator: ", ") + ".")
        }
    }

    static func snakeCase(_ key: String) -> String {
        var result = ""
        for character in key {
            if character.isUppercase {
                if !result.isEmpty { result += "_" }
                result += character.lowercased()
            } else {
                result.append(character)
            }
        }
        return result
    }

    mutating func parse() throws -> Script {
        let args = ToolArguments(object)
        warnUnknown(object, known: Self.scriptKeys, at: "The script")
        let name = args.string("name").flatMap { $0.isEmpty ? nil : $0 } ?? "script"
        let params = try parseParams(object["params"])
        let declared = Set(params.map(\.name))
        if let unknown = given.keys.sorted().first(where: { !declared.contains($0) }) {
            let list = declared.isEmpty ? "none" : declared.sorted().joined(separator: ", ")
            throw ScriptError(message: "The script doesn't declare a param called \"\(unknown)\". Its params: \(list).")
        }
        for param in params {
            guard let value = given[param.name] ?? param.defaultValue ?? (requireParams ? nil : "{{\(param.name)}}") else {
                throw ScriptError(message: "The script needs a value for \"\(param.name)\""
                    + (param.description.map { " (\($0))" } ?? "") + ". Pass it in params.")
            }
            values[param.name] = value
        }

        guard let rawSteps = object["steps"] as? [Any] else {
            throw ScriptError(message: "The script has no steps array.")
        }
        guard !rawSteps.isEmpty else { throw ScriptError(message: "The script's steps array is empty.") }
        guard rawSteps.count <= Script.maxSteps else {
            throw ScriptError(message: "The script has \(rawSteps.count) steps; the most is \(Script.maxSteps). Split it in two.")
        }
        let app = try args.string("app").map { try substitute($0, at: nil) }
        let window = try args.string("window").map { try substitute($0, at: nil) }
        var steps: [ScriptStep] = []
        for (index, raw) in rawSteps.enumerated() {
            guard let stepObject = raw as? [String: Any] else {
                throw ScriptError(message: "Step \(index + 1) isn't an object.")
            }
            let step = try parseStep(stepObject, number: index + 1)
            if step.action.target != nil || step.action == .focusWindow || step.action == .launchApp,
               step.app == nil, app == nil {
                throw ScriptError(message: "Step \(index + 1) needs an app: set \"app\" (a bundle ID) on the script or the step.")
            }
            steps.append(step)
        }
        return Script(name: name, description: args.string("description"), app: app, window: window,
                      params: params, steps: steps)
    }

    private func parseParams(_ raw: Any?) throws -> [ScriptParam] {
        switch raw {
        case nil, is NSNull:
            return []
        case let names as [Any]:
            return names.compactMap { $0 as? String }.map { ScriptParam(name: $0) }
        case let declared as [String: Any]:
            return declared.keys.sorted().map { name -> ScriptParam in
                switch declared[name] {
                case let description as String:
                    return ScriptParam(name: name, description: description.isEmpty ? nil : description)
                case let entry as [String: Any]:
                    let args = ToolArguments(entry)
                    return ScriptParam(name: name, description: args.string("description"),
                                       defaultValue: args.string("default"))
                default:
                    return ScriptParam(name: name)
                }
            }
        default:
            throw ScriptError(message: "params must be an object of name → description, or a list of names.")
        }
    }

    private static let actionKeys = ["press", "focus", "set_value", "wait_for", "type", "key",
                                     "focus_window", "launch_app", "wait"]

    private func parseStep(_ object: [String: Any], number: Int) throws -> ScriptStep {
        let args = ToolArguments(object)
        warnUnknown(object, known: Self.stepKeys, at: "Step \(number)")
        let present = Self.actionKeys.filter { args.value($0) != nil }
        guard present.count == 1, let key = present.first else {
            let what = present.isEmpty ? "no action" : "more than one action (\(present.joined(separator: ", ")))"
            throw ScriptError(message: "Step \(number) has \(what). Give exactly one of: "
                + Self.actionKeys.joined(separator: ", ") + ".")
        }
        var step = ScriptStep(action: .focusWindow)
        step.app = try args.string("app").map { try substitute($0, at: number) }
        step.window = try args.string("window").map { try substitute($0, at: number) }
        step.timeout = args.double("timeout_s")
        step.optional = args.bool("optional") ?? false
        defer {
            if let timeout = step.timeout, timeout > step.timeoutCap {
                warnings.items.append("Step \(number) asks to wait \(ScriptFormat.seconds(timeout)), but "
                    + "\(step.action.isWait ? "wait_for" : "this step") waits at most "
                    + "\(ScriptFormat.seconds(step.timeoutCap)), so it'll stop there.")
            }
            if case .press(let target, let action) = step.action, action == nil,
               target.role == "AXMenuBarItem" {
                warnings.items.append("Step \(number) presses a menu bar item. ClickRelay presses menu items "
                    + "directly without opening their menus, so it skips this step. You can remove it.")
            }
        }

        switch key {
        case "press":
            step.action = .press(try target(args.value("press"), number), action: args.string("action"))
        case "focus":
            step.action = .focus(try target(args.value("focus"), number))
        case "set_value":
            guard let value = args.string("value") else {
                throw ScriptError(message: "Step \(number) (set_value) needs a \"value\".")
            }
            step.action = .setValue(try target(args.value("set_value"), number), value: try substitute(value, at: number))
        case "wait_for":
            step.action = .waitFor(try target(args.value("wait_for"), number))
        case "type":
            guard let text = args.string("type"), !text.isEmpty else {
                throw ScriptError(message: "Step \(number) (type) needs the text to type.")
            }
            step.action = .type(try substitute(text, at: number))
        case "key":
            guard let raw = args.string("key"), !raw.isEmpty else {
                throw ScriptError(message: "Step \(number) (key) needs a key, like \"return\" or \"cmd+s\".")
            }
            let combo = try substitute(raw, at: number)
            var modifiers = args.strings("modifiers") ?? []
            var keyName = combo
            if combo.count > 1, combo.contains("+") {
                let parts = combo.split(separator: "+").map(String.init)
                keyName = parts.last ?? combo
                modifiers += parts.dropLast()
            }
            step.action = .key(keyName, modifiers: modifiers)
        case "focus_window":
            step.action = .focusWindow
        case "launch_app":
            if let bundleID = args.string("launch_app"), bundleID.contains(".") {
                step.app = try substitute(bundleID, at: number)
            }
            step.action = .launchApp
        case "wait":
            guard let seconds = args.double("wait"), seconds >= 0, seconds <= 60 else {
                throw ScriptError(message: "Step \(number) (wait) needs a number of seconds from 0 to 60.")
            }
            step.action = .pause(seconds)
        default:
            break
        }
        return step
    }

    private func target(_ raw: Any?, _ number: Int) throws -> ElementTarget {
        if let title = raw as? String {
            guard !title.isEmpty else { throw ScriptError(message: "Step \(number) has an empty element.") }
            return ElementTarget(title: try substitute(title, at: number))
        }
        guard let object = raw as? [String: Any] else {
            throw ScriptError(message: "Step \(number) needs an element: an object with role, title, label, "
                + "value, identifier or hint, or just a title as a string.")
        }
        let args = ToolArguments(object)
        warnUnknown(object, known: Self.elementKeys, at: "Step \(number)'s element")
        func text(_ name: String) throws -> String? {
            guard let value = args.string(name), !value.isEmpty else { return nil }
            return try substitute(value, at: number)
        }
        var target = ElementTarget()
        target.role = try text("role").map(ElementTarget.normaliseRole)
        target.title = try text("title")
        target.label = try text("label")
        target.value = try text("value")
        target.identifier = try text("identifier")
        target.hint = try text("hint")
        target.enabled = args.bool("enabled")
        if let scope = args.string("in") {
            guard let parsed = ElementTarget.Scope(rawValue: scope.lowercased()) else {
                throw ScriptError(message: "Step \(number): \"in\" must be \"windows\" or \"menus\".")
            }
            target.scope = parsed
        } else {
            target.scope = ElementTarget.defaultScope(forRole: target.role)
        }
        guard target.hasText || target.role != nil || target.hint != nil else {
            throw ScriptError(message: "Step \(number)'s element has nothing to match on. Give a title, "
                + "label, identifier, value, role or hint.")
        }
        if !target.hasText {
            warnings.items.append("Step \(number)'s element has no title, label, identifier or value, so it "
                + "only matches when it's the only one of its role" + (target.hint != nil ? " or the on-device model picks it." : "."))
        }
        return target
    }

    /// Replaces `{{name}}` with the param's value.
    private func substitute(_ text: String, at step: Int?) throws -> String {
        guard text.contains("{{") else { return text }
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "{{") {
            result += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "}}") else {
                result += rest[open.lowerBound...]
                return result
            }
            let name = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            guard let value = values[name] else {
                let place = step.map { "Step \($0)" } ?? "The script"
                throw ScriptError(message: "\(place) uses {{\(name)}}, which isn't in the script's params. "
                    + "Declare it under \"params\".")
            }
            result += value
            rest = rest[close.upperBound...]
        }
        return result + rest
    }
}

/// `clickrelay_validate_script`: checks a script without running it, so an
/// agent can fix a script it wrote before it needs the user to unlock. Pure,
/// so the bridge answers it itself (no app, no lease).
nonisolated enum ScriptCheck {
    static func result(_ raw: Any?, params: Any?, label: String?,
                       isInstalled: (String) -> Bool) -> ToolResult {
        var object = raw
        if let text = raw as? String, let data = text.data(using: .utf8) {
            object = try? JSONSerialization.jsonObject(with: data)
        }
        let name = label ?? "The script"
        guard let object = object as? [String: Any] else {
            return .error("Pass the script's path (relative to your working directory), or the script itself as \"script\".")
        }
        let given = stringParams(params)
        let (result, parseWarnings) = Script.check(object, params: given, requireParams: false)
        var warnings = parseWarnings
        let script: Script
        switch result {
        case .failure(let error):
            var lines = ["\(name) isn't valid: \(error.message)"]
            if !warnings.isEmpty { lines += ["Also:"] + warnings.map { "- " + $0 } }
            return .error(lines.joined(separator: "\n"))
        case .success(let parsed):
            script = parsed
        }

        for app in Set(script.steps.compactMap { $0.app ?? script.app }).sorted() where !isInstalled(app) {
            warnings.append("No app with bundle ID \(app) is installed on this Mac.")
        }
        if script.app == nil {
            let loose = script.steps.indices
                .filter { script.steps[$0].app == nil && script.steps[$0].action.isKeyboard }
                .map { String($0 + 1) }
            if !loose.isEmpty {
                warnings.append("Step\(loose.count == 1 ? "" : "s") \(loose.joined(separator: ", ")) type into whichever allowed app "
                    + "is frontmost, since neither the script nor the step names an app.")
            }
        }

        var lines = ["\(name) is valid: \"\(script.name)\", \(script.steps.count) step\(script.steps.count == 1 ? "" : "s")"
            + (script.app.map { ", in \($0)" } ?? "") + "."]
        if !script.params.isEmpty {
            let described = script.params.map { param -> String in
                if let value = given[param.name] { return "\(param.name) = \"\(value)\"" }
                if let value = param.defaultValue { return "\(param.name) (default \"\(value)\")" }
                return "\(param.name) (needs a value when you run it)"
            }
            lines.append("Params: " + described.joined(separator: ", ") + ".")
        }
        lines.append("Steps:")
        for (index, step) in script.steps.enumerated() {
            var line = "\(index + 1). \(step.action.summary)"
            if let app = step.app, app != script.app { line += " in \(app)" }
            if let window = step.window { line += ", window \"\(window)\"" }
            if step.action.target != nil || step.action == .focusWindow {
                line += ", waits up to \(ScriptFormat.seconds(step.effectiveTimeout))"
            }
            if step.optional { line += ", optional" }
            lines.append(line)
        }
        if !warnings.isEmpty { lines += ["Warnings:"] + warnings.map { "- " + $0 } }
        return .text(lines.joined(separator: "\n"))
    }

    /// Param values as strings, however the agent sent them.
    static func stringParams(_ raw: Any?) -> [String: String] {
        var given: [String: String] = [:]
        if let params = raw as? [String: Any] {
            for (name, value) in params {
                if let text = ToolArguments(["v": value]).string("v") { given[name] = text }
            }
        }
        return given
    }
}

nonisolated enum ScriptFormat {
    static func seconds(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f s", value) : "\(Int(value.rounded())) s"
    }
}
