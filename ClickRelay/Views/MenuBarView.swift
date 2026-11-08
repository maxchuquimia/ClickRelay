import SwiftUI

/// The menu bar item: the shield, filled while anything is unlocked, with
/// the time left, or what's waiting for the user. The menu covers each agent
/// plus Lock All, so the main window can stay closed while an agent works.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let icon = Image(nsImage: model.menuBarTime == nil ? MenuBarIcon.image : MenuBarIcon.filledImage)
        if let text {
            HStack(spacing: 4) {
                icon
                Text(text).monospacedDigit()
            }
        } else {
            icon
        }
    }

    /// Asking beats done beats the time left.
    private var text: String? {
        if model.handOffs.isAnyOpen { return "Your turn" }
        if !model.leases.requests.isEmpty { return "Asking" }
        if let notice = model.notices.values.max(by: { $0.date < $1.date }) {
            return notice.kind == .done ? "Done" : "Needs you"
        }
        return model.menuBarTime
    }
}

struct MenuBarMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.sessions.isEmpty {
            Text("No agents connected")
        }
        ForEach(model.sessions) { session in
            Section {
                if model.handOffs.handOffs[session.id] != nil {
                    Button("Show Where…") { model.showHandOff(sessionID: session.id) }
                }
                if let lease = model.leases.leases[session.id] {
                    Text(AppModel.list(lease.allowedBundleIDs.subtracting(AccessPolicy.filePanelServices)
                        .sorted().map(AppCatalog.name(for:))))
                    if model.preferences.unlockMethod == .authorizeButton {
                        Button("Extend…") { open(session.id) }
                    } else {
                        Button("Extend \(AppModel.shortDuration(minutes: model.preferences.leaseDurationMinutes))") {
                            Task { await model.extend(sessionID: session.id) }
                        }
                    }
                    Button("Lock") { model.lock(sessionID: session.id) }
                    if model.request(for: session.id) != nil {
                        Button("Review Request…") { open(session.id) }
                    }
                } else if model.request(for: session.id) != nil {
                    Button("Review Request…") { open(session.id) }
                } else {
                    // Unlocking always happens next to the app list.
                    Button("Unlock…") { open(session.id) }
                }
                if let notice = model.notices[session.id] {
                    Button(notice.kind == .done ? "Done: \(notice.message)" : "Needs you: \(notice.message)") {
                        open(session.id)
                        model.dismissNotice(sessionID: session.id)
                    }
                }
            } header: {
                Text(header(session))
            }
        }
        if !model.alerts.isEmpty {
            Divider()
            Button("Show Alerts") { model.alertPanel.show() }
        }
        Divider()
        Button("Lock All") { model.lockNow() }
            .disabled(!model.leases.isAnyUnlocked)
        Button("Open ClickRelay") { open(nil) }
        Divider()
        SettingsLink { Text("Settings…") }
        Button("Quit ClickRelay") { NSApp.terminate(nil) }
    }

    private func header(_ session: AgentSession) -> String {
        if model.handOffs.handOffs[session.id] != nil { return "\(session.shortName) · Your turn" }
        if let remaining = model.leases.remaining(for: session.id) {
            return "\(session.shortName) · \(AppModel.clock(remaining))"
        }
        if model.request(for: session.id) != nil { return "\(session.shortName) · Asking" }
        if let notice = model.notices[session.id] {
            return "\(session.shortName) · \(notice.kind == .done ? "Done" : "Needs you")"
        }
        return "\(session.shortName) · Locked"
    }

    private func open(_ sessionID: String?) {
        if let sessionID { model.select(sessionID) }
        openWindow(id: "main")
        model.showMainWindow(activate: true)
    }
}
