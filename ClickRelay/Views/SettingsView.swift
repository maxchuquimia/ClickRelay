import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            ScrollView { SetupChecklist(style: .settings) }
                .tabItem { Label("Setup", systemImage: "checklist") }
            AccessSettings()
                .tabItem { Label("Access", systemImage: "lock") }
            DisplaySettings()
                .tabItem { Label("Display", systemImage: "eye") }
            AppsSettings()
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            LogSettings()
                .tabItem { Label("Log", systemImage: "list.bullet.rectangle") }
        }
        .frame(width: 560, height: 520)
    }
}

private struct AccessSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        Form {
            Section {
                Picker("Unlock with", selection: $preferences.unlockMethod) {
                    ForEach(UnlockMethod.allCases) { method in
                        Text(method.label).tag(method)
                            .disabled(method != .authorizeButton && !Preferences.hasBiometrics && method == .touchID)
                    }
                }
                Text(methodDescription(preferences.unlockMethod))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Lease duration", selection: $preferences.leaseDurationMinutes) {
                    ForEach(durationChoices(current: preferences.leaseDurationMinutes), id: \.self) {
                        Text(AppModel.durationText(minutes: $0)).tag($0)
                    }
                }
                Text("The last duration you unlocked with. Extend adds this much.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("When a call arrives locked, wait", selection: $preferences.unlockWaitSeconds) {
                    ForEach(Preferences.waitChoices, id: \.self) { seconds in
                        Text(seconds == 0 ? "Don't wait" : "\(seconds) s").tag(seconds)
                    }
                }
                Picker("Lock after no calls for", selection: $preferences.idleLockMinutes) {
                    ForEach(Preferences.idleChoices, id: \.self) { minutes in
                        Text(minutes == 0 ? "Off" : "\(minutes) min").tag(minutes)
                    }
                }
                .onChange(of: preferences.idleLockMinutes) { model.applyIdleTimeout() }
                LabeledContent("Kill shortcut") {
                    ShortcutRecorder(combo: $preferences.killShortcut) { recording in
                        // Let the current shortcut through while recording,
                        // so it can be typed again.
                        if recording { model.suspendKillShortcut() } else { model.applyKillShortcut() }
                    }
                }
                Text("Locks every agent at once, from any app. Locking the screen, sleeping and switching user always lock too.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Allow system file panels by default", isOn: $preferences.allowFilePanels)
            }
        }
        .formStyle(.grouped)
    }

    private func durationChoices(current: Int) -> [Int] {
        Array(Set(Preferences.durationChoices + [current])).sorted()
    }

    private func methodDescription(_ method: UnlockMethod) -> String {
        switch method {
        case .touchID:
            return Preferences.hasBiometrics
                ? "Each unlock and extension needs your fingerprint."
                : "This Mac has no Touch ID available right now (or the lid is closed). Pick another method."
        case .touchIDOrPassword:
            return "Touch ID, or your login password when Touch ID isn't available."
        case .authorizeButton:
            return "Press and hold Authorize in ClickRelay's window for a second. It ignores Accessibility presses, the keyboard, and clicks posted by other programs. The posted-click check relies on details macOS attaches to events, which haven't been confirmed on every Mac and macOS version, so use Touch ID if you have it."
        }
    }
}

private struct DisplaySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        Form {
            Section {
                Picker("While unlocked, show", selection: $preferences.indicatorStyle) {
                    ForEach(IndicatorStyle.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Highlight where clicks land", isOn: $preferences.showClickHighlights)
            }
            Section {
                Picker("Screenshot size (long edge)", selection: $preferences.screenshotMaxEdge) {
                    ForEach(Array(Set(Preferences.maxEdgeChoices + [preferences.screenshotMaxEdge])).sorted(), id: \.self) {
                        Text("\($0) px").tag($0)
                    }
                }
                Text("Agents can ask for a different size per screenshot.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        // Apps used before, plus any set by hand earlier.
        let apps = Array(Set(preferences.lastAllowedApps + preferences.inputDelivery.keys)).sorted {
            AppCatalog.name(for: $0).localizedCaseInsensitiveCompare(AppCatalog.name(for: $1)) == .orderedAscending
        }
        Form {
            Section {
                if apps.isEmpty {
                    Text("Apps show up here once you've allowed them for an agent.")
                        .foregroundStyle(.secondary)
                }
                ForEach(apps, id: \.self) { id in
                    Picker(selection: Binding(get: { preferences.delivery(for: id) },
                                              set: { preferences.setDelivery($0, for: id) })) {
                        ForEach(InputDelivery.allCases) { Text($0.label).tag($0) }
                    } label: {
                        HStack {
                            Image(nsImage: AppCatalog.icon(for: id)).resizable().frame(width: 18, height: 18)
                            Text(AppCatalog.name(for: id))
                        }
                    }
                }
            } header: {
                Text("Keyboard delivery")
            } footer: {
                Text("Targeted sends keystrokes only to that app, so they can't land anywhere else. Some apps ignore keystrokes sent that way; switch those to Global, which types into whatever is frontmost after checking it's still that app.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct LogSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        Form {
            Section {
                Picker("Keep logs for", selection: $preferences.auditRetentionDays) {
                    ForEach(Preferences.retentionChoices, id: \.self) { days in
                        Text(days == 1 ? "1 day" : "\(days) days").tag(days)
                    }
                }
                Toggle("Keep the text agents type", isOn: $preferences.keepTypedText)
                Text("Off, the log records only how many characters were typed or set.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Show log in Finder") { model.showLogInFinder() }
            } footer: {
                Text("Every call and every lock and unlock is written to ~/Library/Application Support/ClickRelay/Logs, one file per day, with small thumbnails of screenshots. Older files are deleted at launch.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Records a key combination for the kill shortcut. Shows the modifiers as
/// they're held, and says why a combination was turned down.
struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo
    /// Recording started or stopped.
    var onRecording: (Bool) -> Void = { _ in }
    @State private var recording = false
    @State private var held: NSEvent.ModifierFlags = []
    @State private var hint: String?
    @State private var monitor: Any?

    private static let modifierKeys: [NSEvent.ModifierFlags] = [.control, .option, .shift, .command]

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                if recording {
                    Button("Cancel", action: stop)
                } else if combo != .defaultKill {
                    Button("Reset") { combo = .defaultKill }
                }
                Button(action: { recording ? stop() : start() }) {
                    Text(label)
                        .monospacedDigit()
                        .frame(minWidth: 96)
                }
                .help(recording ? "Press the new shortcut, or Esc to cancel" : "Click, then press a new shortcut")
            }
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear(perform: stop)
    }

    private var label: String {
        guard recording else { return combo.display }
        return held.isEmpty ? "Press keys…" : Self.symbols(held) + "…"
    }

    private static func symbols(_ flags: NSEvent.ModifierFlags) -> String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text
    }

    private func start() {
        guard !recording else { return }
        recording = true
        held = []
        hint = "Hold two or more of ⌃ ⌥ ⇧ ⌘ and press a key."
        onRecording(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
            if event.type == .flagsChanged {
                held = flags
                return event
            }
            if event.keyCode == 53, flags.isEmpty {   // Esc cancels
                stop()
                return nil
            }
            // At least two modifiers, so it can't collide with normal typing
            // or an app's own shortcuts.
            guard Self.modifierKeys.filter(flags.contains).count >= 2 else {
                hint = flags.isEmpty
                    ? "That needs modifier keys. Hold two or more of ⌃ ⌥ ⇧ ⌘ and press a key."
                    : "One modifier would clash with app shortcuts. Add another of ⌃ ⌥ ⇧ ⌘."
                return nil
            }
            combo = KeyCombo(keyCode: event.keyCode, modifiers: flags.rawValue)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        held = []
        hint = nil
        if recording {
            recording = false
            onRecording(false)
        }
    }
}
