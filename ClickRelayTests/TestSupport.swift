import CoreGraphics
import Foundation
@testable import ClickRelay

/// A clock tests move by hand.
final class FakeClock: LeaseClock, @unchecked Sendable {
    private let lock = NSLock()
    private let base = ContinuousClock.now
    private var offset: Duration = .zero

    var now: ContinuousClock.Instant {
        lock.withLock { base + offset }
    }

    func advance(_ duration: Duration) {
        lock.withLock { offset += duration }
    }
}

/// Answers every prompt with `outcome`, and counts them.
@MainActor
final class FakeAuthenticator: Authenticator {
    var outcome: AuthOutcome = .success
    private(set) var prompts: [(UnlockMethod, String)] = []

    func authenticate(method: UnlockMethod, reason: String) async -> AuthOutcome {
        prompts.append((method, reason))
        return outcome
    }
}

/// Processes made up for a test: PID → (bundle ID, name).
struct FakeResolver: ProcessResolver {
    var apps: [pid_t: (bundleID: String, name: String)]

    func bundleID(for pid: pid_t) -> String? { apps[pid]?.bundleID }
    func appName(for pid: pid_t) -> String? { apps[pid]?.name }
}

struct FakeCatalog: WindowCatalog {
    var windows: [WindowInfo]
    func snapshot() -> WindowSnapshot { WindowSnapshot(windows: windows) }
}

enum Fixtures {
    static let simulatorPID: pid_t = 101
    static let notesPID: pid_t = 202
    static let settingsPID: pid_t = 303
    static let terminalPID: pid_t = 404

    static let resolver = FakeResolver(apps: [
        simulatorPID: ("com.apple.iphonesimulator", "Simulator"),
        notesPID: ("com.apple.Notes", "Notes"),
        settingsPID: ("com.apple.systempreferences", "System Settings"),
        terminalPID: ("com.apple.Terminal", "Terminal")
    ])

    static func window(_ id: CGWindowID, pid: pid_t, frame: CGRect, layer: Int = 0, alpha: Double = 1,
                       title: String = "") -> WindowInfo {
        WindowInfo(id: id, pid: pid, ownerName: resolver.appName(for: pid) ?? "", title: title,
                   frame: frame, layer: layer, alpha: alpha)
    }

    static func session(_ id: String = "session-a", hosts: Set<String> = ["com.apple.Terminal"]) -> AgentSession {
        AgentSession(id: id, clientName: "Claude Code", workingDirectory: "/Users/me/xcode/Foo",
                     termProgram: "Apple_Terminal", parentPID: 1, hostBundleIDs: hosts, connectedAt: Date())
    }

    static func defaults() -> UserDefaults {
        let name = "ClickRelayTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
