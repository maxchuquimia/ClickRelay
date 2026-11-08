import AppKit
import SwiftUI

/// The Authorize button: an unlock without biometrics, safe only as long as
/// nothing automated can press it. So it:
///
/// - ignores Accessibility presses (`accessibilityPerformPress` returns false);
/// - ignores synthetic clicks: the event must come from the HID system state
///   and carry no source process (events posted with `CGEvent` carry their
///   poster's PID and their own source state);
/// - ignores the keyboard: no key equivalent, not default, not in the key loop;
/// - needs a one-second press-and-hold, with a progress ring, so a single
///   stray or posted click doesn't count.
///
/// The synthetic-click check reads `eventSourceUnixProcessID` and
/// `eventSourceStateID`; which values real clicks carry should be confirmed on
/// each new macOS release (see Settings, where this caveat is shown).
final class HumanOnlyButton: NSButton {
    var onAuthorize: (() -> Void)?
    /// Rejected attempts, shown under the button.
    var onRejected: ((String) -> Void)?

    static let holdDuration: TimeInterval = 1.0
    private var progress: CGFloat = 0 { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = "Hold to Authorize"
        keyEquivalent = ""
        bezelStyle = .regularSquare
        isBordered = false
        refusesFirstResponder = true
        setAccessibilityLabel("Authorize (hold with the mouse or trackpad)")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { false }
    override var canBecomeKeyView: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: 220, height: 64) }
    override func accessibilityPerformPress() -> Bool { false }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }
    override func keyDown(with event: NSEvent) {}
    override func performClick(_ sender: Any?) {}   // only a held, real click counts
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Whether `event` came from real hardware rather than another process.
    static func isHumanEvent(_ event: NSEvent) -> Bool {
        guard let cgEvent = event.cgEvent else { return false }
        let sourcePID = cgEvent.getIntegerValueField(.eventSourceUnixProcessID)
        let stateID = cgEvent.getIntegerValueField(.eventSourceStateID)
        return sourcePID == 0 && stateID == Int64(CGEventSourceStateID.hidSystemState.rawValue)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        guard Self.isHumanEvent(event) else {
            onRejected?("That click didn't come from a mouse or trackpad, so it was ignored.")
            return
        }
        let start = Date()
        var released = false
        while !released {
            let elapsed = Date().timeIntervalSince(start)
            progress = CGFloat(min(1, elapsed / Self.holdDuration))
            displayIfNeeded()
            if elapsed >= Self.holdDuration { break }
            if let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged],
                                           until: Date().addingTimeInterval(1.0 / 60), inMode: .eventTracking,
                                           dequeue: true) {
                let inside = bounds.contains(convert(next.locationInWindow, from: nil))
                if next.type == .leftMouseUp || !inside || !Self.isHumanEvent(next) { released = true }
            }
        }
        if released {
            progress = 0
            onRejected?("Keep holding until the ring fills.")
            return
        }
        progress = 1
        onAuthorize?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let background = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        (isEnabled ? NSColor.controlAccentColor : NSColor.disabledControlTextColor).withAlphaComponent(0.15).setFill()
        background.fill()
        NSColor.controlAccentColor.setStroke()
        background.lineWidth = 1
        background.stroke()

        // Progress ring at the leading edge.
        let ringRect = CGRect(x: rect.minX + 16, y: rect.midY - 14, width: 28, height: 28)
        let track = NSBezierPath(ovalIn: ringRect)
        track.lineWidth = 3
        NSColor.tertiaryLabelColor.setStroke()
        track.stroke()
        if progress > 0 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: CGPoint(x: ringRect.midX, y: ringRect.midY), radius: 14,
                          startAngle: 90, endAngle: 90 - 360 * progress, clockwise: true)
            arc.lineWidth = 3
            arc.lineCapStyle = .round
            NSColor.controlAccentColor.setStroke()
            arc.stroke()
        }

        let text = progress >= 1 ? "Authorized" : title
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: ringRect.maxX + 14, y: rect.midY - size.height / 2), withAttributes: attributes)
    }
}

struct AuthorizeButtonView: NSViewRepresentable {
    var onAuthorize: () -> Void
    var onRejected: (String) -> Void

    func makeNSView(context: Context) -> HumanOnlyButton {
        let button = HumanOnlyButton(frame: .zero)
        button.onAuthorize = onAuthorize
        button.onRejected = onRejected
        return button
    }

    func updateNSView(_ button: HumanOnlyButton, context: Context) {
        button.onAuthorize = onAuthorize
        button.onRejected = onRejected
    }
}

/// The sheet shown while an unlock or Extend waits for the Authorize button.
struct AuthorizeSheet: View {
    let prompt: AuthorizationPrompt
    let onFinish: (AuthOutcome) -> Void
    @State private var hint: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text(prompt.reason.prefix(1).uppercased() + prompt.reason.dropFirst() + "?")
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            AuthorizeButtonView(onAuthorize: { onFinish(.success) }, onRejected: { hint = $0 })
                .frame(width: 220, height: 64)
            Text(hint ?? "Press and hold with your mouse or trackpad.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Cancel") { onFinish(.cancelled) }
                .keyboardShortcut(.cancelAction)
        }
        .padding(28)
        .frame(width: 400)
    }
}
