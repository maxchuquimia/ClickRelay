import Foundation

/// The tool names, in the order `tools/list` reports them.
nonisolated enum ToolName: String, CaseIterable, Sendable {
    case status = "clickrelay_status"
    case listWindows = "clickrelay_list_windows"
    case screenshot = "clickrelay_screenshot"
    case getUITree = "clickrelay_get_ui_tree"
    case findElements = "clickrelay_find_elements"
    case press = "clickrelay_press"
    case setValue = "clickrelay_set_value"
    case click = "clickrelay_click"
    case drag = "clickrelay_drag"
    case scroll = "clickrelay_scroll"
    case type = "clickrelay_type"
    case key = "clickrelay_key"
    case focusWindow = "clickrelay_focus_window"
    case launchApp = "clickrelay_launch_app"
    case requestAccess = "clickrelay_request_access"
    case notify = "clickrelay_notify"
    case handOff = "clickrelay_hand_off"
    case runScript = "clickrelay_run_script"
    case saveScript = "clickrelay_save_script"
    case validateScript = "clickrelay_validate_script"

    /// Tools that post input or act on another app. These run one at a time
    /// across every session (`InputQueue`).
    var isInput: Bool {
        switch self {
        case .press, .setValue, .click, .drag, .scroll, .type, .key, .focusWindow, .launchApp:
            return true
        case .status, .listWindows, .screenshot, .getUITree, .findElements, .requestAccess, .notify, .handOff:
            return false
        case .runScript, .saveScript, .validateScript:
            // A script holds the input queue for its whole run (ToolRouter.runScript);
            // saving one only reads what the session did.
            return false
        }
    }

    /// Tools that work without a lease. None of them sees or touches another
    /// app: they read ClickRelay's state or put something in front of the user.
    var worksWhileLocked: Bool {
        self == .status || self == .requestAccess || self == .notify || self == .validateScript
    }
}

/// Tool definitions and the `initialize` result. Used by both the bridge (to
/// answer `tools/list` without the app) and the app (to dispatch), so the two
/// can't disagree.
///
/// No ScreenCaptureKit, Accessibility or `CGEvent` here: the bridge links this.
nonisolated enum MCPTools {
    static let protocolVersion = "2024-11-05"

    static func initializeResult() -> [String: Any] {
        [
            "protocolVersion": protocolVersion,
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "ClickRelay", "version": "1.0.0"],
            "instructions": serverInstructions
        ]
    }

    static let serverInstructions = """
        ClickRelay lets you see and control other apps on the user's Mac, but only while \
        the user has unlocked it for you (Touch ID or a button in ClickRelay) and only in \
        the apps they allowed. Access ends by itself after the time they picked.

        Start with clickrelay_status. If it's locked, or an app you need isn't allowed, \
        call clickrelay_request_access with the apps you need and a short reason. That \
        alerts the user and waits for their answer. You can't unlock, extend or widen \
        access yourself, so don't try to work around a refusal: read what it says and do \
        that, or ask.

        Keep working while you have access, even if only a little time is left. Don't stop \
        early or wait for the user to add time. If access runs out partway, call \
        clickrelay_request_access to ask again, then carry on.

        Before clicking, typing or pressing keys, bring the window to the front with \
        clickrelay_focus_window. clickrelay_list_windows shows which one is frontmost. \
        Clicks on a window that's behind another are refused, and keys always go to the \
        frontmost app.

        Prefer Accessibility over coordinates: clickrelay_get_ui_tree or \
        clickrelay_find_elements, then clickrelay_press or clickrelay_set_value with the \
        element's ref. Use clickrelay_click, clickrelay_drag and clickrelay_scroll when \
        there's no usable element, with a window_id from clickrelay_list_windows or \
        clickrelay_screenshot. Menu bar commands aren't in any window: find them with \
        clickrelay_find_elements, in "menus" with the app's bundle_id, and press the item \
        itself. ClickRelay never opens menus.

        For UI work you'll repeat, do it once by ref, save it with clickrelay_save_script, \
        and next time run it with clickrelay_run_script: one call instead of many.

        When you hit something you can't or shouldn't do yourself, like a password, a \
        CAPTCHA, a 2FA code or approving a payment, call clickrelay_hand_off with the \
        window and what you need. The user does it and you carry on. Never ask for a \
        password in chat.

        When you finish, or stop because you need the user, call clickrelay_notify. While \
        you work the user usually keeps their hands off the Mac, so this is how they know \
        they can have it back.
        """

    private static let rules = " Needs an unlocked ClickRelay and works only on apps the user allowed."

    private static func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return schema
    }

    private static func prop(_ type: String, _ description: String) -> [String: Any] {
        ["type": type, "description": description]
    }

    private static var windowID: [String: Any] {
        prop("integer", "A window_id from clickrelay_list_windows or clickrelay_screenshot.")
    }
    private static var point: [String: Any] {
        object([
            "x": prop("number", "Horizontal position."),
            "y": prop("number", "Vertical position.")
        ], required: ["x", "y"])
    }
    private static var space: [String: Any] {
        [
            "type": "string", "enum": ["points", "pixels"],
            "description": "points (default): window points from the window's top-left. pixels: pixels in your most recent clickrelay_screenshot that showed this window."
        ]
    }
    private static var modifiers: [String: Any] {
        [
            "type": "array",
            "items": ["type": "string", "enum": ["cmd", "shift", "option", "ctrl", "fn"]],
            "description": "Modifier keys to hold."
        ]
    }

    static var toolDefinitions: [[String: Any]] {
        ToolName.allCases.map { definition(for: $0) }
    }

    static func definition(for tool: ToolName) -> [String: Any] {
        let (description, schema): (String, [String: Any])
        switch tool {
        case .status:
            description = "Whether ClickRelay is unlocked for you, seconds left, the apps you may use (name and bundle ID), and whether keyboard input is allowed right now (the frontmost app must be an allowed one). Always works, even when locked."
            schema = object([:])
        case .listWindows:
            description = "On-screen windows of the allowed apps: window_id, app, title, frame in points (top-left origin, global screen coordinates) and whether it's frontmost." + rules
            schema = object(["bundle_id": prop("string", "Only list this app's windows.")])
        case .screenshot:
            description = "A screenshot of one allowed window, or of all allowed apps on the main display (everything else is left out of the image). Returns the image plus window_id, scale and origin so image pixels map back to points: point = origin + pixel / scale." + rules
            schema = object([
                "window_id": prop("integer", "Capture just this window. Omit for the main display, showing only allowed apps."),
                "format": ["type": "string", "enum": ["png", "jpeg"], "description": "Image format. Default png."],
                "max_edge": prop("integer", "Longest edge in pixels. Default 1568.")
            ])
        case .getUITree:
            description = "The window's Accessibility tree, flattened: ref (e.g. e42), role, title or label, value, frame relative to the window, enabled. Refs stay valid until your next clickrelay_get_ui_tree on this window, or until access ends." + rules
            schema = object([
                "window_id": windowID,
                "max_depth": prop("integer", "How deep to walk. Default 6."),
                "filter": ["type": "string", "enum": ["interactive", "all"],
                           "description": "interactive (default): only elements you can act on. all: every element."]
            ], required: ["window_id"])
        case .findElements:
            description = "Elements in a window whose title, label, value or identifier contains the query (case-insensitive), with refs, in the same shape as clickrelay_get_ui_tree. "
                + "For menu commands (Product > Archive, File > Export…), pass in \"menus\" and bundle_id instead of window_id: it searches the app's menu bar and returns refs to press with clickrelay_press, with the menus closed. ClickRelay never opens a menu, so press the item itself, not the menu it's in." + rules
            schema = object([
                "window_id": windowID,
                "query": prop("string", "Text to look for."),
                "role": prop("string", "Only this Accessibility role, e.g. AXButton."),
                "in": ["type": "string", "enum": ["windows", "menus"],
                       "description": "windows (default): the window_id's elements. menus: the menu bar of the app in bundle_id."],
                "bundle_id": prop("string", "With in \"menus\": the app whose menus to search.")
            ], required: ["query"])
        case .press:
            description = "Performs an Accessibility action on an element by ref. No coordinates, so it can't land in the wrong place. Use action \"focus\" to focus a text field before typing." + rules
            schema = object([
                "ref": prop("string", "An element ref, e.g. e42."),
                "action": prop("string", "AXPress (default), another action the element lists, or focus.")
            ], required: ["ref"])
        case .setValue:
            description = "Sets an element's value directly (text fields, sliders), if it's settable." + rules
            schema = object([
                "ref": prop("string", "An element ref, e.g. e42."),
                "value": prop("string", "The new value. Numbers are converted for numeric elements.")
            ], required: ["ref", "value"])
        case .click:
            description = "Clicks at a point in a window. Call clickrelay_focus_window first unless the window is already frontmost: a click is refused if the point is outside the window or covered by another app's window." + rules
            schema = object([
                "window_id": windowID,
                "x": prop("number", "Horizontal position in the window."),
                "y": prop("number", "Vertical position in the window."),
                "space": space,
                "button": ["type": "string", "enum": ["left", "right", "middle"], "description": "Default left."],
                "count": prop("integer", "1 to 3 for single, double or triple click. Default 1."),
                "modifiers": modifiers
            ], required: ["window_id", "x", "y"])
        case .drag:
            description = "Drags with the left button from one point to another in a window. Bring the window to the front with clickrelay_focus_window first. Every step is checked, and the drag stops (releasing the button) at the first point that fails." + rules
            schema = object([
                "window_id": windowID,
                "from": point,
                "to": point,
                "space": space,
                "duration_ms": prop("integer", "How long the drag takes. Default 300.")
            ], required: ["window_id", "from", "to"])
        case .scroll:
            description = "Scrolls at a point in a window, by lines. Positive dy scrolls down, positive dx scrolls right." + rules
            schema = object([
                "window_id": windowID,
                "x": prop("number", "Horizontal position in the window."),
                "y": prop("number", "Vertical position in the window."),
                "space": space,
                "dx": prop("integer", "Lines to scroll horizontally."),
                "dy": prop("integer", "Lines to scroll vertically.")
            ], required: ["window_id", "x", "y"])
        case .type:
            description = "Types text into the focused element of the frontmost app, which must be allowed. Call clickrelay_focus_window first unless that window is already frontmost." + rules
            schema = object([
                "text": prop("string", "The text to type."),
                "delay_ms": prop("integer", "Pause between characters in milliseconds. Default 10. Raise it if an app drops characters.")
            ], required: ["text"])
        case .key:
            description = "Presses one key, optionally with modifiers, in the frontmost (allowed) app. Shortcuts that could move focus out of the allowed apps, like cmd+tab or cmd+space, are refused." + rules
            schema = object([
                "key": prop("string", "Key name: a letter or digit, return, tab, space, delete, forward_delete, escape, left, right, up, down, home, end, page_up, page_down, f1 to f20, or punctuation like - = [ ] ; ' , . / ` \\"),
                "modifiers": modifiers
            ], required: ["key"])
        case .focusWindow:
            description = "Brings an allowed window to the front and makes its app frontmost, so keyboard input can go to it." + rules
            schema = object(["window_id": windowID], required: ["window_id"])
        case .launchApp:
            description = "Opens an allowed app by bundle ID. Only apps the user allowed can be opened." + rules
            schema = object(["bundle_id": prop("string", "The app's bundle ID, e.g. com.apple.iphonesimulator.")],
                            required: ["bundle_id"])
        case .requestAccess:
            description = "Asks the user to unlock ClickRelay for you, allow more apps, or give you more time. It shows an alert next to your session in ClickRelay and under its menu bar icon, bounces the Dock icon, and waits for the user. Use it when you're locked, when an app you need isn't allowed, or when access ran out mid-task. Asking grants nothing by itself: the user picks what to allow. Returns your access once they answer, or says they haven't yet. Works while locked."
            schema = object([
                "apps": [
                    "type": "array", "items": ["type": "string"],
                    "description": "Apps you need, by bundle ID (com.apple.Safari) or name (Safari)."
                ],
                "reason": prop("string", "One short sentence for the user on what you want to do, e.g. \"Check the sign-up email arrived in Mail.\""),
                "wait_seconds": prop("integer", "How long to wait for an answer, up to 300. Default 120. The alert stays up after that until the user answers.")
            ])
        case .notify:
            description = "Tells the user you've finished, or stopped and need them. Shows an alert in ClickRelay and under its menu bar icon, which they see even if the app you were driving fills the screen. Call it when you're done using their Mac. Works while locked."
            schema = object([
                "message": prop("string", "One or two short sentences, e.g. \"Finished testing sign-up. All three flows pass.\""),
                "status": ["type": "string", "enum": ["done", "needs_you"],
                           "description": "done (default): you've finished. needs_you: you stopped and need the user to do or decide something."],
                "release_access": prop("boolean", "Lock your own access now, since you're done with it. Default false.")
            ], required: ["message"])
        case .handOff:
            description = "Hands a window to the user for something you can't or shouldn't do: entering a password, solving a CAPTCHA, typing a 2FA code, approving a payment. ClickRelay points at the window (or the element, with ref), shows your message, and waits until the user says they're done. Meanwhile every agent's input is paused, and you can't capture or read that app, so you never see what they type. Returns when they answer: done (with an optional note), or that they couldn't." + rules
            schema = object([
                "window_id": windowID,
                "ref": prop("string", "An element ref (e.g. e42) in that window to point at, like the password field."),
                "message": prop("string", "One or two short sentences for the user on what to do, e.g. \"Please enter your GitHub password and press Sign in.\""),
                "wait_seconds": prop("integer", "How long to wait for the user, up to 300. Default 300. The hand-off stays open after that until they answer.")
            ], required: ["window_id", "message"])
        case .runScript:
            description = "Runs a script of Accessibility steps in one call and returns a short summary, so repeated UI work needs no screenshots or trees. Keep scripts as JSON files in your project. Every step gets the same checks as a single call, and the run stops at the first step that fails, saying which and why. "
                + "Format: {\"name\", \"app\": bundle ID, \"window\"?: text in the window title, \"params\"?: {name: description}, \"steps\": [...]}. "
                + "Each step has one action: press, focus, set_value (with \"value\") or wait_for, each given an element; type: text; key: e.g. \"cmd+s\"; focus_window: true; launch_app: true; wait: seconds. "
                + "An element is {role?, title?, label?, identifier?, value?, hint?, enabled?, in?: \"windows\" or \"menus\"}, or just a title string. Every field given must match; menu roles (menu_bar_item, menu_item) are looked for in the menu bar. "
                + "For a menu command, press the menu_item itself (by title or identifier) with the menu closed; don't press the menu_bar_item first, since ClickRelay never opens menus and skips that step. "
                + "Any step can also have app, window, timeout_s (seconds to wait for its element or window; default 3, wait_for 10, at most 120, or 900 for wait_for) and optional: true (skip it if the element isn't there). Write {{name}} anywhere to use a param. "
                + "wait_for passes at once if the element is already on screen, so wait for something that only appears when the work is done, not something an earlier run left open. ClickRelay pauses briefly after each input step and closes any menu left open when the run ends. "
                + "If several elements match equally, the on-device model (when the Mac has it) picks one, and the summary says so. When nothing matches, it only guesses for an element with a hint, and never on an optional or wait_for step. To make a script, do the task once by ref, then call clickrelay_save_script." + rules
            schema = object([
                "path": prop("string", "The script file, relative to your working directory (or absolute)."),
                "params": prop("object", "Values for the script's params, by name."),
                "script": prop("object", "The script itself, instead of a path.")
            ])
        case .validateScript:
            description = "Checks a script without running it: whether it parses, what each step will do, how long each waits, which params it needs, and warnings such as keys ClickRelay ignores (a typo like \"titel\") or apps that aren't installed. Doesn't find elements on screen. Works while ClickRelay is locked and needs no unlock."
            schema = object([
                "path": prop("string", "The script file, relative to your working directory (or absolute)."),
                "params": prop("object", "Values to check with. Params left out are reported, not an error."),
                "script": prop("object", "The script itself, instead of a path.")
            ])
        case .saveScript:
            description = "Saves the input calls you made since your last save (or since you connected) as a script file for clickrelay_run_script. Calls by ref (press, set_value) become element descriptions; type, key, focus_window and launch_app are kept; coordinate calls (click, drag, scroll) are left out. Says which steps may not replay well." + rules
            schema = object([
                "path": prop("string", "Where to write the script (a .json file), relative to your working directory."),
                "name": prop("string", "The script's name."),
                "description": prop("string", "What the script does, for whoever runs it next."),
                "last": prop("integer", "Only save your last N calls."),
                "params": prop("object", "Text to turn into params: param name → the text you used, e.g. {\"scheme\": \"Release\"}. That text becomes {{scheme}} in the script, with it as the default."),
                "overwrite": prop("boolean", "Replace the file if it exists. Default false.")
            ], required: ["path", "name"])
        }
        return ["name": tool.rawValue, "description": description, "inputSchema": schema]
    }
}

/// A tool call's arguments, read leniently: models send numbers as strings,
/// integers as doubles, and camelCase names for snake_case ones.
nonisolated struct ToolArguments: @unchecked Sendable {
    let raw: [String: Any]

    init(_ raw: [String: Any]) { self.raw = raw }

    func value(_ name: String) -> Any? {
        if let exact = raw[name], !(exact is NSNull) { return exact }
        // window_id ↔ windowId
        let camel = name.split(separator: "_").enumerated()
            .map { $0.offset == 0 ? String($0.element) : $0.element.prefix(1).uppercased() + $0.element.dropFirst() }
            .joined()
        if let other = raw[camel], !(other is NSNull) { return other }
        return nil
    }

    func string(_ name: String) -> String? {
        switch value(name) {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    func double(_ name: String) -> Double? {
        switch value(name) {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    func int(_ name: String) -> Int? {
        guard let d = double(name), d.isFinite, d.rounded() == d,
              d >= Double(Int.min), d <= Double(Int.max) else { return nil }
        return Int(d)
    }

    func bool(_ name: String) -> Bool? {
        switch value(name) {
        case let n as NSNumber: return n.boolValue
        case let s as String: return ["true", "yes", "1"].contains(s.lowercased())
        default: return nil
        }
    }

    func strings(_ name: String) -> [String]? {
        switch value(name) {
        case let list as [Any]: return list.compactMap { $0 as? String }
        case let s as String:
            // A JSON array sent as a string, or a comma/plus separated list.
            if let data = s.data(using: .utf8),
               let list = try? JSONSerialization.jsonObject(with: data) as? [String] { return list }
            return s.split(whereSeparator: { $0 == "," || $0 == "+" || $0 == " " }).map(String.init)
        default: return nil
        }
    }

    /// A nested `{x, y}` object (or one sent as a JSON string).
    func point(_ name: String) -> (x: Double, y: Double)? {
        var object = value(name) as? [String: Any]
        if object == nil, let s = value(name) as? String, let data = s.data(using: .utf8) {
            object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        guard let object else { return nil }
        let args = ToolArguments(object)
        guard let x = args.double("x"), let y = args.double("y") else { return nil }
        return (x, y)
    }
}
