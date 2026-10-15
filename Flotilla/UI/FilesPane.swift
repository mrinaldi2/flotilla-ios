import PDFKit
import SwiftUI

/// The bot's project artifacts, newest first: everything the project's bots
/// wrote for each other, including files from bots on another computer.
/// Gravity's Files panel, on the phone.
struct BotFilesPane: View {
    @Environment(AppStore.self) private var store
    let botId: String
    @State private var files: [ArtifactFile] = []
    /// How many are shown. An older daemon sends every file at once, so the
    /// newest are shown and more on request either way.
    @State private var shown = Page.size
    /// The next page's cursor, while the daemon has more.
    @State private var next: String?
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        List {
            if let error {
                Text(error).font(.footnote).foregroundStyle(Color.errorText)
            }
            if loaded, error == nil, files.isEmpty {
                EmptyNote(text: "No files in this project yet.", systemImage: "doc")
            }
            if !files.isEmpty {
                Section {
                    ForEach(files.prefix(shown)) { file in
                        NavigationLink(value: file) { FileRow(file: file) }
                    }
                    ListEnd(hasMore: files.count > shown || next != nil, noun: "files", loaded: min(shown, files.count)) {
                        if files.count <= shown { try await loadMore() }
                        shown += Page.size
                    }
                } header: {
                    SectionTitle("Newest")
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load(fresh: true) }
        .task(id: store.status) { await load(fresh: true) }
        // Files land when bots finish work: look again once bus traffic settles.
        .task(id: store.busRevision) {
            guard loaded else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await load()
        }
        .navigationDestination(for: ArtifactFile.self) { FilePreview(botId: botId, file: $0) }
    }

    /// The newest page. Fresh, it replaces the list; otherwise (bus traffic)
    /// it is merged in and pages already loaded stay.
    private func load(fresh: Bool = false) async {
        guard store.status == .connected, let projectId = store.bot(botId)?.projectId else { return }
        do {
            let page = try await store.listArtifacts(projectId: projectId)
            if fresh || files.isEmpty {
                files = page.files
                next = page.hasMore ? page.nextBefore : nil
                shown = Page.size
            } else {
                files = ArtifactPage.merge(files, page.files)
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func loadMore() async throws {
        guard let next, let projectId = store.bot(botId)?.projectId else { return }
        let page = try await store.listArtifacts(projectId: projectId, before: next)
        files = ArtifactPage.merge(files, page.files)
        self.next = page.hasMore ? page.nextBefore : nil
    }
}

private struct FileRow: View {
    let file: ArtifactFile

    private var symbol: String {
        if file.mime.hasPrefix("image/") { return "photo" }
        if file.mime == "text/markdown" { return "doc.richtext" }
        if file.mime == "application/pdf" { return "doc.text.image" }
        if file.mime == "text/x-code" { return "chevron.left.forwardslash.chevron.right" }
        return "doc"
    }

    private var meta: String {
        var parts = [file.title == nil ? file.rel : file.name, ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)]
        if let modified = file.modified { parts.append(modified.relative) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        ItemRow(title: file.title ?? file.name, subtitle: meta, detail: file.createdBy?.label, titleLines: 2) {
            IconTile(systemImage: symbol)
        }
    }
}

/// One file, rendered for reading: markdown, code and text, images and PDFs.
/// Read through the bot, so it reaches its own folder and the project's
/// artifacts and nothing else.
struct FilePreview: View {
    @Environment(AppStore.self) private var store
    let botId: String
    let file: ArtifactFile
    @State private var loadedFile: DaemonFile?
    @State private var error: String?
    @State private var shared: URL?

    var body: some View {
        Group {
            if let loadedFile {
                content(loadedFile)
            } else if let error {
                ContentUnavailableView("Can't open the file", systemImage: "doc.questionmark", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { UIPasteboard.general.string = file.path } label: { Label("Copy path", systemImage: "doc.on.doc") }
                    if let shared {
                        ShareLink(item: shared) { Label("Share or save", systemImage: "square.and.arrow.up") }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            do {
                let loaded = try await store.readFile(botId: botId, path: file.path)
                loadedFile = loaded
                shared = Self.temporaryCopy(loaded, name: file.name)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    @ViewBuilder private func content(_ loaded: DaemonFile) -> some View {
        if loaded.mime.hasPrefix("image/"), let data = loaded.data, let image = UIImage(data: data) {
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
            }
        } else if loaded.mime == "application/pdf", let data = loaded.data, let document = PDFDocument(data: data) {
            PDFPreview(document: document)
        } else if let text = loaded.text {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if loaded.truncated {
                        Text("Only the first 16 MB are shown.").font(.caption).foregroundStyle(Color.secondaryText)
                    }
                    if loaded.mime == "text/markdown" {
                        MarkdownText(text).textSelection(.enabled)
                    } else {
                        CodeBlock(title: file.name, text: text)
                    }
                }
                .padding()
            }
        } else {
            ContentUnavailableView("No preview", systemImage: "doc",
                                   description: Text("No preview for this kind of file (\(loaded.mime)). Share it to open it in another app."))
        }
    }

    /// A copy in the app's temporary folder, for the share sheet.
    private static func temporaryCopy(_ file: DaemonFile, name: String) -> URL? {
        guard let data = file.data ?? file.text.map({ Data($0.utf8) }) else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("artifacts/\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name.isEmpty ? "file" : name)
        return (try? data.write(to: url)) == nil ? nil : url
    }
}

private struct PDFPreview: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = document
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}
}
