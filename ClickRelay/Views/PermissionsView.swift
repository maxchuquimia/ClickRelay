import SwiftUI

/// The setup checklist: both permissions, the direct-capture prompt, and
/// adding ClickRelay to an agent. Fills the main window on first run and
/// lives in Settings ▸ Setup after that. Re-checked whenever ClickRelay
/// becomes active.
struct SetupChecklist: View {
    enum Style { case firstRun, settings }

    @Environment(AppModel.self) private var model
    let style: Style
    @State private var copied = false
    @AppStorage("setupAgent") private var agent = AgentSetup.claudeCode.rawValue

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 0) {
            if style == .firstRun {
                Text("Set up ClickRelay")
                    .font(.title.weight(.semibold))
                    .padding(.bottom, 4)
                Text("ClickRelay holds these permissions so your agent's terminal never has to. It only uses them while you've unlocked it.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 12)
            }
            step(1, done: model.permissions.screenRecording, current: next == 1,
                 title: "Screen Recording", detail: "For screenshots of the apps you allow.") {
                if !model.permissions.screenRecording {
                    action("Open System Settings", prominent: next == 1) {
                        Permissions.requestScreenRecording()
                        Permissions.openSettings(.screenRecording)
                    }
                }
            } footer: {
                if !model.permissions.screenRecording {
                    Text("After turning it on, macOS may ask you to quit and reopen ClickRelay.")
                }
            }
            Divider()
            step(2, done: model.permissions.accessibility, current: next == 2,
                 title: "Accessibility",
                 detail: "For reading buttons and fields, clicking and typing. System Settings opens on the right page. Switch ClickRelay on there, then come back.") {
                if !model.permissions.accessibility {
                    action("Open System Settings", prominent: next == 2) {
                        Permissions.requestAccessibility()
                        Permissions.openSettings(.accessibility)
                    }
                }
            }
            Divider()
            step(3, done: model.preferences.directCaptureConfirmed, current: next == 3,
                 title: "Test screenshot",
                 detail: model.preferences.directCaptureConfirmed
                    ? "macOS may ask again from time to time. Choose Allow when it does."
                    : "macOS asks once more on the first capture. Choose Allow now so an agent's first screenshot doesn't stall.") {
                if !model.preferences.directCaptureConfirmed {
                    action(model.checkingDirectCapture ? "Waiting…" : "Take Test Screenshot", prominent: next == 3) {
                        Task { await model.confirmDirectCapture() }
                    }
                    .disabled(!model.permissions.screenRecording || model.checkingDirectCapture)
                    .help(model.permissions.screenRecording ? "" : "Needs Screen Recording first.")
                }
            }
            Divider()
            step(4, done: model.preferences.hasConnectedAgent, current: next == 4,
                 title: "Add to your agent",
                 detail: "Do this once for each agent you use. This step ticks itself when one first connects.") {
                EmptyView()
            } footer: {
                let setup = AgentSetup(rawValue: agent) ?? .claudeCode
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Agent", selection: $agent) {
                        ForEach(AgentSetup.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Text(setup.location)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top) {
                        Text(setup.snippet)
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(setup.snippet, forType: .string)
                            copied = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                copied = false
                            }
                        }
                    }
                    if setup != .claudeCode {
                        Text("If the file already has servers in it, add the clickrelay entry next to them. Config formats change between versions, so adjust the keys if yours differs.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let error = model.unlockError, style == .firstRun || !model.preferences.directCaptureConfirmed {
                Text(error).font(.callout).foregroundStyle(.red).padding(.top, 8)
            }
            if style == .firstRun {
                Spacer(minLength: 16)
                HStack {
                    Text("All of this is in Settings ▸ Setup later.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") { model.finishSetup() }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        if style == .firstRun {
            ScrollView {
                content
                    .padding(.horizontal, 56)
                    .padding(.vertical, 28)
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
        } else {
            content.padding(20)
        }
    }

    /// The first step still to do, if any.
    private var next: Int? {
        if !model.permissions.screenRecording { return 1 }
        if !model.permissions.accessibility { return 2 }
        if !model.preferences.directCaptureConfirmed { return 3 }
        if !model.preferences.hasConnectedAgent { return 4 }
        return nil
    }

    private func action(_ title: String, prominent: Bool, perform: @escaping () -> Void) -> some View {
        Group {
            if prominent {
                Button(title, action: perform).buttonStyle(.borderedProminent)
            } else {
                Button(title, action: perform)
            }
        }
    }

    private func step<Trailing: View, Footer: View>(
        _ number: Int, done: Bool, current: Bool, title: String, detail: String,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder footer: () -> Footer = { EmptyView() }
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                } else {
                    Circle()
                        .strokeBorder(current ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: 1.5)
                        .frame(width: 22, height: 22)
                    Text("\(number)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(current ? Color.accentColor : Color.secondary)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline)
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if done, number < 4 {
                        Text(number == 3 ? "Allowed" : "Granted").foregroundStyle(.secondary)
                    } else {
                        trailing()
                    }
                }
                footer()
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 12)
    }
}

/// How to add ClickRelay to each agent ClickRelay knows. Every one launches
/// ClickRelay's own executable with `--mcp`.
enum AgentSetup: String, CaseIterable, Identifiable {
    case claudeCode, codex, cursor, windsurf, vsCode, zed, antigravity

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex CLI"
        case .cursor: "Cursor"
        case .windsurf: "Windsurf"
        case .vsCode: "VS Code (GitHub Copilot)"
        case .zed: "Zed"
        case .antigravity: "Antigravity"
        }
    }

    /// Where the snippet goes.
    var location: String {
        switch self {
        case .claudeCode: "Run this in Terminal:"
        case .codex: "Add this to ~/.codex/config.toml:"
        case .cursor: "Add this to ~/.cursor/mcp.json:"
        case .windsurf: "Add this to ~/.codeium/windsurf/mcp_config.json (newer versions use ~/.config/devin/mcp_config.json):"
        case .vsCode: "In the Command Palette, choose MCP: Open User Configuration and add:"
        case .zed: "Add this to ~/.config/zed/settings.json:"
        case .antigravity: "Add this to ~/.gemini/config/mcp_config.json (in Antigravity: the … menu on the agent panel, then MCP Servers, Manage MCP Servers, View raw config):"
        }
    }

    var snippet: String {
        let path = MCPLocal.bridgeExecutablePath
        let args = [MCPLocal.bridgeArgument]
        switch self {
        case .claudeCode:
            return MCPLocal.claudeAddCommand
        case .codex:
            return "[mcp_servers.clickrelay]\ncommand = \(Self.json(path))\nargs = [\"\(MCPLocal.bridgeArgument)\"]"
        case .cursor, .windsurf, .antigravity:
            return Self.json(["mcpServers": ["clickrelay": ["command": path, "args": args]]])
        case .vsCode:
            return Self.json(["servers": ["clickrelay": ["type": "stdio", "command": path, "args": args]]])
        case .zed:
            return Self.json(["context_servers": ["clickrelay": ["command": path, "args": args,
                                                                "env": [String: String]()]]])
        }
    }

    /// Pretty JSON, keys in a stable order, slashes left alone.
    private static func json(_ value: Any) -> String {
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
                                                         .fragmentsAllowed]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: options) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
