import Carbon.HIToolbox
import CoreGraphics

/// Modifier keys an agent can hold.
nonisolated enum Modifier: String, CaseIterable, Sendable, Hashable {
    case cmd, shift, option, ctrl, fn

    /// Accepts the spellings models actually send.
    init?(name: String) {
        switch name.lowercased().trimmingCharacters(in: .whitespaces) {
        case "cmd", "command", "⌘", "meta", "super": self = .cmd
        case "shift", "⇧": self = .shift
        case "option", "opt", "alt", "⌥": self = .option
        case "ctrl", "control", "⌃": self = .ctrl
        case "fn", "function", "globe": self = .fn
        default: return nil
        }
    }

    var eventFlag: CGEventFlags {
        switch self {
        case .cmd: .maskCommand
        case .shift: .maskShift
        case .option: .maskAlternate
        case .ctrl: .maskControl
        case .fn: .maskSecondaryFn
        }
    }

    var symbol: String {
        switch self {
        case .cmd: "⌘"
        case .shift: "⇧"
        case .option: "⌥"
        case .ctrl: "⌃"
        case .fn: "fn"
        }
    }

    static func flags(_ modifiers: Set<Modifier>) -> CGEventFlags {
        modifiers.reduce(into: CGEventFlags()) { $0.insert($1.eventFlag) }
    }

    /// Parses a modifier list, failing on the first unknown name.
    static func parse(_ names: [String]) -> Result<Set<Modifier>, UnknownModifier> {
        var set = Set<Modifier>()
        for name in names where !name.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let modifier = Modifier(name: name) else { return .failure(UnknownModifier(name: name)) }
            set.insert(modifier)
        }
        return .success(set)
    }

    struct UnknownModifier: Error, Equatable {
        let name: String
    }
}

/// Key names to virtual key codes (ANSI positions).
nonisolated enum KeyMap {
    static let codes: [String: Int] = {
        var map: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
            "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
            "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
            "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
            "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket,
            "]": kVK_ANSI_RightBracket, "\\": kVK_ANSI_Backslash, ";": kVK_ANSI_Semicolon,
            "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
            "`": kVK_ANSI_Grave,
            "return": kVK_Return, "enter": kVK_Return, "keypad_enter": kVK_ANSI_KeypadEnter,
            "tab": kVK_Tab, "space": kVK_Space, " ": kVK_Space,
            "delete": kVK_Delete, "backspace": kVK_Delete,
            "forward_delete": kVK_ForwardDelete, "forwarddelete": kVK_ForwardDelete,
            "escape": kVK_Escape, "esc": kVK_Escape,
            "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
            "home": kVK_Home, "end": kVK_End, "page_up": kVK_PageUp, "pageup": kVK_PageUp,
            "page_down": kVK_PageDown, "pagedown": kVK_PageDown, "help": kVK_Help
        ]
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9,
                            kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17,
                            kVK_F18, kVK_F19, kVK_F20]
        for (index, code) in functionKeys.enumerated() { map["f\(index + 1)"] = code }
        return map
    }()

    /// The canonical key name, lowercased, with aliases resolved
    /// ("arrowleft" → "left").
    static func normalize(_ name: String) -> String {
        let lower = name.count == 1 ? name.lowercased()
            : name.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "-", with: "_")
        let aliases: [String: String] = [
            "arrowleft": "left", "arrow_left": "left", "leftarrow": "left",
            "arrowright": "right", "arrow_right": "right", "rightarrow": "right",
            "arrowup": "up", "arrow_up": "up", "uparrow": "up",
            "arrowdown": "down", "arrow_down": "down", "downarrow": "down",
            "spacebar": "space", "ret": "return", "newline": "return", "\n": "return", "\t": "tab",
            "del": "delete", "backspace": "delete", "esc": "escape", "enter": "return",
            "pageup": "page_up", "pagedown": "page_down", "forwarddelete": "forward_delete", "minus": "-", "equal": "=", "equals": "=", "comma": ",",
            "period": ".", "slash": "/", "backslash": "\\", "semicolon": ";", "quote": "'",
            "grave": "`", "backtick": "`", "left_bracket": "[", "right_bracket": "]"
        ]
        return aliases[lower] ?? lower
    }

    static func keyCode(for name: String) -> CGKeyCode? {
        codes[normalize(name)].map { CGKeyCode($0) }
    }

    static func displayName(forKeyCode code: UInt16) -> String? {
        let names: [Int: String] = [kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space",
                                    kVK_Delete: "⌫", kVK_Escape: "⎋", kVK_LeftArrow: "←",
                                    kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
                                    kVK_ForwardDelete: "⌦"]
        if let name = names[Int(code)] { return name }
        // Prefer the shortest name for this code ("a" over aliases).
        let match = codes.filter { $0.value == Int(code) }.map(\.key).min { $0.count < $1.count }
        return match?.uppercased()
    }
}
