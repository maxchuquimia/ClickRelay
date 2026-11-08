import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Where keystrokes go.
nonisolated enum InputDelivery: String, Codable, CaseIterable, Identifiable, Sendable {
    /// `CGEvent.postToPid`: only that process receives it, even if focus
    /// changes mid-call.
    case targeted
    /// Posted system-wide, relying on the frontmost check made just before
    /// each event. For apps that ignore targeted events.
    case global

    var id: String { rawValue }
    var label: String { self == .targeted ? "Targeted" : "Global" }

    /// Apps known to ignore targeted keyboard events. Starts empty; fill it in
    /// from testing.
    static let builtInGlobal: Set<String> = []
}

nonisolated enum MouseButton: String, Sendable {
    case left, right, middle

    var cgButton: CGMouseButton {
        switch self {
        case .left: .left
        case .right: .right
        case .middle: .center
        }
    }

    var downType: CGEventType {
        switch self {
        case .left: .leftMouseDown
        case .right: .rightMouseDown
        case .middle: .otherMouseDown
        }
    }

    var upType: CGEventType {
        switch self {
        case .left: .leftMouseUp
        case .right: .rightMouseUp
        case .middle: .otherMouseUp
        }
    }

    var dragType: CGEventType {
        switch self {
        case .left: .leftMouseDragged
        case .right: .rightMouseDragged
        case .middle: .otherMouseDragged
        }
    }
}

/// Posts synthetic input with `CGEvent`. Knows nothing about policy: callers
/// run `InputGuard` immediately before each event. Tracks what it holds down
/// so `releaseAll` can let go when a lease ends mid-sequence.
///
/// Events come from a private event source, so they don't pick up the user's
/// own held modifiers, and they never carry the HID system state that the
/// Authorize button looks for.
@MainActor
final class InputPoster {
    private let source = CGEventSource(stateID: .privateState)
    private var heldButtons: [MouseButton: CGPoint] = [:]
    private var heldKeys: [CGKeyCode: InputTarget] = [:]

    enum InputTarget: Equatable {
        case process(pid_t)
        case system
    }

    // MARK: Mouse

    func moveMouse(to point: CGPoint) {
        post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                     mouseCursorPosition: point, mouseButton: .left), to: .system)
    }

    func mouseDown(_ button: MouseButton, at point: CGPoint, clickCount: Int, flags: CGEventFlags) {
        let event = CGEvent(mouseEventSource: source, mouseType: button.downType,
                            mouseCursorPosition: point, mouseButton: button.cgButton)
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        event?.flags = flags
        heldButtons[button] = point
        post(event, to: .system)
    }

    func mouseUp(_ button: MouseButton, at point: CGPoint, clickCount: Int, flags: CGEventFlags) {
        let event = CGEvent(mouseEventSource: source, mouseType: button.upType,
                            mouseCursorPosition: point, mouseButton: button.cgButton)
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        event?.flags = flags
        heldButtons[button] = nil
        post(event, to: .system)
    }

    func mouseDragged(_ button: MouseButton, to point: CGPoint) {
        let event = CGEvent(mouseEventSource: source, mouseType: button.dragType,
                            mouseCursorPosition: point, mouseButton: button.cgButton)
        heldButtons[button] = point
        post(event, to: .system)
    }

    /// Scroll events go to the window under the cursor, so the cursor is moved
    /// there first. Positive `dy` scrolls down, positive `dx` right.
    func scroll(dx: Int, dy: Int, at point: CGPoint) {
        moveMouse(to: point)
        let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
                            wheel1: Int32(clamping: -dy), wheel2: Int32(clamping: -dx), wheel3: 0)
        event?.location = point
        post(event, to: .system)
    }

    // MARK: Keyboard

    func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags, target: InputTarget) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        event?.flags = flags
        if down { heldKeys[code] = target } else { heldKeys[code] = nil }
        post(event, to: target)
    }

    /// Presses and releases a key, holding modifier keys around it. Modifier
    /// key events are sent as well as the flags, since some apps track the
    /// modifier keys themselves.
    func press(_ code: CGKeyCode, modifiers: Set<Modifier>, target: InputTarget) {
        let flags = Modifier.flags(modifiers)
        let ordered = [Modifier.ctrl, .option, .shift, .cmd].filter(modifiers.contains)
        var held = CGEventFlags()
        for modifier in ordered {
            guard let modifierCode = Self.keyCode(forModifier: modifier) else { continue }
            held.insert(modifier.eventFlag)
            key(modifierCode, down: true, flags: held, target: target)
        }
        key(code, down: true, flags: flags, target: target)
        key(code, down: false, flags: flags, target: target)
        for modifier in ordered.reversed() {
            guard let modifierCode = Self.keyCode(forModifier: modifier) else { continue }
            held.remove(modifier.eventFlag)
            key(modifierCode, down: false, flags: held, target: target)
        }
    }

    /// Types one character (a grapheme) as a Unicode keyboard event. Return
    /// and Tab are sent as real keys, which more apps understand.
    func type(_ character: Character, target: InputTarget) {
        if character == "\n" || character == "\r" || character == "\r\n" {
            press(CGKeyCode(kVK_Return), modifiers: [], target: target)
            return
        }
        if character == "\t" {
            press(CGKeyCode(kVK_Tab), modifiers: [], target: target)
            return
        }
        let units = Array(String(character).utf16)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
            event?.flags = []
            units.withUnsafeBufferPointer { buffer in
                event?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            post(event, to: target)
        }
    }

    // MARK: Releasing

    /// Lets go of every button and key still down. Called when a sequence
    /// fails partway and whenever a lease ends.
    func releaseAll() {
        for (button, point) in heldButtons {
            let event = CGEvent(mouseEventSource: source, mouseType: button.upType,
                                mouseCursorPosition: point, mouseButton: button.cgButton)
            post(event, to: .system)
        }
        heldButtons = [:]
        for (code, target) in heldKeys {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
            post(event, to: target)
        }
        heldKeys = [:]
    }

    var isHoldingAnything: Bool { !heldButtons.isEmpty || !heldKeys.isEmpty }

    // MARK: Posting

    private func post(_ event: CGEvent?, to target: InputTarget) {
        guard let event else { return }
        switch target {
        case .process(let pid): event.postToPid(pid)
        case .system: event.post(tap: .cghidEventTap)
        }
    }

    static func keyCode(forModifier modifier: Modifier) -> CGKeyCode? {
        switch modifier {
        case .cmd: CGKeyCode(kVK_Command)
        case .shift: CGKeyCode(kVK_Shift)
        case .option: CGKeyCode(kVK_Option)
        case .ctrl: CGKeyCode(kVK_Control)
        case .fn: nil
        }
    }
}

/// Runs one input sequence at a time across every session, so two unlocked
/// agents can't interleave keystrokes. FIFO.
actor InputQueue {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Runs `body` with the queue held.
    nonisolated func run<T: Sendable>(_ body: @MainActor @Sendable () async -> T) async -> T {
        await acquire()
        let result = await body()
        await release()
        return result
    }
}
