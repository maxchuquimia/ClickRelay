import Foundation
import LocalAuthentication
import Observation

nonisolated enum IndicatorStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A border around each allowed app's visible windows.
    case windows
    /// A border around the whole screen.
    case screen

    var id: String { rawValue }
    var label: String { self == .windows ? "Border around allowed windows" : "Border around the screen" }
}

/// App-wide settings, in `UserDefaults`. Observable so views and services
/// react to changes. Locking on screen lock and sleep isn't here: it's always
/// on.
@MainActor
@Observable
final class Preferences {
    @ObservationIgnored private let defaults: UserDefaults

    /// The last lease duration used, in minutes. Highlighted in the unlock
    /// screen and used by Extend.
    var leaseDurationMinutes: Int { didSet { defaults.set(leaseDurationMinutes, forKey: Key.duration) } }
    var unlockMethod: UnlockMethod { didSet { defaults.set(unlockMethod.rawValue, forKey: Key.method) } }
    /// How long a call made while locked waits for an unlock. 0 means it
    /// fails at once.
    var unlockWaitSeconds: Int { didSet { defaults.set(unlockWaitSeconds, forKey: Key.wait) } }
    /// 0 means off.
    var idleLockMinutes: Int { didSet { defaults.set(idleLockMinutes, forKey: Key.idle) } }
    var killShortcut: KeyCombo {
        didSet { defaults.set(try? JSONEncoder().encode(killShortcut), forKey: Key.kill) }
    }
    var indicatorStyle: IndicatorStyle { didSet { defaults.set(indicatorStyle.rawValue, forKey: Key.indicator) } }
    var showClickHighlights: Bool { didSet { defaults.set(showClickHighlights, forKey: Key.highlights) } }
    var screenshotMaxEdge: Int { didSet { defaults.set(screenshotMaxEdge, forKey: Key.maxEdge) } }
    var allowFilePanels: Bool { didSet { defaults.set(allowFilePanels, forKey: Key.filePanels) } }
    var auditRetentionDays: Int { didSet { defaults.set(auditRetentionDays, forKey: Key.retention) } }
    /// Keep `clickrelay_type` text in the audit log instead of its length.
    var keepTypedText: Bool { didSet { defaults.set(keepTypedText, forKey: Key.keepText) } }
    /// Whether the user has answered macOS's "bypass the private window
    /// picker" prompt with Allow, as far as ClickRelay can tell (a capture
    /// succeeded). macOS can ask again later; a failed capture clears it.
    var directCaptureConfirmed: Bool { didSet { defaults.set(directCaptureConfirmed, forKey: Key.directCapture) } }
    /// The first-run checklist was closed with Done.
    var setupFinished: Bool { didSet { defaults.set(setupFinished, forKey: Key.setupFinished) } }
    /// A bridge has connected at least once, so the agent was set up.
    var hasConnectedAgent: Bool { didSet { defaults.set(hasConnectedAgent, forKey: Key.connected) } }
    /// The last set of allowed apps, ticked again at the next unlock and kept
    /// in the unlock list even when they aren't running.
    var lastAllowedApps: [String] { didSet { defaults.set(lastAllowedApps, forKey: Key.lastApps) } }
    /// Per-app keyboard delivery, by bundle ID. Missing means the built-in
    /// default (`InputDelivery.builtInGlobal`, else Targeted).
    var inputDelivery: [String: String] { didSet { defaults.set(inputDelivery, forKey: Key.delivery) } }

    static let durationChoices = [5, 15, 30, 60]
    static let waitChoices = [0, 10, 30, 60, 120]
    static let idleChoices = [0, 2, 5, 10, 15, 30]
    static let retentionChoices = [1, 7, 30, 90]
    static let maxEdgeChoices = [1024, 1280, 1568, 2048, 2560]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        leaseDurationMinutes = defaults.object(forKey: Key.duration) as? Int ?? 5
        unlockMethod = (defaults.string(forKey: Key.method)).flatMap(UnlockMethod.init(rawValue:))
            ?? (Self.hasBiometrics ? .touchID : .authorizeButton)
        unlockWaitSeconds = defaults.object(forKey: Key.wait) as? Int ?? 30
        idleLockMinutes = defaults.object(forKey: Key.idle) as? Int ?? 0
        killShortcut = defaults.data(forKey: Key.kill).flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) }
            ?? .defaultKill
        indicatorStyle = defaults.string(forKey: Key.indicator).flatMap(IndicatorStyle.init(rawValue:)) ?? .windows
        showClickHighlights = defaults.object(forKey: Key.highlights) as? Bool ?? true
        screenshotMaxEdge = defaults.object(forKey: Key.maxEdge) as? Int ?? 1568
        allowFilePanels = defaults.object(forKey: Key.filePanels) as? Bool ?? false
        auditRetentionDays = defaults.object(forKey: Key.retention) as? Int ?? 7
        keepTypedText = defaults.object(forKey: Key.keepText) as? Bool ?? false
        directCaptureConfirmed = defaults.object(forKey: Key.directCapture) as? Bool ?? false
        let connected = defaults.object(forKey: Key.connected) as? Bool ?? false
        hasConnectedAgent = connected
        // Installs from before the checklist existed have already set up.
        setupFinished = defaults.object(forKey: Key.setupFinished) as? Bool
            ?? (defaults.object(forKey: Key.directCapture) as? Bool ?? false || connected)
        lastAllowedApps = defaults.stringArray(forKey: Key.lastApps) ?? []
        inputDelivery = defaults.dictionary(forKey: Key.delivery) as? [String: String] ?? [:]
    }

    var leaseDuration: Duration { .seconds(max(1, leaseDurationMinutes) * 60) }
    var unlockWait: Duration { .seconds(max(0, unlockWaitSeconds)) }
    var idleTimeout: Duration? { idleLockMinutes > 0 ? .seconds(idleLockMinutes * 60) : nil }

    func delivery(for bundleID: String) -> InputDelivery {
        if let raw = inputDelivery[bundleID], let delivery = InputDelivery(rawValue: raw) { return delivery }
        return InputDelivery.builtInGlobal.contains(bundleID) ? .global : .targeted
    }

    func setDelivery(_ delivery: InputDelivery, for bundleID: String) {
        let builtIn: InputDelivery = InputDelivery.builtInGlobal.contains(bundleID) ? .global : .targeted
        inputDelivery[bundleID] = delivery == builtIn ? nil : delivery.rawValue
    }

    static var hasBiometrics: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    private enum Key {
        static let duration = "leaseDurationMinutes"
        static let method = "unlockMethod"
        static let wait = "unlockWaitSeconds"
        static let idle = "idleLockMinutes"
        static let kill = "killShortcut"
        static let indicator = "indicatorStyle"
        static let highlights = "showClickHighlights"
        static let maxEdge = "screenshotMaxEdge"
        static let filePanels = "allowFilePanels"
        static let retention = "auditRetentionDays"
        static let keepText = "keepTypedText"
        static let directCapture = "directCaptureConfirmed"
        static let setupFinished = "setupFinished"
        static let connected = "hasConnectedAgent"
        static let lastApps = "lastAllowedApps"
        static let delivery = "inputDelivery"
    }
}
