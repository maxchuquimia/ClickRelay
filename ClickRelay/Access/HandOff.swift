import CoreGraphics
import Foundation
import Observation

/// An agent handing something to the user: a password, a CAPTCHA, a 2FA
/// code. While it's open the user has the Mac: every agent's input is paused,
/// and the app it's in can't be captured or read over Accessibility, so the
/// agent never sees what the user types.
nonisolated struct HandOff: Identifiable, Sendable, Equatable {
    let id: UUID
    let sessionID: String
    let windowID: CGWindowID
    let pid: pid_t
    let bundleID: String?
    let appName: String
    /// The agent's own words, shown in quotes.
    var message: String
    /// The element to point at, if the agent gave a ref.
    var element: AXElement?
    /// That element's frame relative to the window's top-left, in points.
    var elementFrame: CGRect?
    let createdAt: Date
    /// When the agent's current wait ends, if it's waiting.
    var deadline: Date?

    static func == (lhs: HandOff, rhs: HandOff) -> Bool {
        lhs.id == rhs.id && lhs.message == rhs.message && lhs.elementFrame == rhs.elementFrame
            && lhs.deadline == rhs.deadline && lhs.windowID == rhs.windowID
    }
}

/// How a hand-off ended, as far as the waiting call is concerned.
nonisolated enum HandOffAnswer: Sendable, Equatable {
    /// The user pressed Done, with an optional note for the agent.
    case done(note: String?)
    /// The user pressed Can't Do This.
    case cantDo(note: String?)
    /// This call's wait ran out. The hand-off stays open.
    case timedOut
    /// The window closed or its app quit.
    case windowClosed
    /// The session's lease ended.
    case locked
    /// The same session handed off a different window.
    case replaced
}

/// Open hand-offs, one per session at most. Nothing here creates, extends or
/// widens a lease: a hand-off only ever takes access away for a while.
@MainActor
@Observable
final class HandOffController {
    private(set) var handOffs: [String: HandOff] = [:]

    /// Something opened, changed or closed.
    @ObservationIgnored var onChanged: (() -> Void)?

    /// Answers the user gave while no call was waiting, for the agent's next
    /// `clickrelay_status` or `clickrelay_hand_off`.
    @ObservationIgnored private var unread: [String: (answer: HandOffAnswer, handOff: HandOff, at: Date)] = [:]
    @ObservationIgnored private var waiters: [UUID: [UUID: CheckedContinuation<HandOffAnswer, Never>]] = [:]

    var isAnyOpen: Bool { !handOffs.isEmpty }

    /// The open hand-off in this app, if any. Its whole app is off limits.
    func blocking(pid: pid_t) -> HandOff? {
        handOffs.values.first { $0.pid == pid }
    }

    var blockedPIDs: Set<pid_t> { Set(handOffs.values.map(\.pid)) }

    /// Opens a hand-off (or, for the same window, updates the open one and
    /// waits on it again) and waits up to `timeout` for the user.
    func start(_ handOff: HandOff, timeout: Duration) async -> HandOffAnswer {
        var current = handOff
        if let old = handOffs[handOff.sessionID] {
            if old.windowID == handOff.windowID {
                current = HandOff(id: old.id, sessionID: old.sessionID, windowID: old.windowID, pid: old.pid,
                                  bundleID: old.bundleID, appName: old.appName, message: handOff.message,
                                  element: handOff.element ?? old.element,
                                  elementFrame: handOff.elementFrame ?? old.elementFrame,
                                  createdAt: old.createdAt, deadline: nil)
            } else {
                resolve(old.id, with: .replaced)
            }
        }
        unread[handOff.sessionID] = nil
        let deadline = timeout > .zero ? Date().addingTimeInterval(Self.seconds(timeout)) : nil
        current.deadline = deadline
        handOffs[handOff.sessionID] = current
        onChanged?()
        guard timeout > .zero else { return .timedOut }

        let id = current.id
        let waiterID = UUID()
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.waiterTimedOut(handOffID: id, waiterID: waiterID)
        }
        return await withCheckedContinuation { continuation in
            waiters[id, default: [:]][waiterID] = continuation
        }
    }

    /// The user answered, or the hand-off can't go on. Closes it and tells
    /// whoever is waiting. An answer nobody was waiting for is kept for the
    /// agent's next call.
    func finish(sessionID: String, _ answer: HandOffAnswer) {
        guard let handOff = handOffs.removeValue(forKey: sessionID) else { return }
        onChanged?()
        let waiting = waiters.removeValue(forKey: handOff.id) ?? [:]
        if waiting.isEmpty, answer != .locked, answer != .replaced {
            unread[sessionID] = (answer, handOff, Date())
        }
        for waiter in waiting.values { waiter.resume(returning: answer) }
    }

    /// An answer the agent hasn't heard yet, which it hears only once.
    func takeUnread(sessionID: String) -> (answer: HandOffAnswer, handOff: HandOff, at: Date)? {
        unread.removeValue(forKey: sessionID)
    }

    func forget(sessionID: String) {
        unread[sessionID] = nil
    }

    /// Keeps the ring on the element as the page scrolls.
    func updateElementFrame(sessionID: String, _ frame: CGRect) {
        guard handOffs[sessionID] != nil, handOffs[sessionID]?.elementFrame != frame else { return }
        handOffs[sessionID]?.elementFrame = frame
        onChanged?()
    }

    private func waiterTimedOut(handOffID: UUID, waiterID: UUID) {
        guard let continuation = waiters[handOffID]?.removeValue(forKey: waiterID) else { return }
        if waiters[handOffID]?.isEmpty == true { waiters[handOffID] = nil }
        if let sessionID = handOffs.first(where: { $0.value.id == handOffID })?.key {
            handOffs[sessionID]?.deadline = nil
            onChanged?()
        }
        continuation.resume(returning: .timedOut)
    }

    private func resolve(_ handOffID: UUID, with answer: HandOffAnswer) {
        for waiter in (waiters.removeValue(forKey: handOffID) ?? [:]).values { waiter.resume(returning: answer) }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
