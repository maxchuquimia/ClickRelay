import AppKit
import CoreGraphics

/// One on-screen window, from the window server's list.
///
/// Frames are in global screen points with the origin at the top-left of the
/// main display and y growing downwards: the space `CGEvent`, Accessibility
/// and ScreenCaptureKit all use. Only AppKit (`NSWindow`, `NSScreen`) differs.
nonisolated struct WindowInfo: Sendable, Equatable, Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let ownerName: String
    let title: String
    let frame: CGRect
    let layer: Int
    let alpha: Double

    /// Layer 0 is ordinary app windows; floating panels and modal panels sit
    /// a little above. Menus, the Dock and the menu bar are far higher.
    var isAppWindow: Bool { layer >= 0 && layer < 20 && frame.width >= 2 && frame.height >= 2 }
}

/// Every on-screen window, front to back, at one moment. The input checks run
/// against a fresh snapshot taken just before each event.
nonisolated struct WindowSnapshot: Sendable, Equatable {
    let windows: [WindowInfo]

    func window(_ id: CGWindowID) -> WindowInfo? {
        windows.first { $0.id == id }
    }

    /// The window that would receive a click at `point`: the frontmost one
    /// containing it. Fully transparent windows are skipped (they're drawn
    /// with nothing and don't take clicks), as are `ignoring` (ClickRelay's
    /// own click-through overlay).
    func topmost(at point: CGPoint, ignoring: Set<CGWindowID> = []) -> WindowInfo? {
        windows.first { window in
            !ignoring.contains(window.id) && window.alpha > 0.01 && window.frame.contains(point)
        }
    }
}

/// Where window snapshots come from. A protocol so `InputGuard` can be tested
/// with made-up window layouts.
protocol WindowCatalog: Sendable {
    func snapshot() -> WindowSnapshot
}

/// The real window list, from `CGWindowListCopyWindowInfo`. Titles need Screen
/// Recording, which the app holds.
nonisolated struct SystemWindowCatalog: WindowCatalog {
    func snapshot() -> WindowSnapshot {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return WindowSnapshot(windows: [])
        }
        return WindowSnapshot(windows: list.compactMap(Self.window))
    }

    static func window(_ entry: [String: Any]) -> WindowInfo? {
        guard let number = entry[kCGWindowNumber as String] as? NSNumber,
              let pid = entry[kCGWindowOwnerPID as String] as? NSNumber,
              let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
        return WindowInfo(
            id: CGWindowID(number.uint32Value),
            pid: pid_t(pid.int32Value),
            ownerName: entry[kCGWindowOwnerName as String] as? String ?? "",
            title: entry[kCGWindowName as String] as? String ?? "",
            frame: frame,
            layer: (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
            alpha: (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)
    }
}
