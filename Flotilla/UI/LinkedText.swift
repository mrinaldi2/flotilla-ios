import SwiftUI
import UIKit

/// Running text whose card ids are links one by one (H-207, UX-035 §3, UX-037):
/// a tap opens the card in the current stack, a long-press on a link shows that
/// card's preview with Open card and Copy, an iPad pointer resting on a link
/// previews it, and VoiceOver reads each link as "H-293: <title>".
struct LinkedText: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.openURL) private var openURL
    let markdown: String
    var font: UIFont = .preferredFont(forTextStyle: .callout)
    var color: UIColor = .label
    var lineLimit: Int = 0

    var body: some View {
        let prefixes = fleet.cards.prefixes
        LinkedTextView(
            text: LinkedTextModel.attributed(markdown, prefixes: prefixes, font: font, color: color),
            lineLimit: lineLimit,
            title: { id in fleet.cards.cached(id)?.title },
            open: { openURL($0) },
            preview: { id in AnyView(CardPreviewView.hosted(id: id, fleet: fleet)) },
            prefetch: { ids in
                Task { @MainActor in for id in ids { _ = await fleet.cards.preview(id, fleet: fleet) } }
            })
    }
}

/// The pure parts, tested apart from UIKit.
enum LinkedTextModel {
    /// Inline Markdown with this phone's card ids as links, as an NSAttributedString.
    static func attributed(_ markdown: String, prefixes: Set<String>, font: UIFont, color: UIColor) -> NSAttributedString {
        let linked = CardLinker.linked(markdown, prefixes: prefixes)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? AttributedString(markdown: linked, options: options)) ?? AttributedString(markdown)
        let result = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
        let whole = NSRange(location: 0, length: result.length)
        result.addAttribute(.font, value: font, range: whole)
        result.addAttribute(.foregroundColor, value: color, range: whole)
        // Keep inline styles the parser gave (bold, italic, code) on top of the base font.
        result.enumerateAttribute(.inlinePresentationIntent, in: whole) { value, range, _ in
            guard let raw = value as? UInt else { return }
            let intent = InlinePresentationIntent(rawValue: raw)
            var traits: UIFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
            if intent.contains(.emphasized) { traits.insert(.traitItalic) }
            if intent.contains(.code) { traits.insert(.traitMonoSpace) }
            if let descriptor = font.fontDescriptor.withSymbolicTraits(traits), !traits.isEmpty {
                result.addAttribute(.font, value: UIFont(descriptor: descriptor, size: font.pointSize), range: range)
            }
        }
        return result
    }

    /// Each card link in the text: its id and where it sits.
    static func cardLinks(in text: NSAttributedString) -> [(id: String, range: NSRange)] {
        var links: [(String, NSRange)] = []
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
            if let url, let id = CardLinker.id(from: url) { links.append((id, range)) }
        }
        return links
    }

    /// What VoiceOver reads for one link: "H-293: <title>, else "H-293, card" (UX-035 §2).
    static func spokenName(_ id: String, title: String?) -> String {
        title.map { "\(id): \($0)" } ?? "\(id), card"
    }

    /// Text with no block-level Markdown (headings, lists, quotes, tables,
    /// fenced code, images) can be shown as running text with per-link actions.
    static func isRunningText(_ markdown: String) -> Bool {
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ")
                || trimmed.hasPrefix(">") || trimmed.hasPrefix("|") || trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
                || trimmed.hasPrefix("![") || trimmed.range(of: #"^\d+[.)] "#, options: .regularExpression) != nil {
                return false
            }
        }
        return true
    }
}

/// The UIKit side: a non-editable, non-scrolling UITextView.
private struct LinkedTextView: UIViewRepresentable {
    let text: NSAttributedString
    let lineLimit: Int
    let title: (String) -> String?
    let open: (URL) -> Void
    let preview: (String) -> AnyView
    let prefetch: ([String]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> CardLinkTextView {
        let view = CardLinkTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.linkTextAttributes = [.foregroundColor: UIColor.tintColor]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        view.addGestureRecognizer(UIHoverGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hover(_:))))
        return view
    }

    func updateUIView(_ view: CardLinkTextView, context: Context) {
        context.coordinator.parent = self
        if view.attributedText != text { view.attributedText = text }
        view.textContainer.maximumNumberOfLines = lineLimit
        view.textContainer.lineBreakMode = lineLimit > 0 ? .byTruncatingTail : .byWordWrapping
        view.links = LinkedTextModel.cardLinks(in: text)
        view.title = title
        view.open = open
        prefetch(view.links.map(\.id))
    }

    /// As wide as the text needs, up to the width offered, so bubbles hug short text.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: CardLinkTextView, context: Context) -> CGSize? {
        let limit = proposal.width ?? UIScreen.main.bounds.width
        let size = uiView.sizeThatFits(CGSize(width: limit, height: .greatestFiniteMagnitude))
        let natural = text.boundingRect(with: CGSize(width: limit, height: .greatestFiniteMagnitude),
                                        options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).width
        return CGSize(width: min(limit, ceil(natural)), height: ceil(size.height))
    }

    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var parent: LinkedTextView?
        private var hovered: String?
        private var hoverTask: Task<Void, Never>?
        private weak var shown: UIViewController?

        private func cardId(_ item: UITextItem) -> String? {
            guard case .link(let url) = item.content else { return nil }
            return CardLinker.id(from: url)
        }

        /// Tap: open the card here (or the system for other links).
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content else { return defaultAction }
            return UIAction { [weak self] _ in self?.parent?.open(url) }
        }

        /// Long-press on one link: that card's preview, Open card and Copy.
        func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem,
                      defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
            guard let id = cardId(textItem), let parent else { return nil }
            let open = UIAction(title: "Open card", image: UIImage(systemName: "rectangle.portrait.on.rectangle.portrait")) { _ in
                parent.open(CardLinker.url(id))
            }
            let copy = UIAction(title: "Copy \(id)", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = id
            }
            let host = UIHostingController(rootView: parent.preview(id))
            host.preferredContentSize = host.sizeThatFits(in: CGSize(width: 300, height: 400))
            return .init(preview: .view(host.view), menu: UIMenu(children: [open, copy]))
        }

        /// iPad pointer: resting on a link for 400 ms shows its preview (§3).
        @objc func hover(_ recognizer: UIHoverGestureRecognizer) {
            guard let view = recognizer.view as? CardLinkTextView else { return }
            let id = recognizer.state == .ended || recognizer.state == .cancelled ? nil : view.cardId(at: recognizer.location(in: view))
            guard id != hovered else { return }
            hovered = id
            hoverTask?.cancel()
            shown?.dismiss(animated: true)
            guard let id, let parent else { return }
            hoverTask = Task { [weak self, weak view] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let self, let view, let range = view.range(of: id),
                      let presenter = view.presenter else { return }
                let host = UIHostingController(rootView: parent.preview(id))
                host.modalPresentationStyle = .popover
                host.preferredContentSize = host.sizeThatFits(in: CGSize(width: 300, height: 400))
                host.popoverPresentationController?.sourceView = view
                host.popoverPresentationController?.sourceRect = view.rect(for: range)
                host.popoverPresentationController?.delegate = self
                presenter.present(host, animated: true)
                self.shown = host
            }
        }
    }
}

extension LinkedTextView.Coordinator: UIPopoverPresentationControllerDelegate {
    /// A popover on iPhone too, never a sheet.
    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        .none
    }
}

/// The text view that knows its card links, for hover and VoiceOver.
final class CardLinkTextView: UITextView {
    var links: [(id: String, range: NSRange)] = [] { didSet { linkElements = nil } }
    var title: (String) -> String? = { _ in nil }
    var open: (URL) -> Void = { _ in }
    private var linkElements: [UIAccessibilityElement]?

    func cardId(at point: CGPoint) -> String? {
        guard let position = closestPosition(to: point) else { return nil }
        let index = offset(from: beginningOfDocument, to: position)
        return links.first { NSLocationInRange(index, $0.range) && rect(for: $0.range).insetBy(dx: -4, dy: -4).contains(point) }?.id
    }

    func range(of id: String) -> NSRange? { links.first { $0.id == id }?.range }

    func rect(for range: NSRange) -> CGRect {
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length),
              let textRange = textRange(from: start, to: end) else { return .zero }
        return selectionRects(for: textRange).map(\.rect).reduce(CGRect.null) { $0.union($1) }
    }

    /// Whoever can present the hover popover.
    var presenter: UIViewController? {
        var controller = window?.rootViewController
        while let next = controller?.presentedViewController { controller = next }
        return controller
    }

    // VoiceOver: the text, then one element per card link named "H-293: <title>".
    // The elements are kept (QA-007, H-212): built anew on every read, nothing
    // retained them and only one link stayed reachable. They are rebuilt when
    // the text or its links change; labels and frames refresh on each read, so
    // a title that arrives later or a new layout is picked up.
    override var attributedText: NSAttributedString! {
        didSet { linkElements = nil }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if linkElements != nil { UIAccessibility.post(notification: .layoutChanged, argument: nil) }
    }

    override var accessibilityElements: [Any]? {
        get {
            guard !links.isEmpty else { return nil }
            let elements = linkElements ?? buildElements()
            linkElements = elements
            // The first element is the whole text; then the links in order.
            elements[0].accessibilityLabel = attributedText.string
            elements[0].accessibilityFrameInContainerSpace = bounds
            for (element, link) in zip(elements.dropFirst(), links) {
                element.accessibilityLabel = LinkedTextModel.spokenName(link.id, title: title(link.id))
                element.accessibilityFrameInContainerSpace = rect(for: link.range)
            }
            return elements
        }
        set {}
    }

    private func buildElements() -> [UIAccessibilityElement] {
        let text = UIAccessibilityElement(accessibilityContainer: self)
        let elements = links.map { link -> UIAccessibilityElement in
            let element = CardLinkElement(accessibilityContainer: self)
            element.accessibilityTraits = .link
            element.activate = { [weak self] in self?.open(CardLinker.url(link.id)) }
            return element
        }
        return [text] + elements
    }
}

private final class CardLinkElement: UIAccessibilityElement {
    var activate: () -> Void = {}
    override func accessibilityActivate() -> Bool {
        activate()
        return true
    }
}
