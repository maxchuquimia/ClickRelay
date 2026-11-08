import AppKit
import SwiftUI

/// A button only a person can press: real mouse or trackpad clicks count,
/// while posted clicks, Accessibility presses and the keyboard do nothing.
/// Like `HumanOnlyButton` but without the hold, for answering a hand-off.
final class HumanClickButton: NSButton {
    var onPress: (() -> Void)?

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .push
        keyEquivalent = ""
        refusesFirstResponder = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { false }
    override var canBecomeKeyView: Bool { false }
    override func accessibilityPerformPress() -> Bool { false }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }
    override func keyDown(with event: NSEvent) {}
    override func performClick(_ sender: Any?) {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window, HumanOnlyButton.isHumanEvent(event) else { return }
        isHighlighted = true
        defer { isHighlighted = false }
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let inside = bounds.contains(convert(next.locationInWindow, from: nil))
            isHighlighted = inside
            if next.type == .leftMouseUp {
                if inside, HumanOnlyButton.isHumanEvent(next) { onPress?() }
                return
            }
        }
    }
}

struct HumanButton: NSViewRepresentable {
    let title: String
    var prominent = false
    var small = false
    let action: () -> Void

    init(_ title: String, prominent: Bool = false, small: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.prominent = prominent
        self.small = small
        self.action = action
    }

    func makeNSView(context: Context) -> HumanClickButton {
        let button = HumanClickButton(title: title)
        button.controlSize = small ? .small : .regular
        if prominent { button.bezelColor = OverlayController.handOffColor }
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.onPress = action
        return button
    }

    func updateNSView(_ button: HumanClickButton, context: Context) {
        button.title = title
        button.onPress = action
    }
}

extension Color {
    /// The user's turn.
    static let handOff = Color(nsColor: OverlayController.handOffColor)
}

/// The callout beside a hand-off's ring: what the agent needs, a note back,
/// and Done or Can't Do This. One panel per open hand-off, placed next to the
/// ring and never on it.
@MainActor
final class HandOffPanelController {
    private weak var model: AppModel?
    private var panels: [String: HandOffPanel] = [:]
    private let catalog: WindowCatalog = SystemWindowCatalog()

    static let width: CGFloat = 290
    static let gap: CGFloat = 16

    init(model: AppModel) {
        self.model = model
    }

    /// Opens, moves or closes panels to match the open hand-offs.
    func update() {
        guard !AppModel.isRunningTests, let model else { return }
        let open = model.handOffs.handOffs
        for (sessionID, panel) in panels where open[sessionID] == nil {
            panel.orderOut(nil)
            panels[sessionID] = nil
        }
        guard !open.isEmpty else { return }
        let snapshot = catalog.snapshot()
        for (sessionID, handOff) in open {
            let panel = panels[sessionID] ?? makePanel(sessionID: sessionID, model: model)
            panels[sessionID] = panel
            guard let window = snapshot.window(handOff.windowID) else {
                // Off screen or on another Space: the alert panel still has it.
                panel.orderOut(nil)
                continue
            }
            let target = handOff.elementFrame
                .map { $0.offsetBy(dx: window.frame.minX, dy: window.frame.minY).intersection(window.frame) }
                .flatMap { $0.isNull || $0.width < 2 ? nil : $0 } ?? window.frame
            DispatchQueue.main.async { [weak self] in
                self?.place(panel, beside: target)
                panel.orderFrontRegardless()
            }
        }
    }

    private func makePanel(sessionID: String, model: AppModel) -> HandOffPanel {
        let root = HandOffCallout(sessionID: sessionID).environment(model)
        return HandOffPanel(content: NSHostingView(rootView: root))
    }

    /// To the right of the ring if there's room, else the left, else below
    /// or above it. `target` is in global top-left points.
    private func place(_ panel: HandOffPanel, beside target: CGRect) {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = CGSize(width: Self.width, height: max(80, content.fittingSize.height))
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        // Global top-left → AppKit bottom-left.
        let ring = CGRect(x: target.minX, y: primaryHeight - target.maxY, width: target.width, height: target.height)
            .insetBy(dx: -8, dy: -8)
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: ring.midX, y: ring.midY)) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let midY = min(max(visible.minY, ring.midY - size.height / 2), visible.maxY - size.height)
        var origin: CGPoint
        if ring.maxX + Self.gap + size.width <= visible.maxX {
            origin = CGPoint(x: ring.maxX + Self.gap, y: midY)
        } else if ring.minX - Self.gap - size.width >= visible.minX {
            origin = CGPoint(x: ring.minX - Self.gap - size.width, y: midY)
        } else if ring.minY - Self.gap - size.height >= visible.minY {
            origin = CGPoint(x: ring.minX, y: ring.minY - Self.gap - size.height)
        } else {
            origin = CGPoint(x: ring.minX, y: ring.maxY + Self.gap)
        }
        origin.x = min(max(visible.minX + 8, origin.x), visible.maxX - size.width - 8)
        origin.y = min(max(visible.minY + 8, origin.y), visible.maxY - size.height - 8)
        let frame = CGRect(origin: origin, size: size)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
    }
}

final class HandOffPanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: CGRect(x: 0, y: 0, width: HandOffPanelController.width, height: 160),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .modalPanel
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        sharingType = .none
        contentView = content
    }

    // Key only so the note field can take typing.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct HandOffCallout: View {
    @Environment(AppModel.self) private var model
    let sessionID: String

    var body: some View {
        if let handOff = model.handOffs.handOffs[sessionID] {
            let agent = model.anySession(sessionID)?.clientName ?? "The agent"
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(Color.handOff)
                    Text("Your Turn").font(.headline)
                    Spacer()
                    Text(model.anySession(sessionID)?.shortName ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HandOffMessage(text: handOff.message)
                Text("\(agent) can't see or use \(handOff.appName) until you're done.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HandOffNoteField(sessionID: sessionID, agent: agent)
                HStack(spacing: 8) {
                    Spacer()
                    HumanButton("Can't Do This", small: true) {
                        model.answerHandOff(sessionID: sessionID, done: false)
                    }
                    .fixedSize()
                    HumanButton("Done", prominent: true, small: true) {
                        model.answerHandOff(sessionID: sessionID, done: true)
                    }
                    .fixedSize()
                }
            }
            .padding(12)
            .frame(width: HandOffPanelController.width, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .top) {
                UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12)
                    .fill(Color.handOff)
                    .frame(height: 3)
            }
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        }
    }
}

/// The agent's words, in a grey box so it's clear the agent wrote them.
struct HandOffMessage: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6)))
            .textSelection(.enabled)
            .help("Written by the agent")
    }
}

/// A short note back to the agent, sent with Done or Can't Do This. Shared
/// between the callout, the alert panel and the agent's card.
struct HandOffNoteField: View {
    @Environment(AppModel.self) private var model
    let sessionID: String
    let agent: String

    var body: some View {
        TextField("Note for \(agent) (optional)", text: Binding(
            get: { model.handOffNotes[sessionID] ?? "" },
            set: { model.handOffNotes[sessionID] = String($0.prefix(AppModel.maxHandOffNote)) }))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
    }
}
