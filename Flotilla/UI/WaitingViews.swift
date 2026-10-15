import SwiftUI

// H-248 (UX-048): "▲ Waiting for you" on a release: what only the owner can give it.

/// The section at the top of a release, above Install and Progress.
struct WaitingSection: View {
    @Environment(AppStore.self) private var store
    let blockers: [OwnerBlocker]
    let computerId: String
    /// Review… on the ruling: the release review on this screen.
    let reviewRuling: () -> Void
    @State private var expanded = false

    private var shown: [OwnerBlocker] { expanded ? blockers : Array(blockers.prefix(WaitingWords.shown)) }

    var body: some View {
        Section {
            ForEach(shown) { blocker in
                WaitingRow(blocker: blocker, computerId: computerId, reviewRuling: reviewRuling)
            }
            if !expanded, blockers.count > WaitingWords.shown {
                Button(WaitingWords.more(blockers.count - WaitingWords.shown)) { expanded = true }
                    .font(.footnote)
            }
        } header: {
            Text(WaitingWords.header(blockers.count))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Tone.needsYou.color)
                .textCase(nil)
        }
    }
}

/// One blocker in the Needs-you row style (H-134): glyph, a 2-line title,
/// "who · where · time", and its button at the trailing edge.
struct WaitingRow: View {
    @Environment(AppStore.self) private var store
    let blocker: OwnerBlocker
    let computerId: String
    let reviewRuling: () -> Void

    private var botName: String? { blocker.botId.flatMap { store.bot($0)?.name } }
    private var action: BlockerAction { .of(blocker) }

    var body: some View {
        let row = ItemRow(title: WaitingWords.title(blocker, bot: botName),
                          subtitle: WaitingWords.meta(blocker, bot: botName, computer: store.computerName),
                          titleLines: 2, subtitleLines: 2) {
            IconTile(systemImage: symbol, tone: .needsYou)
        } trailing: {
            if let label = action.label {
                Text(label).font(.subheadline.weight(.semibold)).foregroundStyle(Color.accentColor)
            }
        }
        Group {
            switch action {
            case .none:
                row
            case .reviewRuling:
                Button(action: reviewRuling) { row }.buttonStyle(.plain)
            case .openDecision(let id):
                NavigationLink(value: NeedsDestination.decision(computerId: computerId, decisionId: id)) { row }
            case .reply(let itemId, let commentId):
                NavigationLink(value: NeedsDestination.reply(computerId: computerId, itemId: itemId, commentId: commentId)) { row }
            case .reviewPermission(let botId):
                NavigationLink(value: NeedsDestination.bot(computerId: computerId, botId: botId, chat: false)) { row }
            }
        }
        .hoverEffect()
        .accessibilityElement(children: .combine)
        .modifier(ActionName(label: action.label))
    }

    private var symbol: String {
        switch blocker.kind {
        case .ruling: "shippingbox.fill"
        case .run: "terminal.fill"
        case .decision: "diamond.fill"
        case .question: "questionmark.bubble.fill"
        case .permission: "hand.raised.fill"
        }
    }
}

/// The whole row is tappable; the button's text is its accessibility action.
private struct ActionName: ViewModifier {
    let label: String?

    func body(content: Content) -> some View {
        if let label { content.accessibilityHint(label) } else { content }
    }
}

/// On a release in the Releases list: "▲ Waiting for you · N" under the version.
struct WaitingPill: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text(WaitingWords.header(count))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Tone.needsYou.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Tone.needsYou.color.opacity(0.12), in: Capsule())
        }
    }
}
