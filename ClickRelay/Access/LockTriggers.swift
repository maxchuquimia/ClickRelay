import AppKit
import Carbon.HIToolbox

/// Watches for the system events that end every lease at once: screen lock,
/// screensaver, sleep and switching user. Not settings; always on.
/// Also reports app quits, for the "every allowed app quit" lock.
@MainActor
final class LockTriggerMonitor {
    private let onTrigger: (LockReason) -> Void
    private let onAppTerminated: (String?) -> Void
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    init(onTrigger: @escaping (LockReason) -> Void, onAppTerminated: @escaping (String?) -> Void) {
        self.onTrigger = onTrigger
        self.onAppTerminated = onAppTerminated
    }

    func start() {
        guard tokens.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, "com.apple.screenIsLocked", .screenLocked)
        observe(distributed, "com.apple.screensaver.didstart", .screensaver)

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification.rawValue, .sleep)
        observe(workspace, NSWorkspace.screensDidSleepNotification.rawValue, .sleep)
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification.rawValue, .sessionResigned)

        let token = workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                          object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            MainActor.assumeIsolated { self?.onAppTerminated(bundleID) }
        }
        tokens.append((workspace, token))
    }

    func stop() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens = []
    }

    private func observe(_ center: NotificationCenter, _ name: String, _ reason: LockReason) {
        let token = center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.onTrigger(reason) }
        }
        tokens.append((center, token))
    }
}

/// A key and modifiers, as stored for the kill shortcut.
nonisolated struct KeyCombo: Codable, Equatable, Sendable {
    var keyCode: UInt16
    /// `NSEvent.ModifierFlags` raw value, device-independent bits only.
    var modifiers: UInt

    /// ⌃⌥⌘L.
    static let defaultKill = KeyCombo(
        keyCode: UInt16(kVK_ANSI_L),
        modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue)

    var flags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers).intersection([.control, .option, .shift, .command])
    }

    var carbonModifiers: UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    func matches(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        keyCode == self.keyCode
            && flags.intersection([.control, .option, .shift, .command]) == self.flags
    }

    var display: String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + (KeyMap.displayName(forKeyCode: keyCode) ?? "Key \(keyCode)")
    }
}

/// The global kill shortcut. A Carbon hot key, which works while any app is
/// focused, backed by a global key monitor (the app has Accessibility). Either
/// firing ends every lease; ending twice is harmless.
@MainActor
final class KillShortcut {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var combo: KeyCombo?

    /// Read by the Carbon callback, which can't capture context.
    nonisolated(unsafe) private static var action: (() -> Void)?

    func register(_ combo: KeyCombo, action: @escaping () -> Void) {
        unregister()
        self.combo = combo
        Self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { KillShortcut.action?() }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x434C524C) /* CLRL */, id: 1)
        RegisterEventHotKey(UInt32(combo.keyCode), combo.carbonModifiers, id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)

        let keyCode = combo.keyCode
        let flags = combo.flags
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            let matches = event.keyCode == keyCode
                && event.modifierFlags.intersection([.control, .option, .shift, .command]) == flags
            if matches { DispatchQueue.main.async { KillShortcut.action?() } }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let matches = event.keyCode == keyCode
                && event.modifierFlags.intersection([.control, .option, .shift, .command]) == flags
            if matches {
                DispatchQueue.main.async { KillShortcut.action?() }
                return nil
            }
            return event
        }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        hotKeyRef = nil
        handlerRef = nil
        globalMonitor = nil
        localMonitor = nil
    }
}
