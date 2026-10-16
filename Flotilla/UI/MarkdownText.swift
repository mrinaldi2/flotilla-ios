import MarkdownUI
import SwiftUI

/// Bots write markdown: headings, lists, tables, code, images. An image with
/// a file path is fetched from the Mac through Gravity Lens (reports only);
/// a web image is loaded from the web.
struct MarkdownText: View {
    @Environment(Fleet.self) private var fleet
    let text: String
    /// The report this text is, so its local images can be resolved.
    var report: (project: String, name: String)?

    init(_ text: String, report: (project: String, name: String)? = nil) {
        self.text = text
        self.report = report
    }

    var body: some View {
        // Running text: each card id its own link (H-207). Block Markdown
        // (lists, tables, code, images) keeps MarkdownUI, with the block's
        // long-press menu of its cards (H-204).
        if LinkedTextModel.isRunningText(text) {
            LinkedText(markdown: text, font: .preferredFont(forTextStyle: .body))
        } else {
            Markdown(CardLinker.linked(text, prefixes: fleet.cards.prefixes))
                .markdownTheme(.gravity)
                .markdownImageProvider(MarkdownImages(report: report.map { ReportRef(project: $0.project, name: $0.name) }))
                .textSelection(.enabled)
                .cardMenu(for: text)
        }
    }
}

private struct ReportRef {
    let project: String
    let name: String
}

private struct MarkdownImages: ImageProvider {
    let report: ReportRef?

    func makeImage(url: URL?) -> some View {
        MarkdownImage(url: url, report: report)
    }
}

private struct MarkdownImage: View {
    let url: URL?
    let report: ReportRef?
    @State private var viewing = false

    private var source: LensStore.ImageSource? {
        guard let url, let report, url.scheme == nil || url.scheme == "file" else { return nil }
        let src = (url.scheme == "file" ? url.path : url.relativeString).removingPercentEncoding ?? url.relativeString
        return .report(project: report.project, name: report.name, src: src)
    }

    var body: some View {
        if let source {
            Button { viewing = true } label: {
                LensImageView(source: source, thumb: false, contentMode: .fit)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
            .buttonStyle(.plain)
            .fullScreenCover(isPresented: $viewing) { ImageViewer(sources: [source], index: 0) }
        } else if let url, url.scheme == "https" || url.scheme == "http" {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                ProgressView()
            }
        } else {
            Label("Image not available", systemImage: "photo")
                .font(.caption)
                .foregroundStyle(Color.secondaryText)
        }
    }
}

extension Theme {
    /// MarkdownUI's basic theme at body size, with compact headings and
    /// scrolling code blocks that suit a phone.
    static let gravity = Theme.basic
        .text { FontSize(.em(0.97)) }
        .heading1 { configuration in
            configuration.label.markdownTextStyle { FontWeight(.bold); FontSize(.em(1.3)) }
                .markdownMargin(top: 14, bottom: 6)
        }
        .heading2 { configuration in
            configuration.label.markdownTextStyle { FontWeight(.bold); FontSize(.em(1.15)) }
                .markdownMargin(top: 12, bottom: 4)
        }
        .heading3 { configuration in
            configuration.label.markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.05)) }
                .markdownMargin(top: 10, bottom: 4)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.88))
            BackgroundColor(Color(.tertiarySystemFill))
        }
        .codeBlock { configuration in
            ScrollView(.horizontal) {
                configuration.label
                    .markdownTextStyle { FontFamilyVariant(.monospaced); FontSize(.em(0.82)) }
                    .padding(10)
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .markdownMargin(top: 4, bottom: 8)
        }
        .table { configuration in
            ScrollView(.horizontal) {
                configuration.label.markdownTableBorderStyle(.init(color: Color(.separator)))
            }
            .markdownMargin(top: 4, bottom: 8)
        }
}
