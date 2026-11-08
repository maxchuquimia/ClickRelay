import AppKit
import ApplicationServices
import CoreGraphics

/// The two grants ClickRelay holds on the agent's behalf. Checked when the app
/// becomes active; Unlock is disabled while either is missing.
nonisolated struct Permissions: Equatable, Sendable {
    var screenRecording: Bool
    var accessibility: Bool

    static var current: Permissions {
        Permissions(screenRecording: CGPreflightScreenCaptureAccess(), accessibility: AXIsProcessTrusted())
    }

    var allGranted: Bool { screenRecording && accessibility }

    var missing: [String] {
        var names: [String] = []
        if !screenRecording { names.append("Screen Recording") }
        if !accessibility { names.append("Accessibility") }
        return names
    }

    /// Shows the system prompt (first time only; after that macOS just
    /// returns false and the user has to use System Settings).
    @MainActor
    static func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() { openSettings(.screenRecording) }
    }

    @MainActor
    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) { openSettings(.accessibility) }
    }

    enum Pane: String {
        case screenRecording = "Privacy_ScreenCapture"
        case accessibility = "Privacy_Accessibility"
    }

    @MainActor
    static func openSettings(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }
}
