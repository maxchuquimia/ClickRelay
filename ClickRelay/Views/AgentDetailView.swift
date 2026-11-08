import SwiftUI

/// Everything about one agent: who it is, its card (asking, locked or
/// unlocked) and its calls.
struct AgentDetailView: View {
    @Environment(AppModel.self) private var model
    let session: AgentSession
    let connected: Bool
    @State private var showCalls = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let notice = model.notices[session.id] {
                    NoticeBanner(notice: notice)
                }
                if connected, let handOff = model.handOffs.handOffs[session.id] {
                    HandOffCard(session: session, handOff: handOff)
                }
                card
                if let error = model.unlockError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                calls
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.shortName)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(headerDetail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(session.workingDirectory ?? "")
                    .textSelection(.enabled)
            }
            Spacer()
        }
    }

    private var headerDetail: String {
        let place = session.workingDirectory.map(MCPLocal.abbreviatingHome)
        return [place, session.terminalName].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private var card: some View {
        if !connected {
            DisconnectedCard(session: session)
        } else if let lease = model.leases.leases[session.id] {
            LiveCard(session: session, lease: lease)
        } else {
            UnlockCard(session: session, request: model.request(for: session.id))
        }
    }

    @ViewBuilder private var calls: some View {
        let items = model.activity(for: session.id)
        // While asking, fold the calls so the card fits without scrolling.
        let folded = model.request(for: session.id) != nil && !showCalls
        if folded {
            if !items.isEmpty {
                Button(items.count == 1 ? "1 earlier call" : "\(items.count) earlier calls") { showCalls = true }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        } else {
            CallList(sessionID: session.id, items: items)
        }
    }
}

// MARK: - Unlocked

private struct LiveCard: View {
    @Environment(AppModel.self) private var model
    let session: AgentSession
    let lease: Lease

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Can use").font(.callout.weight(.semibold))
                AppChips(bundleIDs: lease.allowedBundleIDs)
                Spacer(minLength: 0)
                Button("Change Apps…") { model.changeApps(sessionID: session.id) }
                    .buttonStyle(.link)
                    .help("Apps can't change while unlocked. This locks the agent and keeps these apps ticked so you can unlock again.")
            }
            let total = lease.expiresAt - lease.startedAt
            HStack(spacing: 14) {
                Countdown(until: lease.endDate) { left in
                    Text(AppModel.clock(.seconds(left)))
                        .font(.system(size: 32, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(left <= 60 ? Color.red : Color.primary)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("left of \(AppModel.shortDuration(minutes: max(1, Int(total.components.seconds) / 60))), until \(lease.endDate.formatted(date: .omitted, time: .shortened))")
                        .font(.callout)
                    // Counts itself down; no redraw of the card needed.
                    ProgressView(timerInterval: lease.startedDate...lease.endDate, countsDown: true) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                    .tint(.orange)
                }
                Spacer(minLength: 0)
                Button("Extend \(AppModel.shortDuration(minutes: model.preferences.leaseDurationMinutes))") {
                    Task { await model.extend(sessionID: session.id) }
                }
                .help(model.preferences.unlockMethod == .authorizeButton ? "Then hold Authorize" : "Asks for Touch ID")
                Button("Lock") { model.lock(sessionID: session.id) }
                    .controlSize(.large)
                    .foregroundStyle(.red)
                    .help("Ends this agent's access. Lock All in the toolbar ends every agent's.")
            }
            if let request = model.request(for: session.id) {
                LiveRequest(session: session, request: request)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.35)))
    }

}

/// An unlocked agent asking for more: other apps, or more time. Apps can't
/// change mid-lease, so allowing more means locking and unlocking again with
/// them ticked; more time is Extend.
private struct LiveRequest: View {
    @Environment(AppModel.self) private var model
    let session: AgentSession
    let request: AccessRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(UnlockCard.describe(request, unlocked: true), systemImage: "hand.raised.fill")
                    .font(.headline)
                Spacer()
                Text("Asked at \(request.createdAt.formatted(date: .omitted, time: .shortened))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let reason = request.reason { AgentQuote(text: reason) }
            HStack {
                Text(request.apps.isEmpty
                     ? "Extend gives it more time."
                     : "Apps can't change while unlocked. Change Apps locks it and keeps its apps ticked, so you can add these and unlock again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Not Now") { model.leases.dismissRequest(request.id) }
                if !request.apps.isEmpty {
                    Button("Change Apps…") { model.changeApps(sessionID: session.id) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.blue, lineWidth: 1.5))
    }
}

/// The agent handed something to the user and is waiting for them.
private struct HandOffCard: View {
    @Environment(AppModel.self) private var model
    let session: AgentSession
    let handOff: HandOff

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("Waiting for you in \(handOff.appName)", systemImage: "hand.raised.fill")
                    .font(.headline)
                    .foregroundStyle(Color.handOff)
                Spacer()
                Text("Asked at \(handOff.createdAt.formatted(date: .omitted, time: .shortened))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HandOffMessage(text: handOff.message)
            Text("\(session.clientName) can't see or use \(handOff.appName), and every agent's input is paused, until you're done.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HandOffNoteField(sessionID: session.id, agent: session.clientName)
            HStack(spacing: 8) {
                Button("Show Me") { model.showHandOff(sessionID: session.id) }
                Spacer()
                HumanButton("Can't Do This") { model.answerHandOff(sessionID: session.id, done: false) }
                    .fixedSize()
                HumanButton("Done", prominent: true) { model.answerHandOff(sessionID: session.id, done: true) }
                    .fixedSize()
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.handOff.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.handOff, lineWidth: 2))
    }
}

/// What the agent said with `clickrelay_notify`.
private struct NoticeBanner: View {
    @Environment(AppModel.self) private var model
    let notice: AgentNotice

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.kind == .done ? "checkmark.circle.fill" : "exclamationmark.bubble.fill")
                .foregroundStyle(notice.kind == .done ? Color.green : Color.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.kind == .done ? "Done at \(time)" : "Stopped at \(time) and needs you")
                    .font(.headline)
                Text(notice.message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Dismiss") { model.dismissNotice(sessionID: notice.sessionID) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill((notice.kind == .done ? Color.green : Color.orange).opacity(0.1)))
    }

    private var time: String { notice.date.formatted(date: .omitted, time: .shortened) }
}

/// Allowed apps as small icon-and-name capsules, wrapping as needed.
struct AppChips: View {
    let bundleIDs: Set<String>

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(bundleIDs.subtracting(AccessPolicy.filePanelServices).sorted(), id: \.self) { id in
                chip {
                    Image(nsImage: AppCatalog.icon(for: id)).resizable().frame(width: 14, height: 14)
                    Text(AppCatalog.name(for: id))
                }
            }
            if !bundleIDs.isDisjoint(with: AccessPolicy.filePanelServices) {
                chip {
                    Image(systemName: "doc").font(.caption)
                    Text("Open and Save panels")
                }
            }
        }
    }

    private func chip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 4) { content() }
            .font(.callout)
            .padding(.leading, 5)
            .padding(.trailing, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(.background))
            .overlay(Capsule().strokeBorder(.separator))
    }
}

// MARK: - Disconnected

private struct DisconnectedCard: View {
    @Environment(AppModel.self) private var model
    let session: AgentSession

    var body: some View {
        HStack {
            Label("Disconnected", systemImage: "bolt.horizontal.circle")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Clear Calls") { model.clearActivity(for: session.id) }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
}

// MARK: - Layout

/// Lays children out left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
