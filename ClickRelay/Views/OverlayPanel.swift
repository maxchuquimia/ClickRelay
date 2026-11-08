import AppKit

/// While unlocked: a click-through, borderless panel per screen at
/// `.screenSaver` level, drawing a border in the app icon's gradient around
/// each allowed window the agent has used since the unlock (or around the
/// screen it used), plus short highlights where clicks land.
///
/// A border appears with the agent's first call in that window, pulses to
/// full strength on every call after, and fades back to a faint outline in
/// between. It's drawn only where the window is visible: wherever another
/// window covers it, so does the border.
///
/// ClickRelay is never included in a capture filter, so these panels never
/// appear in screenshots; their window numbers are also ignored by the
/// topmost-window check, since they never take a click.
@MainActor
final class OverlayController {
    private let preferences: Preferences
    private let catalog: WindowCatalog
    private let resolver: ProcessResolver
    private var panels: [OverlayPanel] = []
    private var timer: Timer?
    private var timerInterval: TimeInterval = 0
    private var allowed: Set<String> = []
    private var clicks: [(point: CGPoint, date: Date)] = []
    /// When the agent last acted in each window, since the unlock.
    private var windowActivity: [CGWindowID: Activity] = [:]
    /// The same per display, for the screen-border style.
    private var screenActivity: [CGDirectDisplayID: Activity] = [:]
    /// The window the agent used last, which carries the tag.
    private var lastWindow: CGWindowID?
    /// Text for the tab on the window the agent used last, by bundle ID:
    /// who can use it and the time left.
    var tagProvider: ((String) -> String?)?

    /// Where it's the user's turn: a window, and optionally an element's
    /// frame relative to the window's top-left.
    struct HandOffRing: Equatable {
        let windowID: CGWindowID
        let elementFrame: CGRect?
    }

    /// Open hand-offs. Each gets a steady teal ring, and the agent's border on
    /// that window drops to a faint outline with a "paused" tab.
    var handOffRings: [HandOffRing] = [] {
        didSet { if handOffRings != oldValue { refresh() } }
    }

    /// The user's turn (#0E9384).
    nonisolated static let handOffColor = NSColor(srgbRed: 0.055, green: 0.576, blue: 0.518, alpha: 1)
    static let pausedAlpha: CGFloat = 0.25

    static let borderWidth: CGFloat = 4
    /// The app icon's gradient, top to bottom.
    static let topColor = NSColor(srgbRed: 1.0, green: 0.541, blue: 0.239, alpha: 1)      // #FF8A3D
    static let bottomColor = NSColor(srgbRed: 0.851, green: 0.204, blue: 0.169, alpha: 1)  // #D9342B
    static let midColor = topColor.blended(withFraction: 0.5, of: bottomColor) ?? topColor
    static var gradient: NSGradient { NSGradient(starting: topColor, ending: bottomColor)! }

    /// How a border's strength follows a call: up to full quickly, a pause,
    /// then a slow fade to the resting outline.
    struct Activity {
        let start: Date
        /// Strength when the call came in, so back-to-back calls don't flicker.
        let from: CGFloat

        static let rise: TimeInterval = 0.2
        static let hold: TimeInterval = 1.5
        static let fade: TimeInterval = 6
        static let resting: CGFloat = 0.1

        func alpha(at now: Date) -> CGFloat {
            let t = now.timeIntervalSince(start)
            if t < 0 { return from }
            if t < Self.rise { return from + (1 - from) * Self.ease(t / Self.rise) }
            if t < Self.rise + Self.hold { return 1 }
            let fading = t - Self.rise - Self.hold
            if fading < Self.fade { return 1 - (1 - Self.resting) * Self.ease(fading / Self.fade) }
            return Self.resting
        }

        func isAnimating(at now: Date) -> Bool {
            now.timeIntervalSince(start) < Self.rise + Self.hold + Self.fade
        }

        private static func ease(_ x: Double) -> CGFloat {
            let x = min(1, max(0, x))
            return CGFloat(x * x * (3 - 2 * x))
        }
    }

    init(preferences: Preferences, catalog: WindowCatalog = SystemWindowCatalog(),
         resolver: ProcessResolver = SystemProcessResolver()) {
        self.preferences = preferences
        self.catalog = catalog
        self.resolver = resolver
    }

    /// Window numbers of the overlay panels.
    var windowIDs: Set<CGWindowID> {
        Set(panels.map { CGWindowID($0.windowNumber) })
    }

    func update(allowedBundleIDs: Set<String>) {
        allowed = allowedBundleIDs
        if allowed.isEmpty {
            setTimer(interval: nil)
            for panel in panels { panel.orderOut(nil) }
            panels = []
            clicks = []
            windowActivity = [:]
            screenActivity = [:]
            lastWindow = nil
            return
        }
        rebuildPanelsIfNeeded()
        refresh()
    }

    /// An agent's call succeeded. `windowID` when the call named a window;
    /// otherwise `bundleID`'s frontmost window (keyboard input), or every
    /// allowed window on the main display (a full-display screenshot).
    func noteAction(windowID: CGWindowID?, bundleID: String?, wholeDisplay: Bool) {
        guard !allowed.isEmpty else { return }
        let snapshot = catalog.snapshot()
        let policy = AccessPolicy(allowedBundleIDs: allowed)
        let visible = snapshot.windows.filter {
            $0.isAppWindow && $0.layer == 0 && policy.allows(pid: $0.pid, resolver: resolver)
        }
        var touched: [WindowInfo] = []
        if let windowID, let window = snapshot.window(windowID) {
            touched = [window]
        } else if wholeDisplay {
            let main = CGDisplayBounds(CGMainDisplayID())
            touched = visible.filter { $0.frame.intersects(main) }
        } else if let bundleID, let front = visible.first(where: { resolver.bundleID(for: $0.pid) == bundleID }) {
            touched = [front]
        }
        let now = Date()
        for window in touched {
            windowActivity[window.id] = Activity(start: now, from: windowActivity[window.id]?.alpha(at: now) ?? 0)
        }
        var displays = Set(touched.compactMap { Self.display(containing: $0.frame) })
        if wholeDisplay { displays.insert(CGMainDisplayID()) }
        for display in displays {
            screenActivity[display] = Activity(start: now, from: screenActivity[display]?.alpha(at: now) ?? 0)
        }
        if let first = touched.first { lastWindow = first.id }
        refresh()
    }

    func flashClick(at point: CGPoint) {
        guard !allowed.isEmpty else { return }
        clicks.append((point, Date()))
        refresh()
    }

    private static func display(containing rect: CGRect) -> CGDirectDisplayID? {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard CGGetDisplaysWithPoint(center, 1, &display, &count) == .success, count > 0 else { return nil }
        return display
    }

    private func rebuildPanelsIfNeeded() {
        let screens = NSScreen.screens
        if panels.count == screens.count, zip(panels, screens).allSatisfy({ $0.frame == $1.frame }) { return }
        for panel in panels { panel.orderOut(nil) }
        panels = screens.map(OverlayPanel.init(screen:))
        for panel in panels { panel.orderFrontRegardless() }
    }

    /// 30 Hz while something is moving, 10 Hz to follow windows otherwise,
    /// and nothing when locked.
    private func setTimer(interval: TimeInterval?) {
        guard interval != (timer == nil ? nil : timerInterval) else { return }
        timer?.invalidate()
        timer = nil
        guard let interval else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        timerInterval = interval
    }

    private func refresh() {
        guard !allowed.isEmpty else { return }
        rebuildPanelsIfNeeded()
        let now = Date()
        // Global top-left space → AppKit bottom-left space.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        func cocoa(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        }

        var borders: [OverlayView.Border] = []
        let rings = Dictionary(handOffRings.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        let showBorders = preferences.indicatorStyle == .windows && !windowActivity.isEmpty
        if showBorders || !rings.isEmpty {
            let policy = AccessPolicy(allowedBundleIDs: allowed)
            let ignore = windowIDs
            let windows = catalog.snapshot().windows.filter { !ignore.contains($0.id) }
            // The tag goes on the window used last, or failing that the
            // frontmost one used at all.
            let tagged = windows.first { $0.id == lastWindow && $0.layer == 0 }
                ?? windows.first { windowActivity[$0.id] != nil && $0.layer == 0 }
            // Back to front, so each border is cleared where windows in front
            // of it are, before those draw their own.
            for (index, window) in windows.enumerated().reversed() {
                guard window.isAppWindow, window.layer == 0 else { continue }
                let ring = rings[window.id]
                let activity = showBorders && policy.allows(pid: window.pid, resolver: resolver)
                    ? windowActivity[window.id] : nil
                guard activity != nil || ring != nil else { continue }
                let covering = windows[..<index]
                    .filter { $0.isAppWindow && $0.alpha > 0.01 && $0.frame.intersects(window.frame.insetBy(dx: -24, dy: -24)) }
                    .map { cocoa($0.frame) }
                var tag: String?
                if activity != nil, window.id == tagged?.id, let id = resolver.bundleID(for: window.pid) {
                    tag = ring == nil ? tagProvider?(id) : "Paused while it's your turn"
                }
                var ringRect: CGRect?
                if let ring {
                    let target = ring.elementFrame
                        .map { $0.offsetBy(dx: window.frame.minX, dy: window.frame.minY).intersection(window.frame) }
                        .flatMap { $0.isNull || $0.width < 2 || $0.height < 2 ? nil : $0 }
                    ringRect = cocoa(target ?? window.frame)
                }
                let alpha = activity.map { ring == nil ? $0.alpha(at: now) : Self.pausedAlpha } ?? 0
                borders.append(.init(rect: cocoa(window.frame), alpha: alpha, covering: covering, tag: tag,
                                     ring: ringRect))
            }
        }
        clicks.removeAll { now.timeIntervalSince($0.date) > 0.6 }
        let clickPoints = clicks.map { (cocoa(CGRect(origin: $0.point, size: .zero)).origin, now.timeIntervalSince($0.date)) }

        for panel in panels {
            let origin = panel.frame.origin
            let view = panel.overlayView
            view.screenAlpha = preferences.indicatorStyle == .screen
                ? screenActivity[panel.displayID].map { $0.alpha(at: now) } : nil
            view.borders = borders.compactMap { border in
                let local = border.rect.offsetBy(dx: -origin.x, dy: -origin.y)
                guard local.insetBy(dx: -40, dy: -40).intersects(view.bounds) else { return nil }
                return .init(rect: local, alpha: border.alpha,
                             covering: border.covering.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) },
                             tag: border.tag, ring: border.ring?.offsetBy(dx: -origin.x, dy: -origin.y))
            }
            view.clicks = clickPoints.map { (CGPoint(x: $0.0.x - origin.x, y: $0.0.y - origin.y), $0.1) }
            view.needsDisplay = true
        }

        let animating = !clicks.isEmpty
            || windowActivity.values.contains { $0.isAnimating(at: now) }
            || screenActivity.values.contains { $0.isAnimating(at: now) }
        let idle = windowActivity.isEmpty && screenActivity.isEmpty && clicks.isEmpty && handOffRings.isEmpty
        setTimer(interval: animating ? 1.0 / 30 : idle ? nil : 0.1)
    }
}

final class OverlayPanel: NSPanel {
    let overlayView: OverlayView
    let displayID: CGDirectDisplayID

    init(screen: NSScreen) {
        overlayView = OverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
        displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            ?? CGMainDisplayID()
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        sharingType = .none
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        contentView = overlayView
        setFrame(screen.frame, display: false)
        // Never a hit-test target for Accessibility, so InputGuard's element
        // check sees the app underneath.
        setAccessibilityElement(false)
        overlayView.setAccessibilityElement(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class OverlayView: NSView {
    struct Border {
        /// The window's frame, in this view's coordinates.
        let rect: CGRect
        let alpha: CGFloat
        /// Windows in front of it, where nothing of it should show.
        let covering: [CGRect]
        /// The tab text, on the window used last.
        let tag: String?
        /// A hand-off ring, around the window or one element in it.
        var ring: CGRect? = nil
    }

    /// Back to front.
    var borders: [Border] = []
    /// The screen border's strength, or nil for none.
    var screenAlpha: CGFloat?
    var clicks: [(CGPoint, TimeInterval)] = []

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let width = OverlayController.borderWidth
        if let screenAlpha {
            stroke(NSBezierPath(rect: bounds.insetBy(dx: width / 2, dy: width / 2)), alpha: screenAlpha,
                   in: context)
        }
        for border in borders {
            if border.alpha > 0 {
                let path = NSBezierPath(roundedRect: border.rect.insetBy(dx: -width / 2, dy: -width / 2),
                                        xRadius: 10, yRadius: 10)
                stroke(path, alpha: border.alpha, in: context)
            }
            if let tag = border.tag {
                drawTag(tag, above: border.rect, borderWidth: width, alpha: max(border.alpha, 0.6),
                        color: border.ring == nil ? OverlayController.topColor : .systemGray, in: context)
            }
            if let ring = border.ring {
                // Steady, not pulsing: the agent has stopped and it's the user's turn.
                let path = NSBezierPath(roundedRect: ring.insetBy(dx: -5, dy: -5), xRadius: 7, yRadius: 7)
                path.lineWidth = 3
                OverlayController.handOffColor.setStroke()
                path.stroke()
            }
            // Wipe out whatever of it sits under windows in front.
            for rect in border.covering {
                rect.intersection(bounds).fill(using: .clear)
            }
        }
        for (point, age) in clicks {
            let progress = CGFloat(min(1, age / 0.6))
            let radius = 8 + 18 * progress
            OverlayController.midColor.withAlphaComponent(0.9 * (1 - progress)).setStroke()
            let ring = NSBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                   width: radius * 2, height: radius * 2))
            ring.lineWidth = 3
            ring.stroke()
        }
    }

    /// Strokes `path` with the icon gradient, top to bottom.
    private func stroke(_ path: NSBezierPath, alpha: CGFloat, in context: CGContext) {
        let outline = path.cgPath.copy(strokingWithWidth: OverlayController.borderWidth,
                                       lineCap: .butt, lineJoin: .round, miterLimit: 10)
        context.saveGState()
        context.setAlpha(alpha)
        OverlayController.gradient.draw(in: NSBezierPath(cgPath: outline), angle: -90)
        context.restoreGState()
    }

    /// A small tab on the window's top edge. Moves inside the border when
    /// there's no room above (the window touches the top of the screen).
    private func drawTag(_ text: String, above rect: CGRect, borderWidth: CGFloat, alpha: CGFloat,
                         color: NSColor, in context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        let height = size.height + 4
        let width = min(size.width + 16, max(40, rect.width - 20))
        let outsideY = rect.maxY + borderWidth / 2
        let y = outsideY + height <= bounds.maxY ? outsideY : rect.maxY - borderWidth / 2 - height
        let tab = CGRect(x: rect.minX + 10, y: y, width: width, height: height)
        context.saveGState()
        context.setAlpha(alpha)
        // Flat, in the gradient's top colour: the tab sits on the border's top
        // edge, so it reads as part of it.
        color.setFill()
        NSBezierPath(roundedRect: tab, xRadius: 5, yRadius: 5).fill()
        let clip = tab.insetBy(dx: 8, dy: 2)
        (text as NSString).draw(with: clip, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin],
                                attributes: attributes)
        context.restoreGState()
    }
}
