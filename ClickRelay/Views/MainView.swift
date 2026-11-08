import SwiftUI

/// The main window: the first-run checklist until it's done, then a sidebar
/// of agents with the selected agent's card on the right.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if model.preferences.setupFinished {
                AgentsSplitView()
            } else {
                SetupChecklist(style: .firstRun)
                    .frame(minWidth: 600, idealWidth: 820, minHeight: 520, idealHeight: 600)
            }
        }
        .sheet(item: Binding(get: { model.authenticator.pendingAuthorization },
                             set: { if $0 == nil { model.authenticator.finishAuthorization(.cancelled) } })) { prompt in
            AuthorizeSheet(prompt: prompt) { model.authenticator.finishAuthorization($0) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
        .onAppear {
            model.refreshPermissions()
            let open = openWindow
            model.openMainWindow = { open(id: "main") }
        }
    }
}

private struct AgentsSplitView: View {
    @Environment(AppModel.self) private var model
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            AgentSidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            Group {
                if let id = model.selectedSessionID, let session = model.anySession(id) {
                    AgentDetailView(session: session, connected: model.session(id) != nil)
                        .id(id)
                } else {
                    EmptyDetail()
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { StatusBars() }
        }
        .frame(minWidth: 600, idealWidth: 820, minHeight: 520, idealHeight: 600)
        .navigationTitle("ClickRelay")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.leases.isAnyUnlocked {
                    Button(role: .destructive) { model.lockNow() } label: {
                        Label("Lock All", systemImage: "lock.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .help("Ends every agent's access (\(model.preferences.killShortcut.display) from anywhere)")
                }
                SettingsLink { Label("Settings", systemImage: "gearshape") }
            }
        }
    }
}

// MARK: - Sidebar

private struct AgentSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: Binding(get: { model.selectedSessionID }, set: { model.select($0) })) {
            Section("Agents") {
                if model.sessions.isEmpty {
                    Text("None connected.")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
                ForEach(model.sessions) { session in
                    AgentRow(session: session).tag(session.id)
                        .contextMenu { contextMenu(for: session, connected: true) }
                }
            }
            if !model.pastSessions.isEmpty {
                Section("Disconnected Today") {
                    ForEach(model.pastSessions) { session in
                        AgentRow(session: session, connected: false).tag(session.id)
                            .contextMenu { contextMenu(for: session, connected: false) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarFooter() }
    }

    @ViewBuilder private func contextMenu(for session: AgentSession, connected: Bool) -> some View {
        if connected, model.leases.leases[session.id] != nil {
            Button("Lock") { model.lock(sessionID: session.id) }
        }
        Button("Clear Calls") { model.clearActivity(for: session.id) }
        Button("Show Log in Finder") { model.showLogInFinder() }
    }
}

/// Folder name first, since that's what tells two Claude Code sessions apart.
struct AgentRow: View {
    @Environment(AppModel.self) private var model
    let session: AgentSession
    var connected = true

    var body: some View {
        HStack(spacing: 8) {
            StateMark(sessionID: session.id, connected: connected)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.shortName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            trailing
        }
        .help(session.displayName)
    }

    private var subtitle: String {
        if !connected {
            let count = model.activity(for: session.id).count
            return count == 1 ? "1 call" : "\(count) calls"
        }
        return session.terminalName
            ?? session.workingDirectory.map(MCPLocal.abbreviatingHome)
            ?? ""
    }

    /// Asking or a notice wins over the time left, so the agent that wants
    /// you stands out in the list.
    @ViewBuilder private var trailing: some View {
        if !connected {
            EmptyView()
        } else if model.handOffs.handOffs[session.id] != nil {
            Badge(text: "Your turn", color: .handOff)
        } else if model.request(for: session.id) != nil {
            Badge(text: "Asking", color: .blue)
        } else if let notice = model.notices[session.id] {
            Badge(text: notice.kind == .done ? "Done" : "Needs you", color: notice.kind == .done ? .green : .orange)
        } else if let lease = model.leases.leases[session.id] {
            Countdown(until: lease.endDate) { left in
                Text(AppModel.clock(.seconds(left)))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.orange)
            }
        } else if model.gaveUp[session.id] != nil {
            Text("Asked").font(.caption.weight(.semibold)).foregroundStyle(.blue)
                .help("It asked for access and gave up waiting. Unlock to let its next call through.")
        } else {
            Text("Locked").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A filled capsule for something that wants the user.
private struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color))
    }
}

/// Blue hand: asking. Green tick or orange mark: it said it's done or needs
/// you. Orange dot: unlocked. Grey dot: locked.
struct StateMark: View {
    @Environment(AppModel.self) private var model
    let sessionID: String
    var connected = true

    var body: some View {
        Group {
            if !connected {
                Image(systemName: "circle").foregroundStyle(.tertiary)
            } else if model.handOffs.handOffs[sessionID] != nil {
                Image(systemName: "hand.raised.circle.fill").foregroundStyle(Color.handOff)
                    .font(.body)
            } else if model.request(for: sessionID) != nil {
                Image(systemName: "hand.raised.circle.fill").foregroundStyle(.blue)
                    .font(.body)
                    .symbolEffect(.pulse, options: .repeating)
            } else if let notice = model.notices[sessionID] {
                Image(systemName: notice.kind == .done ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(notice.kind == .done ? Color.green : Color.orange)
                    .font(.body)
            } else if model.leases.leases[sessionID] != nil {
                Image(systemName: "circle.fill").foregroundStyle(.orange)
            } else {
                Image(systemName: "circle.fill").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 9))
        .frame(width: 16)
    }
}

private struct SidebarFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider().padding(.bottom, 5)
            let count = model.leases.leases.count
            Label {
                Text(count == 0 ? "Everything locked" : count == 1 ? "1 agent unlocked" : "\(count) agents unlocked")
            } icon: {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(count == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.orange))
            }
            Text("Lock all from anywhere: \(model.preferences.killShortcut.display)")
                .foregroundStyle(.secondary)
            if model.outdatedBridges > 0 {
                Label(model.outdatedBridges == 1
                      ? "An agent is still using the previous version of ClickRelay. Restart it to reconnect."
                      : "\(model.outdatedBridges) agents are still using the previous version of ClickRelay. Restart them to reconnect.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("ClickRelay was updated while they were open. In Claude Code, run /mcp and reconnect clickrelay, or start a new session.")
            }
            let others = model.rejectedPeers - model.outdatedBridges
            if others > 0 {
                Text(others == 1
                     ? "Turned away 1 program that tried to connect."
                     : "Turned away \(others) programs that tried to connect.")
                    .foregroundStyle(.secondary)
                    .help("Only ClickRelay's own bridge, launched by your agent, may connect.")
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Bars and empty state

/// Shown above the detail pane only when something is wrong.
private struct StatusBars: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if !model.permissions.screenRecording {
                bar("Screen Recording is off, so agents can't take screenshots and Unlock is disabled.",
                    action: "Open Settings") { Permissions.openSettings(.screenRecording) }
            }
            if model.permissions.screenRecording, !model.preferences.directCaptureConfirmed {
                bar(model.checkingDirectCapture
                        ? "Choose Allow when macOS asks about screen recording."
                        : "Screenshots won't work until you allow screen recording in macOS's prompt. Take a test screenshot and choose Allow when it asks.",
                    detail: model.unlockError,
                    action: model.checkingDirectCapture ? nil : "Take Test Screenshot") {
                    Task { await model.confirmDirectCapture() }
                }
            }
            if !model.permissions.accessibility {
                bar("Accessibility is off, so agents can't click or type and Unlock is disabled.",
                    action: "Open Settings") { Permissions.openSettings(.accessibility) }
            }
            if let error = model.serverError {
                bar("Agents can't connect because ClickRelay couldn't start its local server.",
                    detail: error, isError: true, action: nil) {}
            }
        }
    }

    private func bar(_ text: String, detail: String? = nil, isError: Bool = false,
                     action: String?, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isError ? .red : .yellow)
            Text(text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .help(detail ?? "")
            if let action { Button(action, action: perform) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isError ? Color.red.opacity(0.12) : Color.yellow.opacity(0.15))
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct EmptyDetail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Locked", systemImage: "lock")
        } description: {
            Text("When an agent connects, its session appears on the left. If it needs to see or control an app, it has to ask you here first.")
        } actions: {
            Button("Open Today's Log") { model.showLogInFinder() }
                .buttonStyle(.link)
        }
    }
}

extension AgentSession {
    /// The working directory's last component, or the client's name.
    var folderName: String {
        guard let workingDirectory, !workingDirectory.isEmpty else { return clientName }
        let name = URL(filePath: workingDirectory).lastPathComponent
        return name.isEmpty || name == "/" ? workingDirectory : name
    }

    /// "Claude Code in randomizer2": how the UI names an agent. Shorter than
    /// `displayName`, which has the whole path.
    var shortName: String {
        guard let workingDirectory, !workingDirectory.isEmpty else { return clientName }
        return "\(clientName) in \(folderName)"
    }

    /// The terminal the agent runs in, if ClickRelay could tell.
    var terminalName: String? {
        let known = hostBundleIDs != Denylist.knownTerminals
        let running = hostBundleIDs.filter(AppCatalog.isRunning).sorted().map(AppCatalog.name(for:))
        if known, let first = running.first { return first }
        return termProgram
    }
}
