import AppKit
import SwiftUI

/// Something an agent wants the user to see: a request for access, or a
/// note that it's finished.
enum AgentAlert: Identifiable {
    case request(AccessRequest)
    case notice(AgentNotice)
    case handOff(HandOff)

    var id: String {
        switch self {
        case .request(let request): "request-\(request.id)"
        case .notice(let notice): "notice-\(notice.sessionID)"
        case .handOff(let handOff): "handoff-\(handOff.id)"
        }
    }

    var sessionID: String {
        switch self {
        case .request(let request): request.session.id
        case .notice(let notice): notice.sessionID
        case .handOff(let handOff): handOff.sessionID
        }
    }
}

/// A small panel that drops down under ClickRelay's menu bar item while an
/// agent is asking for access or has said it's done. It floats over every
/// app (full screen ones too) without taking focus, so it's seen even with
/// one display and the agent's app filling it.
@MainActor
final class AlertPanelController {
    private weak var model: AppModel?
    private var panel: AlertPanel?
    /// Closed by the user; stays closed until something new arrives.
    private var hidden = false

    static let width: CGFloat = 340

    init(model: AppModel) {
        self.model = model
    }

    /// Shows the panel, even if the user closed it before.
    func show() {
        hidden = false
        refresh()
    }

    /// Shows, resizes or hides the panel to match what's waiting.
    func refresh(showingNew: Bool = false) {
        guard !AppModel.isRunningTests, let model else { return }
        if showingNew { hidden = false }
        guard !model.alerts.isEmpty, !hidden else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel(model)
        self.panel = panel
        // SwiftUI applies the change on its next pass; size after that.
        DispatchQueue.main.async { [weak self] in
            self?.place(panel)
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        hidden = true
        panel?.orderOut(nil)
    }

    private func makePanel(_ model: AppModel) -> AlertPanel {
        let root = AlertStack(onClose: { [weak self] in self?.hide() },
                              onResize: { [weak self] in
                                  guard let self, let panel = self.panel, panel.isVisible else { return }
                                  self.place(panel)
                              })
            .environment(model)
        return AlertPanel(content: NSHostingView(rootView: root))
    }

    /// Under the menu bar item if it can be found, else the top right of the
    /// main screen.
    private func place(_ panel: AlertPanel) {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = CGSize(width: Self.width, height: max(60, content.fittingSize.height))
        let item = NSApp.windows.first { $0.className.contains("StatusBarWindow") && $0.isVisible }?.frame
        let screen = item.flatMap { frame in NSScreen.screens.first { $0.frame.intersects(frame) } }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let centerX = item?.midX ?? (visible.maxX - size.width / 2 - 12)
        let x = min(max(visible.minX + 8, centerX - size.width / 2), visible.maxX - size.width - 8)
        let y = visible.maxY - size.height - 6
        panel.setFrame(CGRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.invalidateShadow()
    }
}

final class AlertPanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: CGRect(x: 0, y: 0, width: AlertPanelController.width, height: 100),
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
        // Kept out of screen sharing and recordings, like the overlay.
        sharingType = .none
        contentView = content
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The panel's content: one row per alert.
private struct AlertStack: View {
    @Environment(AppModel.self) private var model
    let onClose: () -> Void
    let onResize: () -> Void

    var body: some View {
        let alerts = model.alerts
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(nsImage: MenuBarIcon.image)
                    .foregroundStyle(.secondary)
                Text("ClickRelay")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide until something new comes in")
            }
            ForEach(alerts) { alert in
                if alert.id != alerts.first?.id { Divider() }
                AlertRow(alert: alert)
            }
        }
        .padding(12)
        .frame(width: AlertPanelController.width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .onChange(of: alerts.map(\.id)) { onResize() }
    }
}

private struct AlertRow: View {
    @Environment(AppModel.self) private var model
    let alert: AgentAlert

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.font(.title3).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if case .handOff(let handOff) = alert {
                    HandOffMessage(text: handOff.message)
                    HandOffNoteField(sessionID: handOff.sessionID,
                                     agent: session?.clientName ?? "the agent")
                } else {
                    Text(detail)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let quote {
                    Text("\u{201C}\(quote)\u{201D}")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Spacer()
                    buttons
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
    }

    private var session: AgentSession? { model.anySession(alert.sessionID) }
    private var name: String { session?.shortName ?? "An agent" }

    @ViewBuilder private var icon: some View {
        switch alert {
        case .request:
            Image(systemName: "hand.raised.fill").foregroundStyle(.blue)
        case .handOff:
            Image(systemName: "hand.raised.fill").foregroundStyle(Color.handOff)
        case .notice(let notice):
            if notice.kind == .done {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.orange)
            }
        }
    }

    private var title: String {
        switch alert {
        case .request: "\(name) is asking"
        case .notice(let notice): notice.kind == .done ? "\(name) is done" : "\(name) needs you"
        case .handOff(let handOff): "Your turn in \(handOff.appName)"
        }
    }

    private var detail: String {
        switch alert {
        case .request(let request):
            return UnlockCard.describe(request, unlocked: model.leases.leases[request.session.id] != nil)
        case .notice(let notice):
            return notice.message
        case .handOff(let handOff):
            return handOff.message
        }
    }

    private var quote: String? {
        if case .request(let request) = alert { return request.reason }
        return nil
    }

    @ViewBuilder private var buttons: some View {
        switch alert {
        case .request(let request):
            Button("Not Now") { model.leases.dismissRequest(request.id) }
            Button("Review…") { model.reveal(sessionID: request.session.id) }
                .buttonStyle(.borderedProminent)
        case .notice(let notice):
            if model.leases.leases[notice.sessionID] != nil {
                Button("Lock") {
                    model.lock(sessionID: notice.sessionID)
                    model.dismissNotice(sessionID: notice.sessionID)
                }
            }
            Button("Dismiss") { model.dismissNotice(sessionID: notice.sessionID) }
            Button("Show") {
                model.reveal(sessionID: notice.sessionID)
                model.dismissNotice(sessionID: notice.sessionID)
            }
            .buttonStyle(.borderedProminent)
        case .handOff(let handOff):
            Button("Show Me") { model.showHandOff(sessionID: handOff.sessionID) }
            HumanButton("Can't Do This", small: true) {
                model.answerHandOff(sessionID: handOff.sessionID, done: false)
            }
            .fixedSize()
            HumanButton("Done", prominent: true, small: true) {
                model.answerHandOff(sessionID: handOff.sessionID, done: true)
            }
            .fixedSize()
        }
    }
}
