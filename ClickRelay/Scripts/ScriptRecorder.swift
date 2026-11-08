import Foundation

/// Each session's successful input calls, as script steps, so
/// `clickrelay_save_script` can turn work the agent just did into a script.
/// In memory only, capped, and never includes steps run by a script.
@MainActor
final class ScriptRecorder {
    static let limit = 200

    private var steps: [String: [ScriptStep]] = [:]
    /// Coordinate calls (click, drag, scroll) left out, since scripts find
    /// elements instead.
    private var skipped: [String: Int] = [:]

    func record(_ step: ScriptStep, session: String) {
        var list = steps[session] ?? []
        list.append(step)
        if list.count > Self.limit { list.removeFirst(list.count - Self.limit) }
        steps[session] = list
    }

    func skip(session: String) {
        skipped[session, default: 0] += 1
    }

    func steps(for session: String) -> [ScriptStep] { steps[session] ?? [] }
    func skippedCount(for session: String) -> Int { skipped[session] ?? 0 }

    func clear(session: String) {
        steps[session] = nil
        skipped[session] = nil
    }
}

/// Turns recorded steps into a script file's contents.
nonisolated enum ScriptBuilder {
    /// - Parameter params: param name → the literal text it replaces (in typed
    ///   text, set values and element text). The literal becomes the default.
    static func build(name: String, description: String?, steps recorded: [ScriptStep],
                      params: [String: String], skipped: Int) -> (script: Script, warnings: [String]) {
        // The app most steps act in becomes the script's; the rest keep their own.
        var counts: [String: Int] = [:]
        for step in recorded { if let app = step.app { counts[app, default: 0] += 1 } }
        let app = counts.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key

        // Longest literal first, so "Release-arm64" wins over "Release".
        let replacements = params.filter { !$0.value.isEmpty }
            .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
        func substituteText(_ text: String) -> String {
            var result = text
            for (name, literal) in replacements {
                result = result.replacingOccurrences(of: literal, with: "{{\(name)}}")
            }
            return result
        }
        func substituteTarget(_ target: ElementTarget) -> ElementTarget {
            var target = target
            target.title = target.title.map(substituteText)
            target.label = target.label.map(substituteText)
            target.value = target.value.map(substituteText)
            return target
        }

        var warnings: [String] = []
        var steps: [ScriptStep] = []
        for (index, original) in recorded.enumerated() {
            var step = original
            if step.app == app { step.app = nil }
            switch step.action {
            case .press(let target, let action): step.action = .press(substituteTarget(target), action: action)
            case .focus(let target): step.action = .focus(substituteTarget(target))
            case .setValue(let target, let value):
                step.action = .setValue(substituteTarget(target), value: substituteText(value))
            case .waitFor(let target): step.action = .waitFor(substituteTarget(target))
            case .type(let text): step.action = .type(substituteText(text))
            case .key, .focusWindow, .launchApp, .pause: break
            }
            if let target = step.action.target, !target.hasText {
                warnings.append("Step \(index + 1) (\(target.role ?? "element")) had no title, label or identifier, "
                    + "so it's matched by role alone. Add a title or hint to it before relying on the script.")
            }
            steps.append(step)
        }
        let used = replacements.map { $0.key }.filter { name in
            steps.contains { ScriptBuilder.mentions($0, "{{\(name)}}") }
        }
        for name in params.keys.sorted() where !used.contains(name) {
            warnings.append("The param \"\(name)\" didn't appear in any step, so it was left out.")
        }
        if skipped > 0 {
            warnings.append("Left out \(skipped) coordinate call\(skipped == 1 ? "" : "s") (click, drag or scroll): "
                + "scripts find elements instead. Redo those with clickrelay_press on a ref and save again, "
                + "or add the steps by hand.")
        }
        let declared = used.sorted().map { name in
            ScriptParam(name: name, description: nil, defaultValue: params[name])
        }
        let script = Script(name: name, description: description, app: app, window: nil,
                            params: declared, steps: steps)
        return (script, warnings)
    }

    private static func mentions(_ step: ScriptStep, _ token: String) -> Bool {
        let data = (try? JSONSerialization.data(withJSONObject: step.jsonObject)) ?? Data()
        return String(decoding: data, as: UTF8.self).contains(token)
    }
}

extension ElementTarget {
    /// Roles whose value changes as the user works, so it can't identify them.
    static let changingValueRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXSlider", "AXCheckBox",
        "AXRadioButton", "AXSwitch", "AXToggle", "AXPopUpButton", "AXIncrementor", "AXDateField",
        "AXStepper", "AXColorWell", "AXScrollBar", "AXValueIndicator", "AXProgressIndicator"
    ]

    /// A description that should find this element again on a later run.
    /// Recorded elements come from window trees, so the scope is windows even
    /// for menu items (an open pop-up's menu sits under its button).
    static func describing(_ node: AXNode) -> ElementTarget {
        var target = ElementTarget(role: node.role)
        // AppKit makes up "_NS:123" identifiers that change between builds.
        if let identifier = node.identifier, !identifier.isEmpty, !identifier.hasPrefix("_NS:") {
            target.identifier = identifier
        }
        if let title = node.title, !title.isEmpty {
            target.title = title
        } else if let label = node.label, !label.isEmpty {
            target.label = label
        }
        if target.title == nil, target.label == nil, target.identifier == nil,
           !changingValueRoles.contains(node.role), let value = node.value, !value.isEmpty {
            target.value = value
        }
        target.scope = .windows
        return target
    }
}
