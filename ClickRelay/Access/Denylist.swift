import AppKit
import Darwin

/// Apps an agent can never see or control, whatever the user picks. Fixed in
/// code, with no setting to override it, so an agent can't unlock or widen its
/// own access by driving ClickRelay, System Settings or an auth prompt.
///
/// Keep every hard-coded bundle ID that denies access in this one file.
nonisolated enum Denylist {
    /// ClickRelay itself, and the system UI that grants or guards access.
    static let system: Set<String> = [
        MCPLocal.bundleIdentifier,
        "com.apple.systempreferences",          // System Settings
        "com.apple.Settings",
        "com.apple.SecurityAgent",              // auth dialogs
        "com.apple.LocalAuthentication.UIAgent",
        "com.apple.LocalAuthenticationUIService",
        "com.apple.coreautha",
        "com.apple.CoreAuthUI",
        "com.apple.loginwindow",
        "com.apple.keychainaccess",
        "com.apple.KeychainAccess",
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.systemuiserver",
        "com.apple.Spotlight",
        "com.apple.screensharing.agent",
        "com.apple.ScreenSharing",
        "com.apple.universalcontrol",
        "com.apple.accessibility.universalAccessAuthWarn",
        "com.apple.UserNotificationCenter"
    ]

    /// Password managers. Seeing or typing into one is never what an agent
    /// should be doing.
    static let passwordManagers: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        "com.agilebits.onepassword4",
        "com.bitwarden.desktop",
        "com.apple.Passwords",
        "com.lastpass.LastPass",
        "com.dashlane.dashlanephonefinal",
        "com.dashlane.Dashlane",
        "in.sinew.Enpass-Desktop",
        "org.keepassxc.keepassxc",
        "com.keepassium.mac",
        "me.proton.pass.electron",
        "com.nordpass.macos.NordPass",
        "com.roboform.mac"
    ]

    /// Everything above, in one set.
    static let all: Set<String> = system.union(passwordManagers)

    static func isDenied(_ bundleID: String) -> Bool {
        all.contains(bundleID)
    }

    /// Why an app is denied, for the picker.
    static func reason(for bundleID: String) -> String? {
        if bundleID == MCPLocal.bundleIdentifier { return "ClickRelay can't control itself" }
        if passwordManagers.contains(bundleID) { return "Password managers are never allowed" }
        if system.contains(bundleID) { return "Part of macOS security or system UI" }
        return nil
    }

    /// Why an app can't be allowed for one agent: the fixed list, or because
    /// the agent runs inside it.
    static func reason(for bundleID: String, agentHosts: Set<String>) -> String? {
        if let reason = reason(for: bundleID) { return reason }
        guard agentHosts.contains(bundleID) else { return nil }
        // Every known terminal means ClickRelay couldn't tell which one.
        return agentHosts == knownTerminals ? "Might run this agent" : "Runs this agent"
    }

    // MARK: - The agent's terminal

    /// `TERM_PROGRAM` values and the apps that set them. Typing into the
    /// agent's own terminal amounts to running shell commands (and approving
    /// its own permission prompts), so the agent's terminal is always denied.
    static let terminalsByTermProgram: [String: Set<String>] = [
        "Apple_Terminal": ["com.apple.Terminal"],
        "iTerm.app": ["com.googlecode.iterm2"],
        "vscode": ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
                   "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
                   "com.vscodium"],
        "WezTerm": ["com.github.wez.wezterm"],
        "ghostty": ["com.mitchellh.ghostty"],
        "WarpTerminal": ["dev.warp.Warp-Stable", "dev.warp.Warp"],
        "Hyper": ["co.zeit.hyper"],
        "Tabby": ["org.tabby"],
        "zed": ["dev.zed.Zed"],
        "kitty": ["net.kovidgoyal.kitty"],
        "alacritty": ["org.alacritty"],
        "rio": ["com.raphaelamorim.rio"],
        "Nova": ["com.panic.Nova"]
    ]

    /// Every terminal ClickRelay knows. Denied as a group when it can't tell
    /// which one the agent runs in (under tmux, say).
    static var knownTerminals: Set<String> {
        terminalsByTermProgram.values.reduce(into: Set<String>()) { $0.formUnion($1) }
    }

    /// The apps the agent is running inside: what `TERM_PROGRAM` names, plus
    /// every app found walking up from the agent's process. If neither turns
    /// anything up, every known terminal.
    static func agentHostApps(termProgram: String?, ancestorBundleIDs: Set<String>) -> Set<String> {
        var hosts = ancestorBundleIDs
        if let termProgram, let mapped = terminalsByTermProgram[termProgram] {
            hosts.formUnion(mapped)
        }
        hosts.remove(MCPLocal.bundleIdentifier)
        return hosts.isEmpty ? knownTerminals : hosts
    }
}

/// Resolves processes to apps. Behind a protocol so the policy can be tested
/// with made-up processes.
protocol ProcessResolver: Sendable {
    func bundleID(for pid: pid_t) -> String?
    func appName(for pid: pid_t) -> String?
}

nonisolated struct SystemProcessResolver: ProcessResolver {
    func bundleID(for pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    func appName(for pid: pid_t) -> String? {
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
        var buffer = [UInt8](repeating: 0, count: Int(MAXCOMLEN) + 1)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(decoding: buffer.prefix(Int(length)), as: UTF8.self) : nil
    }

    /// Bundle IDs of every app above `pid` in the process tree: the terminal
    /// (or editor) the agent was started from.
    static func ancestorBundleIDs(of pid: pid_t) -> Set<String> {
        var ids = Set<String>()
        var current = pid
        var seen = Set<pid_t>()
        while current > 1, !seen.contains(current), seen.count < 64 {
            seen.insert(current)
            if let id = NSRunningApplication(processIdentifier: current)?.bundleIdentifier {
                ids.insert(id)
            }
            guard let parent = parentPID(of: current) else { break }
            current = parent
        }
        return ids
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }
}
