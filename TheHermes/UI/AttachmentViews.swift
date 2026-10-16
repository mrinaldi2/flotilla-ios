import QuickLook
import SwiftUI

/// A card's attachments (K4b): images as thumbnails that open full screen,
/// files with their name, type and size (opened in Quick Look), linked
/// documents, and a placeholder for each one removed.
struct AttachmentsSection: View {
    @Environment(AppStore.self) private var store
    let attachments: [ItemAttachment]
    @State private var opened: Int?
    @State private var preview: URL?
    @State private var reading: String?
    @State private var failure: String?

    private var images: [ItemAttachment] { attachments.filter { $0.kind == "image" && !$0.removed } }
    private var files: [ItemAttachment] { attachments.filter { $0.kind == "file" && !$0.removed } }
    private var docs: [ItemAttachment] { attachments.filter { $0.kind == "doc" && !$0.removed } }
    private var removed: [ItemAttachment] { attachments.filter(\.removed) }

    var body: some View {
        if !attachments.isEmpty {
            Section {
                if !images.isEmpty { thumbnails }
                ForEach(files, id: \.id) { file in
                    Button { open(file) } label: {
                        ItemRow(title: file.name, subtitle: AttachmentWords.line(file),
                                detail: file.caption.isEmpty ? nil : file.caption) {
                            IconTile(systemImage: file.name.lowercased().hasSuffix(".pdf") ? "doc.richtext" : "doc.text")
                        } trailing: {
                            if reading == file.id { ProgressView() }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the file")
                }
                ForEach(docs, id: \.id) { doc in
                    if let url = URL(string: doc.url), !doc.url.isEmpty {
                        Link(destination: url) {
                            ItemRow(title: doc.name.isEmpty ? doc.url : doc.name, subtitle: doc.url) { IconTile(systemImage: "link") }
                        }
                    } else {
                        ItemRow(title: doc.name, subtitle: "Project document · \(doc.path)") { IconTile(systemImage: "doc.on.doc") }
                    }
                }
                ForEach(removed, id: \.id) { gone in
                    Label("⊘ \(gone.name) · removed", systemImage: "trash")
                        .font(.footnote)
                        .foregroundStyle(Color.secondaryText)
                }
                if let failure {
                    Text(failure).font(.footnote).foregroundStyle(Color.errorText)
                }
            } header: {
                SectionTitle("Attachments", count: attachments.count - removed.count)
            }
            .fullScreenCover(item: Binding(get: { opened.map(AttachmentStart.init) }, set: { opened = $0?.index })) { start in
                ImageViewer(sources: images.map { .attachment(id: $0.id, name: $0.name) }, index: start.index)
            }
            .quickLookPreview($preview)
        }
    }

    private var thumbnails: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                    Button { opened = index } label: {
                        LensImageView(source: .attachment(id: image.id, name: image.name))
                            .frame(width: 124, height: 88)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color(.separator), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(image.caption.isEmpty ? "Image \(image.name)" : "Image \(image.name): \(image.caption)")
                    .accessibilityHint("Opens it full screen")
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// Reads the file from the board's home into a temporary copy for Quick Look.
    private func open(_ file: ItemAttachment) {
        reading = file.id
        failure = nil
        Task {
            defer { reading = nil }
            do {
                let data = try await store.attachmentData(file.id)
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("attachments/\(file.id)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent((file.name as NSString).lastPathComponent)
                try data.write(to: url, options: .atomic)
                preview = url
            } catch {
                failure = "Couldn’t open \(file.name). \(error.localizedDescription)"
            }
        }
    }
}

private struct AttachmentStart: Identifiable {
    let index: Int
    var id: Int { index }
}

/// Inline images in a description, `![caption](attachment:<id>)`: words in
/// their place, since the images show under Attachments; a removed one is a
/// placeholder, never a broken link.
enum AttachmentText {
    static func inline(_ markdown: String, attachments: [ItemAttachment]) -> String {
        guard markdown.contains("](attachment:") else { return markdown }
        let pattern = #"!\[([^\]]*)\]\(attachment:([A-Za-z0-9_-]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return markdown }
        var out = markdown
        for match in regex.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)).reversed() {
            guard let whole = Range(match.range, in: out), let captionRange = Range(match.range(at: 1), in: markdown),
                  let idRange = Range(match.range(at: 2), in: markdown) else { continue }
            let caption = String(markdown[captionRange])
            let found = attachments.first { $0.id == markdown[idRange] }
            let name = caption.isEmpty ? (found?.name ?? "image") : caption
            let words = (found == nil || found?.removed == true) ? "⊘ *removed image: \(name)*" : "🖼 *image: \(name), under Attachments*"
            out.replaceSubrange(whole, with: words)
        }
        return out
    }
}
