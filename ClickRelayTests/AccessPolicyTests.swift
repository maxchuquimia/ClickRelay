import Foundation
import Testing
@testable import ClickRelay

@Suite("Allowlist and denylist")
struct AccessPolicyTests {
    @Test(arguments: ["io.mergeable.ClickRelay", "com.apple.systempreferences", "com.apple.SecurityAgent",
                      "com.apple.loginwindow", "com.apple.keychainaccess", "com.apple.dock",
                      "com.apple.controlcenter", "com.apple.notificationcenterui",
                      "com.1password.1password", "com.bitwarden.desktop", "com.apple.Passwords"])
    func deniedAppsCanNeverBeAllowed(bundleID: String) {
        let policy = AccessPolicy.build(picked: [bundleID, "com.apple.iphonesimulator"], allowFilePanels: false,
                                        agentHosts: [], denyAgentHosts: false)
        #expect(!policy.allows(bundleID: bundleID))
        #expect(policy.allows(bundleID: "com.apple.iphonesimulator"))
        // Even a policy built directly can't let one through.
        #expect(!AccessPolicy(allowedBundleIDs: [bundleID]).allows(bundleID: bundleID))
    }

    @Test func theAgentsTerminalIsDeniedByDefault() {
        let picked: Set = ["com.apple.Terminal", "com.apple.iphonesimulator"]
        let denied = AccessPolicy.build(picked: picked, allowFilePanels: false,
                                        agentHosts: ["com.apple.Terminal"], denyAgentHosts: true)
        #expect(!denied.allows(bundleID: "com.apple.Terminal"))
        let allowed = AccessPolicy.build(picked: picked, allowFilePanels: false,
                                         agentHosts: ["com.apple.Terminal"], denyAgentHosts: false)
        #expect(allowed.allows(bundleID: "com.apple.Terminal"))
    }

    @Test func filePanelsAreOptIn() {
        let off = AccessPolicy.build(picked: ["com.apple.TextEdit"], allowFilePanels: false, agentHosts: [],
                                     denyAgentHosts: true)
        #expect(!off.allows(bundleID: "com.apple.appkit.xpc.openAndSavePanelService"))
        let on = AccessPolicy.build(picked: ["com.apple.TextEdit"], allowFilePanels: true, agentHosts: [],
                                    denyAgentHosts: true)
        #expect(on.allows(bundleID: "com.apple.appkit.xpc.openAndSavePanelService"))
    }

    @Test func everyProcessOfAnAllowedAppCounts() {
        let policy = AccessPolicy(allowedBundleIDs: ["com.apple.iphonesimulator"])
        let resolver = FakeResolver(apps: [10: ("com.apple.iphonesimulator", "Simulator"),
                                           11: ("com.apple.iphonesimulator", "Simulator"),
                                           12: ("com.apple.Notes", "Notes")])
        #expect(policy.allows(pid: 10, resolver: resolver))
        #expect(policy.allows(pid: 11, resolver: resolver))
        #expect(!policy.allows(pid: 12, resolver: resolver))
        #expect(!policy.allows(pid: 99, resolver: resolver))   // unknown process
        #expect(!policy.allows(pid: getpid(), resolver: resolver))   // ClickRelay itself
    }

    @Test func missingBundleIDIsNeverAllowed() {
        let policy = AccessPolicy(allowedBundleIDs: [""])
        #expect(!policy.allows(bundleID: nil))
        #expect(!policy.allows(bundleID: ""))
    }

    @Test func terminalFromTermProgram() {
        #expect(Denylist.agentHostApps(termProgram: "iTerm.app", ancestorBundleIDs: []) == ["com.googlecode.iterm2"])
        #expect(Denylist.agentHostApps(termProgram: "Apple_Terminal", ancestorBundleIDs: ["dev.zed.Zed"])
                == ["com.apple.Terminal", "dev.zed.Zed"])
    }

    @Test func unknownTerminalDeniesEveryKnownOne() {
        let hosts = Denylist.agentHostApps(termProgram: "tmux", ancestorBundleIDs: [])
        #expect(hosts == Denylist.knownTerminals)
        #expect(hosts.contains("com.apple.Terminal"))
        #expect(hosts.contains("com.mitchellh.ghostty"))
    }

    @Test func clickRelayIsNeverItsOwnHost() {
        let hosts = Denylist.agentHostApps(termProgram: nil, ancestorBundleIDs: ["io.mergeable.ClickRelay", "com.apple.Terminal"])
        #expect(hosts == ["com.apple.Terminal"])
    }

    @Test func denylistReasons() {
        #expect(Denylist.reason(for: "io.mergeable.ClickRelay") != nil)
        #expect(Denylist.reason(for: "com.1password.1password") != nil)
        #expect(Denylist.reason(for: "com.apple.iphonesimulator") == nil)
    }
}
