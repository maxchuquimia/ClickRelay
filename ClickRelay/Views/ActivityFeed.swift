import QuickLook
import SwiftUI

/// One agent's calls, newest first, under its card.
struct CallList: View {
    @Environment(AppModel.self) private var model
    let sessionID: String
    let items: [ActivityItem]
    @State private var refusedOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Calls").font(.subheadline.weight(.semibold))
                Spacer()
                if !items.isEmpty {
                    Picker("Show", selection: $refusedOnly) {
                        Text("All").tag(false)
                        Text("Refused Only").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                }
            }
            let shown = refusedOnly ? items.filter { $0.outcome != .ok } : items
            if shown.isEmpty {
                Text(items.isEmpty ? "None yet in this session." : "No refused calls.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { item in
                        Divider()
                        ActivityRow(item: item)
                    }
                }
            }
        }
    }
}

struct ActivityRow: View {
    let item: ActivityItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(item.date, format: .dateTime.hour().minute().second())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
                .padding(.top, 1)
            OutcomeIcon(outcome: item.outcome)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.tool).font(.callout.weight(.medium).monospaced())
                    if let target = item.target {
                        Text(target).font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let script = item.script {
                    Label(script, systemImage: "scroll")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let detail = item.detail {
                    Text(item.tool == "type" ? "\u{201C}\(detail)\u{201D}" : detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                        .help(detail)
                }
                if let message = item.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(item.outcome == .error ? Color.red : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            ScreenshotThumbnail(item: item, maxWidth: 84, maxHeight: 52)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(item.outcome == .refused ? Color.yellow.opacity(0.12) : Color.clear)
    }
}

/// A screenshot's thumbnail. Clicking it opens the full image in Quick Look
/// (just the thumbnail, for screenshots older than the last few dozen).
struct ScreenshotThumbnail: View {
    @Environment(AppModel.self) private var model
    let item: ActivityItem
    let maxWidth: CGFloat
    let maxHeight: CGFloat
    @State private var previewURL: URL?

    var body: some View {
        if let thumbnail = item.thumbnail {
            Button {
                previewURL = model.previewURL(for: item)
            } label: {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.3)))
            }
            .buttonStyle(.plain)
            .disabled(item.image == nil)
            .help(item.image == nil ? "Only the thumbnail of older screenshots is kept" : "Quick Look")
            .quickLookPreview($previewURL)
        }
    }
}

struct OutcomeIcon: View {
    let outcome: AuditEntry.Outcome

    var body: some View {
        switch outcome {
        case .ok:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("OK")
        case .refused:
            Image(systemName: "hand.raised.circle.fill").foregroundStyle(.yellow).help("Refused")
        case .error:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).help("Error")
        }
    }
}
