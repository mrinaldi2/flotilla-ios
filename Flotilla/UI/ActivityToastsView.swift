import SwiftUI

/// Board activity, at the top of every screen (0.20, as the desktop): who
/// did what on which card. Tap a toast for the card; it goes after 8 s.
struct ActivityToastsView: View {
    @Environment(Fleet.self) private var fleet
    /// Opens the card a toast is about.
    let open: (ActivityToast) -> Void

    var body: some View {
        VStack(spacing: 6) {
            ForEach(fleet.activity.toasts) { toast in
                ActivityToastRow(toast: toast, many: fleet.computers.count > 1,
                                 computer: fleet.computer(id: toast.computerId)?.name) {
                    fleet.activity.dismiss(toast.id)
                    open(toast)
                } dismiss: {
                    withAnimation(.snappy) { fleet.activity.dismiss(toast.id) }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .animation(.snappy, value: fleet.activity.toasts)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                fleet.activity.expire()
            }
        }
    }
}

private struct ActivityToastRow: View {
    let toast: ActivityToast
    let many: Bool
    let computer: String?
    let tap: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: tap) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(toast.actorLabel).font(.subheadline.weight(.semibold))
                        Text(toast.itemId).font(.caption.monospaced()).foregroundStyle(Color.secondaryText)
                        if many, let computer {
                            Text("· \(computer)").font(.caption).foregroundStyle(Color.secondaryText)
                        }
                    }
                    if !toast.itemTitle.isEmpty {
                        Text(toast.itemTitle).font(.footnote).lineLimit(1)
                    }
                    ForEach(Array(toast.lines.enumerated()), id: \.offset) { _, line in
                        (Text("\(line.glyph) ").fontWeight(.bold) + Text(line.word).fontWeight(.medium)
                            + Text(line.detail.isEmpty ? "" : " · \(line.detail)").foregroundStyle(Color.secondaryText))
                            .font(.footnote)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens the card")
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(Color.secondaryText)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 12)
        .padding(.vertical, 8)
        .padding(.trailing, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }
}
