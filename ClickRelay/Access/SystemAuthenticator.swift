import AppKit
import LocalAuthentication
import Observation
@preconcurrency import UserNotifications

/// A pending press-and-hold on the Authorize button.
struct AuthorizationPrompt: Identifiable, Equatable {
    let id = UUID()
    let reason: String
}

/// Confirms a person is at the Mac: Touch ID (optionally accepting the login
/// password) through LocalAuthentication, or the human-only Authorize button
/// in ClickRelay's own window.
@MainActor
@Observable
final class SystemAuthenticator: Authenticator {
    /// Shown as a sheet in the main window while set.
    private(set) var pendingAuthorization: AuthorizationPrompt?
    @ObservationIgnored private var authorizationContinuation: CheckedContinuation<AuthOutcome, Never>?

    func authenticate(method: UnlockMethod, reason: String) async -> AuthOutcome {
        switch method {
        case .touchID:
            return await evaluate(.deviceOwnerAuthenticationWithBiometrics, reason: reason)
        case .touchIDOrPassword:
            return await evaluate(.deviceOwnerAuthentication, reason: reason)
        case .authorizeButton:
            return await askForAuthorizeButton(reason: reason)
        }
    }

    private func evaluate(_ policy: LAPolicy, reason: String) async -> AuthOutcome {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(policy, error: &error) else {
            let detail = error?.localizedDescription ?? "Touch ID isn't available"
            return .failed("\(detail). Pick another unlock method in Settings.")
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(policy, localizedReason: reason) { success, error in
                if success {
                    continuation.resume(returning: .success)
                } else if let error = error as? LAError,
                          [.userCancel, .systemCancel, .appCancel].contains(error.code) {
                    continuation.resume(returning: .cancelled)
                } else {
                    continuation.resume(returning: .failed(error?.localizedDescription ?? "Not confirmed"))
                }
            }
        }
    }

    private func askForAuthorizeButton(reason: String) async -> AuthOutcome {
        // Only one prompt at a time; a second request cancels the first.
        finishAuthorization(.cancelled)
        AppModel.shared.showMainWindow(activate: true)
        pendingAuthorization = AuthorizationPrompt(reason: reason)
        return await withCheckedContinuation { continuation in
            authorizationContinuation = continuation
        }
    }

    /// Called by the Authorize sheet: after a completed hold, or on Cancel.
    func finishAuthorization(_ outcome: AuthOutcome) {
        pendingAuthorization = nil
        authorizationContinuation?.resume(returning: outcome)
        authorizationContinuation = nil
    }
}

/// The notification 60 seconds before a lease ends, with an Extend action
/// that needs the unlock method again.
@MainActor
final class ExpiryNotifier: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let categoryID = "lease-expiring"
    nonisolated static let extendActionID = "extend"
    nonisolated static let lockActionID = "lock"
    nonisolated static let sessionKey = "session"

    /// Called with the session ID when the user picks Extend.
    var onExtend: ((String) -> Void)?
    /// Called with the session ID when the user picks Lock.
    var onLock: ((String) -> Void)?
    private var authorizationRequested = false

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let extend = UNNotificationAction(identifier: Self.extendActionID, title: "Extend", options: [.foreground])
        let lock = UNNotificationAction(identifier: Self.lockActionID, title: "Lock", options: [])
        let category = UNNotificationCategory(identifier: Self.categoryID, actions: [extend, lock],
                                              intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }

    /// Asked at the first unlock rather than at launch, so a new user isn't
    /// greeted with a prompt.
    func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyExpiring(sessionID: String, agent: String, apps: [String], until: Date, extendMinutes: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Locking in 1 minute"
        let time = until.formatted(date: .omitted, time: .shortened)
        content.body = "\(agent) can use \(AppModel.list(apps)) until \(time). Extend adds \(AppModel.shortDuration(minutes: extendMinutes))."
        content.categoryIdentifier = Self.categoryID
        content.userInfo = [Self.sessionKey: sessionID]
        let request = UNNotificationRequest(identifier: "expiring-\(sessionID)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func clear(sessionID: String) {
        let id = "expiring-\(sessionID)"
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let session = response.notification.request.content.userInfo[Self.sessionKey] as? String
        completionHandler()
        guard let session else { return }
        switch action {
        case Self.extendActionID: Task { @MainActor in self.onExtend?(session) }
        case Self.lockActionID: Task { @MainActor in self.onLock?(session) }
        default: break
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
