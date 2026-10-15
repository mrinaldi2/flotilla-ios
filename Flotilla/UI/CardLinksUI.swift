import SwiftUI
import UIKit

/// Card links on screen (H-204, UX-035): a tap pushes the card onto the
/// stack the link is in; a long-press previews it with Open card and Copy.

/// Opens `hermes://item/<id>` links from anything inside this navigation
/// stack. A card that isn't on its board, or whose computer is away, says so
/// instead of navigating (§6).
private struct OpensCardLinks: ViewModifier {
    @Environment(Fleet.self) private var fleet
    let projectIds: [String]
    let push: (NeedsDestination) -> Void
    @State private var notice: CardPreview?

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                guard let id = CardLinker.id(from: url) else { return .systemAction }
                open(id)
                return .handled
            })
            .alert(notice?.id ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(notice?.notice ?? "")
            }
    }

    private func open(_ id: String) {
        if let cached = fleet.cards.cached(id), cached.notice != nil {
            notice = cached
            return
        }
        guard let home = fleet.cards.home(for: id, preferring: projectIds) else { return }
        push(.item(computerId: fleet.boardComputer(itemId: id)?.id ?? home.computerId, itemId: id))
    }
}

extension View {
    /// Card links inside open the card here: `push` appends to this stack's path.
    func opensCardLinks(projectIds: [String] = [], push: @escaping (NeedsDestination) -> Void) -> some View {
        modifier(OpensCardLinks(projectIds: projectIds, push: push))
    }

    /// Long-press on text that names cards: each card's preview, Open card and
    /// Copy (UX-035 §3). One card shows its preview above the menu.
    func cardMenu(for text: String) -> some View {
        modifier(CardMenu(text: text))
    }

    /// Long-press on a row that is one card.
    func cardMenu(id: String) -> some View {
        modifier(CardMenu(text: id))
    }
}

private struct CardMenu: ViewModifier {
    @Environment(Fleet.self) private var fleet
    @Environment(\.openURL) private var openURL
    let text: String
    /// Looked up when the text appears, so the menu names every card (UX-037).
    @State private var previews: [String: CardPreview] = [:]

    private var ids: [String] { CardLinker.ids(in: text, prefixes: fleet.cards.prefixes) }

    func body(content: Content) -> some View {
        let ids = self.ids
        if ids.count == 1, let id = ids.first {
            content.contextMenu {
                actions(id)
            } preview: {
                // A context-menu preview is hosted outside the app's environment:
                // it gets Fleet here or crashes (H-214).
                CardPreviewView.hosted(id: id, fleet: fleet)
            }
        } else if ids.count > 1 {
            content
                .contextMenu {
                    ForEach(ids, id: \.self) { id in
                        Section(CardMenuWords.entry(id, previews[id] ?? fleet.cards.cached(id))) { actions(id) }
                    }
                }
                .task(id: ids) {
                    for id in ids where previews[id] == nil {
                        previews[id] = await fleet.cards.preview(id, fleet: fleet)
                    }
                }
        } else {
            content
        }
    }

    @ViewBuilder private func actions(_ id: String) -> some View {
        Button("Open card", systemImage: "rectangle.portrait.on.rectangle.portrait") { openURL(CardLinker.url(id)) }
        Button("Copy \(id)", systemImage: "doc.on.doc") { UIPasteboard.general.string = id }
    }
}

/// A multi-card menu's entry: "HL-005 · <title>", "HL-005 · Loading…" until
/// known, or what happened to it; never a bare id (UX-037).
enum CardMenuWords {
    static func entry(_ id: String, _ preview: CardPreview?) -> String {
        guard let preview else { return "\(id) · Loading…" }
        if let notice = preview.notice { return notice }
        return "\(id) · \(preview.title ?? "Loading…")"
    }
}

extension CardPreviewView {
    /// The preview as it is hosted on its own (a context-menu preview, a hover
    /// popover): everything it reads from the environment is passed in (H-214).
    static func hosted(id: String, fleet: Fleet) -> some View {
        CardPreviewView(id: id).environment(fleet).frame(width: 300)
    }
}

/// The preview card (§3): id · type · priority, the title, column · assignee,
/// flags and the project when it isn't the one on screen.
struct CardPreviewView: View {
    @Environment(Fleet.self) private var fleet
    let id: String
    @State private var preview: CardPreview?
    @State private var slow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let preview {
                Text(preview.heading).font(.caption.weight(.semibold)).foregroundStyle(Color.secondaryText)
                if let notice = preview.notice {
                    Text(notice).font(.callout)
                } else {
                    if let title = preview.title { Text(title).font(.callout.weight(.medium)).lineLimit(2) }
                    if let place = preview.placeLine { Text(place).font(.footnote) }
                    if let flags = preview.flagsLine { Text(flags).font(.footnote).foregroundStyle(Color.warningText) }
                    if let other = preview.otherProject { Text(other).font(.footnote).foregroundStyle(Color.secondaryText) }
                }
            } else if slow, let home = fleet.cards.home(for: id) {
                // Over a second: say where it lives rather than spin (§3).
                Text(CardPreview(id: id, state: .offline(computer: fleet.computer(id: home.computerId)?.name,
                                                         lastSeen: nil), project: home.projectName).notice ?? "")
                    .font(.callout)
            } else {
                Text("Loading \(id)…").font(.callout).foregroundStyle(Color.secondaryText)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .task { preview = await fleet.cards.preview(id, fleet: fleet) }
        .task {
            try? await Task.sleep(for: .seconds(1))
            if preview == nil { slow = true }
        }
    }
}

extension Fleet {
    /// Inline Markdown with this phone's card ids as links, for a `Text`.
    func linkedText(_ markdown: String) -> AttributedString {
        let linked = CardLinker.linked(markdown, prefixes: cards.prefixes)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: linked, options: options)) ?? AttributedString(markdown)
    }
}
