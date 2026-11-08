import ApplicationServices
import CoreGraphics
import Foundation

/// An `AXUIElement` carried across threads. CF objects are safe to retain and
/// release anywhere, and the AX API may be called from any thread.
nonisolated struct AXElement: @unchecked Sendable {
    let element: AXUIElement

    var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }
}

/// One element in a flattened tree, as the agent sees it.
nonisolated struct AXNode: Sendable {
    let element: AXElement
    let role: String
    let subrole: String?
    let title: String?
    let label: String?
    let value: String?
    let identifier: String?
    /// Relative to the window's top-left, in points.
    let frame: CGRect?
    let enabled: Bool
    let focused: Bool
    let actions: [String]
    let depth: Int

    func json(ref: String) -> [String: Any] {
        var object: [String: Any] = ["ref": ref, "role": role, "enabled": enabled]
        if let subrole { object["subrole"] = subrole }
        if let title, !title.isEmpty { object["title"] = title }
        if let label, !label.isEmpty, label != title { object["label"] = label }
        if let value, !value.isEmpty { object["value"] = value }
        if let identifier, !identifier.isEmpty { object["identifier"] = identifier }
        if let frame {
            object["frame"] = [Int(frame.minX.rounded()), Int(frame.minY.rounded()),
                               Int(frame.width.rounded()), Int(frame.height.rounded())]
        }
        if focused { object["focused"] = true }
        let extra = actions.filter { !["AXPress", "AXShowMenu", "AXScrollToVisible", "AXShowDefaultUI",
                                       "AXShowAlternateUI"].contains($0) }
        if !extra.isEmpty { object["actions"] = extra }
        if depth > 0 { object["depth"] = depth }
        return object
    }

    /// Whether `query` appears in its title, label, value or identifier.
    func matches(_ query: String) -> Bool {
        let needle = query.lowercased()
        return [title, label, value, identifier].contains { $0?.lowercased().contains(needle) == true }
    }
}

/// Read-only Accessibility queries. Called off the main actor, since a slow
/// app can take a second or more to answer and ClickRelay's own window (with
/// Lock now) must stay responsive.
nonisolated enum AXQuery {
    static let interactiveRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea", "AXSearchField",
        "AXComboBox", "AXPopUpButton", "AXMenuButton", "AXSlider", "AXIncrementor", "AXLink",
        "AXMenuItem", "AXMenuBarItem", "AXTab", "AXTabButton", "AXDisclosureTriangle", "AXSwitch",
        "AXToggle", "AXColorWell", "AXDateField", "AXStepper", "AXSegment", "AXCell", "AXRow"
    ]

    /// Actions that make an element worth listing as interactive.
    static let interactiveActions: Set<String> = [
        "AXPress", "AXConfirm", "AXPick", "AXIncrement", "AXDecrement", "AXOpen"
    ]

    /// Most nodes walked in one call, so a huge web page can't produce a
    /// result the agent can't afford to read.
    static let nodeLimit = 1500

    /// Sets how long ClickRelay waits for any app to answer an AX request.
    static func configureTimeout(seconds: Float = 2) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }

    /// The owning process of the element at a global point, or nil if
    /// Accessibility couldn't say.
    static func elementPID(at point: CGPoint) -> pid_t? {
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),
                                                      Float(point.x), Float(point.y), &element)
        guard result == .success, let element else { return nil }
        return AXElement(element: element).pid
    }

    /// The AX window for a window-server window: by its window number where
    /// the system says, otherwise by matching frame and title.
    static func windowElement(pid: pid_t, windowID: CGWindowID, frame: CGRect, title: String) -> AXElement? {
        let app = AXUIElementCreateApplication(pid)
        guard let windows = copy(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        if let getWindow = windowNumberFunction {
            for window in windows {
                var number: CGWindowID = 0
                if getWindow(window, &number) == .success, number == windowID {
                    return AXElement(element: window)
                }
            }
        }
        let candidates = windows.filter { window in
            guard let windowFrame = Self.frame(of: window) else { return false }
            return abs(windowFrame.minX - frame.minX) < 2 && abs(windowFrame.minY - frame.minY) < 2
                && abs(windowFrame.width - frame.width) < 2 && abs(windowFrame.height - frame.height) < 2
        }
        if candidates.count > 1, let titled = candidates.first(where: { string($0, kAXTitleAttribute) == title }) {
            return AXElement(element: titled)
        }
        return candidates.first.map(AXElement.init)
    }

    /// Walks the tree under `root` depth-first, in reading order.
    static func walk(root: AXElement, windowOrigin: CGPoint, maxDepth: Int,
                     interactiveOnly: Bool, limit: Int = nodeLimit) -> [AXNode] {
        var nodes: [AXNode] = []
        var visited = 0
        func visit(_ element: AXUIElement, depth: Int) {
            guard visited < limit else { return }
            visited += 1
            let node = describe(element, windowOrigin: windowOrigin, depth: depth)
            if !interactiveOnly || isInteractive(node) { nodes.append(node) }
            guard depth < maxDepth else { return }
            for child in children(of: element) { visit(child, depth: depth + 1) }
        }
        visit(root.element, depth: 0)
        return nodes
    }

    /// The app's menu bar, for script steps that pick menu items.
    static func menuBar(pid: pid_t) -> AXElement? {
        guard let value = copy(AXUIElementCreateApplication(pid), kAXMenuBarAttribute),
              CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
        return AXElement(element: value as! AXUIElement)
    }

    /// Whether pressing this element would only open a menu: a menu bar item,
    /// or a menu item with a submenu. Pressing those through Accessibility
    /// leaves the app in menu tracking (the menu stays open, ignores posted
    /// keys, and holds the mouse until something closes it), so scripts press
    /// the item inside instead, which works with the menu closed.
    static func opensMenu(_ node: AXNode) -> Bool {
        if node.role == "AXMenuBarItem" || node.role == "AXMenuBar" || node.role == "AXMenu" { return true }
        guard node.role == "AXMenuItem" else { return false }
        return children(of: node.element.element).contains { string($0, kAXRoleAttribute) == "AXMenu" }
    }

    /// Closes any menu open in the app's menu bar. Returns how many it closed.
    /// A menu left open keeps the app in menu tracking, where posted keys and
    /// clicks don't reach it and the Dock and hover effects stop working.
    @discardableResult
    static func closeOpenMenus(pid: pid_t) -> Int {
        guard let bar = menuBar(pid: pid) else { return 0 }
        let items = children(of: bar.element)
        let selected = items.filter { (copy($0, kAXSelectedAttribute) as? Bool) == true }
        var closed = 0
        for item in selected {
            for menu in children(of: item) where string(menu, kAXRoleAttribute) == "AXMenu" {
                if AXUIElementPerformAction(menu, kAXCancelAction as CFString) == .success { closed += 1 }
            }
        }
        return closed
    }

    static func isInteractive(_ node: AXNode) -> Bool {
        interactiveRoles.contains(node.role) || !interactiveActions.isDisjoint(with: node.actions)
    }

    static func children(of element: AXUIElement) -> [AXUIElement] {
        (copy(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func describe(_ element: AXUIElement, windowOrigin: CGPoint, depth: Int) -> AXNode {
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                     kAXValueAttribute, kAXIdentifierAttribute, kAXEnabledAttribute, kAXFocusedAttribute,
                     kAXPositionAttribute, kAXSizeAttribute, kAXPlaceholderValueAttribute]
        var raw: CFArray?
        AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &raw)
        let values = (raw as? [Any]) ?? []
        func at(_ index: Int) -> Any? {
            guard index < values.count else { return nil }
            let value = values[index]
            // Missing attributes come back as an AXValue holding an error.
            if CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID(),
               AXValueGetType(value as! AXValue) == .axError { return nil }
            return value
        }
        let role = at(0) as? String ?? "AXUnknown"
        let subrole = at(1) as? String
        let secure = role == "AXSecureTextField" || subrole == "AXSecureTextField"
        var frame: CGRect?
        if let position = at(8).flatMap(point), let size = at(9).flatMap(size) {
            frame = CGRect(x: position.x - windowOrigin.x, y: position.y - windowOrigin.y,
                           width: size.width, height: size.height)
        }
        var label = at(3) as? String
        if label?.isEmpty != false, let placeholder = at(10) as? String { label = placeholder }
        return AXNode(
            element: AXElement(element: element),
            role: role,
            subrole: subrole,
            title: at(2) as? String,
            label: label,
            value: secure ? nil : stringValue(at(4)),
            identifier: at(5) as? String,
            frame: frame,
            enabled: (at(6) as? Bool) ?? true,
            focused: (at(7) as? Bool) ?? false,
            actions: actions(of: element),
            depth: depth)
    }

    static func actions(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = copy(element, kAXPositionAttribute).flatMap(point),
              let size = copy(element, kAXSizeAttribute).flatMap(size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    // MARK: Attribute helpers

    static func copy(_ element: AXUIElement, _ attribute: String) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }

    static func stringValue(_ value: Any?) -> String? {
        let text: String?
        switch value {
        case let string as String: text = string
        case let number as NSNumber: text = number.stringValue
        case let url as URL: text = url.absoluteString
        case let attributed as NSAttributedString: text = attributed.string
        default: text = nil
        }
        guard let text else { return nil }
        return text.count > 200 ? String(text.prefix(200)) + "…" : text
    }

    static func point(_ value: Any) -> CGPoint? {
        guard CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    static func size(_ value: Any) -> CGSize? {
        guard CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    /// `_AXUIElementGetWindow`, looked up at run time: undocumented, but the
    /// only exact link from an AX window to its window-server number. Frame
    /// matching is the fallback if it's ever gone.
    private typealias GetWindowFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let windowNumberFunction: GetWindowFunction? = {
        guard let handle = dlopen(nil, RTLD_LAZY), let symbol = dlsym(handle, "_AXUIElementGetWindow") else {
            return nil
        }
        return unsafeBitCast(symbol, to: GetWindowFunction.self)
    }()
}

/// Element refs handed to agents (`e42`). Per session; a window's refs are
/// replaced by the next `get_ui_tree` on that window, and all of a session's
/// refs go when its lease ends.
@MainActor
final class ElementStore {
    struct Entry {
        let element: AXElement
        let windowID: CGWindowID
        /// The element as it was described, so a recorded script can find it again.
        let node: AXNode
    }

    /// The `windowID` of refs from an app's menu bar, which isn't a window.
    nonisolated static let menuBar: CGWindowID = 0

    private var entries: [String: [String: Entry]] = [:]   // session → ref → entry
    private var counters: [String: Int] = [:]

    /// Stores `nodes` and returns their refs, in order.
    func register(_ nodes: [AXNode], session: String, windowID: CGWindowID, replacingWindow: Bool) -> [String] {
        if replacingWindow {
            entries[session] = entries[session]?.filter { $0.value.windowID != windowID }
        }
        var refs: [String] = []
        for node in nodes {
            let next = (counters[session] ?? 0) + 1
            counters[session] = next
            let ref = "e\(next)"
            entries[session, default: [:]][ref] = Entry(element: node.element, windowID: windowID, node: node)
            refs.append(ref)
        }
        return refs
    }

    func entry(_ ref: String, session: String) -> Entry? {
        let key = ref.trimmingCharacters(in: .whitespaces).lowercased()
        return entries[session]?[key.hasPrefix("e") ? key : "e" + key]
    }

    func invalidate(session: String) {
        entries[session] = nil
        counters[session] = nil
    }

    func invalidateAll() {
        entries = [:]
        counters = [:]
    }
}
