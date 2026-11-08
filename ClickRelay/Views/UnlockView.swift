import SwiftUI
import UniformTypeIdentifiers

/// A locked agent's card: what it's asking for (if anything), the apps it may
/// use, how long, and one Unlock button that says what it approves.
///
/// What the agent asks for never ticks anything. Ticks come only from the
/// user's last selection, so an agent can't steer its own allowlist.
struct UnlockCard: View {
    @Environment(AppModel.self) private var model
    let session: AgentSession
    let request: AccessRequest?
    @State private var working = false

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            heading
            if let request {
                requestWarnings(request)
            }
            if !targetIsForbidden {
                AppPicker(session: session)
                Toggle(isOn: $model.selectedFilePanels) {
                    Text("Also allow Open and Save panels")
                }
                .toggleStyle(.checkbox)
                .help("Open and Save dialogs are drawn by a separate system process, so they need their own permission.")
                DurationPicker()
            }
            actions
        }
        .padding(14)
        .background(background)
    }

    // MARK: Heading

    @ViewBuilder private var heading: some View {
        if let request {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Label(Self.describe(request), systemImage: "hand.raised.fill")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .labelStyle(TintedIconLabelStyle(tint: .blue))
                    Spacer()
                    requestDeadline(request)
                }
                if let reason = request.reason {
                    AgentQuote(text: reason)
                }
            }
        } else if let gaveUp = model.gaveUp[session.id] {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Self.describe(gaveUp, past: true)) at \(gaveUp.createdAt.formatted(date: .omitted, time: .shortened))")
                        .font(.headline)
                    Spacer()
                    Text("Gave up").font(.callout).foregroundStyle(.secondary)
                    Button {
                        model.dismissGaveUp(sessionID: session.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
                Text("The agent was told it's locked and to ask you. You can still unlock now, and its next call goes straight through.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                if let record = model.lastLocks[session.id] {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Locked at \(record.date.formatted(date: .omitted, time: .shortened))")
                                .font(.headline)
                            Text(record.reason.cardText)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Text(summary(record))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Locked").font(.headline)
                }
                Spacer()
                if let other = otherUnlocked {
                    Button("Use the same apps as \(other.shortName)") { model.useApps(from: other.id) }
                        .buttonStyle(.link)
                }
            }
        }
    }

    @ViewBuilder private func requestDeadline(_ request: AccessRequest) -> some View {
        if let deadline = request.deadline {
            Countdown(until: deadline) { left in
                Text("Gives up in \(AppModel.clock(.seconds(left)))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Asked at \(request.createdAt.formatted(date: .omitted, time: .shortened))")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func summary(_ record: LockRecord) -> String {
        let calls = record.calls == 1 ? "1 call" : "\(record.calls) calls"
        let refused = record.refused > 0 ? ", \(record.refused) refused" : ""
        return "\(calls) in \(AppModel.shortDuration(minutes: record.minutes))\(refused)."
    }

    /// Another connected session that's unlocked, to copy apps from.
    private var otherUnlocked: AgentSession? {
        model.sessions.first { $0.id != session.id && model.leases.leases[$0.id] != nil }
    }

    // MARK: Target

    /// A locked call aimed at an app that can never be allowed: there's
    /// nothing to unlock, so the card offers only Not Now.
    private var targetIsForbidden: Bool {
        guard let request, !request.explicit, let target = request.targetBundleID else { return false }
        return model.deniedReason(target, for: session) != nil
    }

    /// What the request names that the card won't give as it stands.
    @ViewBuilder private func requestWarnings(_ request: AccessRequest) -> some View {
        let named = request.namedApps.filter { !AccessPolicy.filePanelServices.contains($0) }
        let forbidden = named.filter { model.deniedReason($0, for: session) != nil }
        let unticked = named.filter { !forbidden.contains($0) && !model.selectedApps.contains($0) }
        ForEach(forbidden, id: \.self) { id in
            warning("\(AppCatalog.name(for: id)) can't be allowed for this agent (\(model.deniedReason(id, for: session)!.lowercasedFirst)).")
        }
        if !unticked.isEmpty {
            let names = AppModel.list(unticked.map(AppCatalog.name(for:)))
            let verb = unticked.count == 1 ? "isn't" : "aren't"
            warning(request.explicit
                    ? "\(names) \(verb) ticked below. Tick \(unticked.count == 1 ? "it" : "them") if you want to allow \(unticked.count == 1 ? "it" : "them")."
                    : "\(names) \(verb) ticked, so this call will still be refused.")
        }
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .labelStyle(TintedIconLabelStyle(tint: .yellow))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.yellow.opacity(0.15)))
    }

    // MARK: Actions

    private var actions: some View {
        let blocked = model.cardBlockedReason(sessionID: session.id)
        let minutes = model.selectedMinutes
        return HStack(spacing: 10) {
            Text(blocked ?? hint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            if let request {
                if targetIsForbidden {
                    Button("Not Now") { model.leases.dismissRequest(request.id) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Not Now") { model.leases.dismissRequest(request.id) }
                        .controlSize(.large)
                        .help("The waiting call fails now with the usual locked message.")
                }
            }
            if !targetIsForbidden {
                Button(model.lastLocks[session.id] != nil && request == nil
                       ? "Unlock Again for \(AppModel.shortDuration(minutes: minutes))"
                       : "Unlock for \(AppModel.shortDuration(minutes: minutes))") {
                    working = true
                    Task {
                        await model.unlockSelected(sessionID: session.id)
                        working = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.large)
                .disabled(blocked != nil || working)
            }
        }
    }

    private var hint: String {
        switch model.preferences.unlockMethod {
        case .touchID: "Asks for Touch ID"
        case .touchIDOrPassword: "Asks for Touch ID or your password"
        case .authorizeButton: "Then hold Authorize"
        }
    }

    @ViewBuilder private var background: some View {
        if request != nil {
            RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.blue, lineWidth: 2))
        } else if model.gaveUp[session.id] != nil {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.blue.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        } else {
            RoundedRectangle(cornerRadius: 10).strokeBorder(.separator)
        }
    }

    // MARK: Describing a request

    /// "Wants to click in Simulator", "Wants to use Mail and Safari".
    static func describe(_ request: AccessRequest, past: Bool = false, unlocked: Bool = false) -> String {
        let app = request.targetBundleID.map(AppCatalog.name(for:))
        let tool = ToolName(rawValue: request.tool)
        let what: String
        switch tool {
        case .requestAccess:
            let apps = request.apps.map(AppCatalog.name(for:))
            if apps.isEmpty {
                what = unlocked ? "have more time" : "use ClickRelay"
            } else {
                what = "use \(AppModel.list(apps))\(unlocked ? " too" : "")"
            }
        case .screenshot: what = app.map { "take a screenshot of \($0)" } ?? "see your screen"
        case .listWindows: what = "list your windows"
        case .getUITree, .findElements: what = app.map { "read the controls in \($0)" } ?? "read an app's controls"
        case .press: what = "press a button"
        case .setValue: what = "fill in a field"
        case .click: what = app.map { "click in \($0)" } ?? "click"
        case .drag: what = app.map { "drag in \($0)" } ?? "drag"
        case .scroll: what = app.map { "scroll in \($0)" } ?? "scroll"
        case .type: what = "type into the frontmost app"
        case .key: what = "press keys in the frontmost app"
        case .focusWindow: what = app.map { "bring \($0) to the front" } ?? "bring a window to the front"
        case .launchApp: what = app.map { "open \($0)" } ?? "open an app"
        case .handOff: what = app.map { "hand something in \($0) to you" } ?? "hand something to you"
        case .runScript: what = app.map { "run a script in \($0)" } ?? "run a script"
        case .saveScript: what = "save its steps as a script"
        case .status, .notify, .validateScript, nil: what = "use ClickRelay"
        }
        return (past ? "Asked to " : "Wants to ") + what
    }
}

/// Something the agent wrote, set apart so it doesn't read as ClickRelay's
/// own words.
struct AgentQuote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "quote.opening").font(.caption).foregroundStyle(.tertiary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .help("Written by the agent")
    }
}

/// Seconds left until `end`, redrawn once a second by a `TimelineView` on
/// the second boundaries of the countdown. Only `content` redraws, so wrap
/// as little as possible in it.
struct Countdown<Content: View>: View {
    let end: Date
    @ViewBuilder let content: (Int) -> Content

    init(until end: Date, @ViewBuilder content: @escaping (Int) -> Content) {
        self.end = end
        self.content = content
    }

    var body: some View {
        // Anchored so each tick lands as a whole second of the countdown ends.
        let anchor = end.addingTimeInterval(-max(0, end.timeIntervalSinceNow).rounded(.up))
        TimelineView(.periodic(from: anchor, by: 1)) { context in
            content(max(0, Int((end.timeIntervalSince(context.date) - 0.05).rounded(.up))))
        }
    }
}

private struct TintedIconLabelStyle: LabelStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

extension LockReason {
    /// Why a card is locked, as a short phrase.
    var cardText: String {
        switch self {
        case .expired: "Time ran out"
        case .lockNow: "You locked it"
        case .killShortcut: "Locked with the shortcut"
        case .screenLocked: "The screen locked"
        case .screensaver: "The screensaver started"
        case .sleep: "The Mac went to sleep"
        case .sessionResigned: "You switched user"
        case .allowedAppsQuit: "Every allowed app quit"
        case .idle: "No calls for a while"
        case .disconnected: "The agent disconnected"
        case .replaced: "Unlocked again"
        case .appQuit: "ClickRelay quit"
        case .permissionRevoked: "A permission was turned off"
        case .released: "The agent finished and gave it back"
        }
    }
}

extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

// MARK: - Apps

/// The apps an agent may see and control: what it asked for and last time's
/// first, then whatever's running. Folds to a few rows, with search.
struct AppPicker: View {
    @Environment(AppModel.self) private var model
    let session: AgentSession
    @State private var entries: [AppEntry] = []
    @State private var expanded = false
    @State private var search = ""
    @State private var addNote: String?

    static let foldedRows = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Apps it may see and control").font(.subheadline.weight(.semibold))
                Spacer()
                TextField("Find an App", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
            }
            let shown = visible
            VStack(spacing: 0) {
                ForEach(shown) { entry in
                    row(entry)
                    if entry.id != shown.last?.id { Divider() }
                }
                if shown.isEmpty {
                    Text(search.isEmpty ? "No apps running." : "No app matches \u{201C}\(search)\u{201D}.")
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            HStack(spacing: 12) {
                let hidden = filtered.count - Self.foldedRows
                if search.isEmpty, hidden > 0 {
                    Button(expanded ? "Show Fewer" : "Show \(hidden) More") { expanded.toggle() }
                        .buttonStyle(.link)
                }
                Button("Add an App…", action: addApp).buttonStyle(.link)
                if let addNote {
                    Text(addNote).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .font(.callout)
        }
        .onAppear(perform: reload)
        .onChange(of: session.id) { reload() }
        .onChange(of: requested) { reload() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in reload() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in reload() }
    }

    private var filtered: [AppEntry] {
        guard !search.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var visible: [AppEntry] {
        let list = filtered
        return expanded || !search.isEmpty ? list : Array(list.prefix(Self.foldedRows))
    }

    @ViewBuilder private func row(_ entry: AppEntry) -> some View {
        let denied = model.deniedReason(entry.bundleID, for: session)
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { denied == nil && model.selectedApps.contains(entry.bundleID) },
                set: { on in
                    if on { model.selectedApps.insert(entry.bundleID) }
                    else { model.selectedApps.remove(entry.bundleID) }
                })) {
                HStack(spacing: 6) {
                    Image(nsImage: AppCatalog.icon(for: entry.bundleID))
                        .resizable()
                        .frame(width: 18, height: 18)
                    Text(entry.name).lineLimit(1).truncationMode(.tail)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(denied != nil)
            Spacer(minLength: 6)
            if requested.contains(entry.bundleID), denied == nil {
                Text("Asked for").font(.caption.weight(.medium)).foregroundStyle(.blue)
            }
            if let denied {
                Text(denied).font(.caption).foregroundStyle(.secondary)
                    .help(denied == "Might run this agent"
                          ? "ClickRelay couldn't tell which terminal this agent runs in, so every terminal is off limits. Typing into it would be the same as running commands, including approving its own prompts."
                          : "Typing into the terminal an agent runs in is the same as running commands, including approving its own prompts.")
            } else if !entry.isRunning {
                Text("Not running").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .opacity(denied == nil ? 1 : 0.55)
    }

    /// Sorted once per reload (not on every tick), so rows don't jump around
    /// while the user ticks them.
    /// Apps the agent's current request names. Listed first, never ticked.
    private var requested: [String] {
        (model.request(for: session.id)?.namedApps ?? []).filter { !AccessPolicy.filePanelServices.contains($0) }
    }

    private func reload() {
        let last = Set(model.selectedApps)
        let asked = requested
        let extra = asked + model.preferences.lastAllowedApps + Array(last)
        // Hard-denied apps can never be ticked, so they're left out.
        let all = AppCatalog.pickerEntries(extra: extra).filter { !Denylist.isDenied($0.bundleID) }
        func rank(_ entry: AppEntry) -> Int {
            if asked.contains(entry.bundleID) { return 0 }
            if last.contains(entry.bundleID) { return 1 }
            if model.deniedReason(entry.bundleID, for: session) != nil { return 3 }
            return 2
        }
        entries = all.enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    private func addApp() {
        addNote = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        var refused: [String] = []
        for url in panel.urls {
            guard let id = AppCatalog.bundleID(ofAppAt: url) else { continue }
            if let reason = Denylist.reason(for: id) {
                refused.append("\(AppCatalog.name(for: id)) wasn't added: \(reason.lowercasedFirst).")
                continue
            }
            if let reason = model.deniedReason(id, for: session) {
                refused.append("\(AppCatalog.name(for: id)) wasn't added: \(reason.lowercasedFirst).")
                continue
            }
            model.selectedApps.insert(id)
        }
        addNote = refused.isEmpty ? nil : refused.joined(separator: " ")
        reload()
    }
}

// MARK: - Duration

/// The quick durations as a segmented control, with Other… for anything
/// else. A custom value gets its own segment so something is always picked.
struct DurationPicker: View {
    @Environment(AppModel.self) private var model
    @State private var showingCustom = false
    @State private var customValue = 2
    @State private var customUnit = Unit.hours

    enum Unit: String, CaseIterable, Identifiable {
        case minutes, hours
        var id: String { rawValue }
    }

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            Text("For").font(.subheadline.weight(.semibold)).frame(width: 30, alignment: .leading)
            Picker("For", selection: $model.selectedMinutes) {
                ForEach(choices, id: \.self) { Text(AppModel.shortDuration(minutes: $0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button("Other…") { showingCustom = true }
                .popover(isPresented: $showingCustom, arrowEdge: .bottom) { customPopover }
            Spacer()
        }
    }

    private var choices: [Int] {
        Array(Set(Preferences.durationChoices + [model.selectedMinutes])).sorted()
    }

    private var customPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How long?").font(.headline)
            HStack {
                TextField("", value: $customValue, format: .number)
                    .frame(width: 70)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $customUnit) {
                    Text("minutes").tag(Unit.minutes)
                    Text("hours").tag(Unit.hours)
                }
                .labelsHidden()
                .frame(width: 110)
            }
            HStack {
                Spacer()
                Button("Use") {
                    showingCustom = false
                    model.selectedMinutes = max(1, customUnit == .hours ? customValue * 60 : customValue)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(customValue < 1)
            }
        }
        .padding(16)
    }
}
