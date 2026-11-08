import CoreGraphics
import Foundation

/// Why input was refused. `check` names the check that failed (for the audit
/// log); `message` is written for the model: what failed and what to do.
nonisolated struct InputRefusal: Error, Equatable, Sendable {
    enum Check: String, Sendable {
        case window, frame, topmost, element, frontmost, focus, shortcut, lease, other
        case handOff = "hand_off"
    }

    let check: Check
    let message: String
}

/// The checks that run immediately before every coordinate event and every
/// keystroke. Pure: it takes a window snapshot and an element-at-point lookup,
/// and returns allow or a refusal, so each refusal can be unit-tested.
nonisolated struct InputGuard: Sendable {
    let policy: AccessPolicy
    let resolver: ProcessResolver
    /// ClickRelay's own click-through overlay windows, which sit on top of
    /// everything but never receive a click.
    var ignoredWindowIDs: Set<CGWindowID> = []
    /// ClickRelay's own process, whose alert panels can cover a window.
    var ownPID: pid_t = ProcessInfo.processInfo.processIdentifier

    /// The four checks for a point given in a window:
    ///
    /// 1. The window still exists, belongs to an allowed app, and is on screen.
    /// 2. The point is inside that window's frame.
    /// 3. The topmost window at that point is that window (or another of the
    ///    same app's, like its own menu), so another app covering it blocks it.
    /// 4. The Accessibility element at that point belongs to an allowed app.
    ///
    /// - Parameters:
    ///   - point: global screen point (top-left origin).
    ///   - elementPID: the owning process of the Accessibility element at a
    ///     point, or nil if it couldn't be read.
    func checkPoint(windowID: CGWindowID, point: CGPoint, snapshot: WindowSnapshot,
                    elementPID: (CGPoint) -> pid_t?) -> Result<WindowInfo, InputRefusal> {
        // 1. Window exists, is on screen, is allowed.
        guard let window = snapshot.window(windowID) else {
            return .failure(InputRefusal(check: .window, message:
                "Window \(windowID) isn't on screen (it was closed, minimised or is on another Space). "
                + "Call clickrelay_list_windows for the current windows."))
        }
        guard policy.allows(pid: window.pid, resolver: resolver) else {
            let app = appName(window.pid, fallback: window.ownerName)
            return .failure(InputRefusal(check: .window, message:
                "Window \(windowID) belongs to \(app), which isn't allowed. Use a window from an allowed "
                + "app, or ask the user to allow \(app)."))
        }

        // 2. Inside the frame.
        let local = CGPoint(x: point.x - window.frame.minX, y: point.y - window.frame.minY)
        guard window.frame.contains(point) else {
            return .failure(InputRefusal(check: .frame, message:
                "The point \(Self.format(local)) is outside window \(windowID), which is "
                + "\(Self.format(window.frame.width)) × \(Self.format(window.frame.height)) points. "
                + "Coordinates are window points from its top-left corner."))
        }

        // 3. Nothing from another app on top.
        guard let top = snapshot.topmost(at: point, ignoring: ignoredWindowIDs) else {
            return .failure(InputRefusal(check: .topmost, message:
                "ClickRelay couldn't tell which window is at \(Self.format(local)), so it refused. "
                + "Take a new screenshot and try again."))
        }
        if top.id != window.id && top.pid != window.pid {
            if top.pid == ownPID {
                // An alert or hand-off callout. Focusing the window won't
                // move it, so don't suggest that.
                return .failure(InputRefusal(check: .topmost, message:
                    "The point \(Self.format(local)) in window \(windowID) is under one of ClickRelay's own "
                    + "panels, which you can't click through. Use clickrelay_press with a ref from "
                    + "clickrelay_find_elements, which doesn't need the spot to be visible."))
            }
            let app = appName(top.pid, fallback: top.ownerName)
            if policy.allows(pid: top.pid, resolver: resolver) {
                return .failure(InputRefusal(check: .topmost, message:
                    "The point \(Self.format(local)) in window \(windowID) is covered by a window from "
                    + "\(app). Bring window \(windowID) to the front with clickrelay_focus_window and click again, "
                    + "or use that window's own window_id if you meant it."))
            }
            return .failure(InputRefusal(check: .topmost, message:
                "The point \(Self.format(local)) is covered by a window from \(app), which isn't allowed. "
                + "Bring window \(windowID) to the front with clickrelay_focus_window and click again."))
        }

        // 4. The element under the point is an allowed app's.
        guard let pid = elementPID(point) else {
            return .failure(InputRefusal(check: .element, message:
                "ClickRelay couldn't confirm with Accessibility what's at \(Self.format(local)), so it "
                + "refused. Try clickrelay_press with a ref from clickrelay_find_elements instead."))
        }
        guard policy.allows(pid: pid, resolver: resolver) else {
            let app = appName(pid, fallback: "another app")
            return .failure(InputRefusal(check: .element, message:
                "The element at \(Self.format(local)) belongs to \(app), which isn't allowed. "
                + "Ask the user to allow \(app) if it should be."))
        }
        return .success(window)
    }

    /// Keyboard input needs the frontmost app to be allowed.
    func checkKeyboard(frontmostPID: pid_t?) -> InputRefusal? {
        guard let frontmostPID else {
            return InputRefusal(check: .frontmost, message:
                "No app is frontmost, so there's nowhere to type. Call clickrelay_focus_window first.")
        }
        guard policy.allows(pid: frontmostPID, resolver: resolver) else {
            let app = appName(frontmostPID, fallback: "an app")
            return InputRefusal(check: .frontmost, message:
                "Keyboard input goes to the frontmost app, \(app), which isn't allowed. Call "
                + "clickrelay_focus_window on an allowed app's window first.")
        }
        return nil
    }

    /// An Accessibility element acted on by ref must belong to an allowed app.
    func checkElement(pid: pid_t) -> InputRefusal? {
        guard policy.allows(pid: pid, resolver: resolver) else {
            let app = appName(pid, fallback: "another app")
            return InputRefusal(check: .element, message:
                "That element belongs to \(app), which isn't allowed.")
        }
        return nil
    }

    private func appName(_ pid: pid_t, fallback: String) -> String {
        resolver.appName(for: pid) ?? (fallback.isEmpty ? "another app" : fallback)
    }

    static func format(_ value: CGFloat) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", Double(value))
    }

    static func format(_ point: CGPoint) -> String {
        "(\(format(point.x)), \(format(point.y)))"
    }
}
