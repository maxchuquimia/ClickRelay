import Foundation

/// Key combinations `clickrelay_key` refuses, because each could move focus
/// (or the keyboard) outside the allowed apps, or end the user's session.
/// Text typed with `clickrelay_type` carries no modifiers, so only `key` needs
/// this.
nonisolated enum ShortcutPolicy {
    /// Why `key` with `modifiers` is refused, written for the model, or nil
    /// if it's fine.
    ///
    /// - Parameter frontmostAllowed: whether the app that would receive it is
    ///   allowed. ⌘Q is fine for an allowed app and refused for any other.
    static func refusal(key rawKey: String, modifiers: Set<Modifier>,
                        frontmostAllowed: Bool = true) -> String? {
        let key = KeyMap.normalize(rawKey)
        let name = describe(key: key, modifiers: modifiers)
        func refuse(_ why: String) -> String {
            "\(name) is blocked: \(why). Use clickrelay_focus_window to change apps instead."
        }

        if modifiers.contains(.fn) {
            return refuse("Fn and Globe shortcuts can open system features outside the allowed apps")
        }
        let cmd = modifiers.contains(.cmd)
        let ctrl = modifiers.contains(.ctrl)
        let option = modifiers.contains(.option)
        let shift = modifiers.contains(.shift)

        if cmd && key == "tab" { return refuse("it switches to another app") }
        if cmd && key == "space" { return refuse("it opens Spotlight or another system panel") }
        if ctrl && ["left", "right", "up", "down"].contains(key) {
            return refuse("it switches Spaces or opens Mission Control")
        }
        if cmd && option && key == "escape" { return refuse("it opens Force Quit") }
        if cmd && shift && key == "q" { return refuse("it logs the user out") }
        if cmd && ctrl && key == "q" { return refuse("it locks the screen") }
        if cmd && key == "q" && !frontmostAllowed {
            return refuse("it would quit an app that isn't allowed")
        }
        if ctrl, let number = functionKeyNumber(key), (1...8).contains(number) {
            return refuse("it moves keyboard focus to the menu bar, Dock or another app's window")
        }
        if cmd, functionKeyNumber(key) == 5 {
            return refuse("it turns on VoiceOver or opens accessibility shortcuts")
        }
        return nil
    }

    static func functionKeyNumber(_ key: String) -> Int? {
        guard key.hasPrefix("f"), key.count > 1 else { return nil }
        return Int(key.dropFirst())
    }

    /// "⌘⇧Q", as the refusal names it.
    static func describe(key: String, modifiers: Set<Modifier>) -> String {
        let order: [Modifier] = [.fn, .ctrl, .option, .shift, .cmd]
        let prefix = order.filter(modifiers.contains).map(\.symbol).joined()
        let keyName: String
        switch key {
        case "space": keyName = "Space"
        case "tab": keyName = "Tab"
        case "escape": keyName = "Esc"
        case "left": keyName = "←"
        case "right": keyName = "→"
        case "up": keyName = "↑"
        case "down": keyName = "↓"
        default: keyName = key.count == 1 ? key.uppercased() : key.capitalized
        }
        return prefix + keyName
    }
}
