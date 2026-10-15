import QuickLook
import SwiftUI

struct FolderLink: Hashable {
    let path: String
}

/// One folder on the Mac. Folders open, files preview; any item's path can be
/// copied or sent to a bot.
struct FolderView: View {
    @Environment(LensStore.self) private var lens
    let path: String
    @AppStorage("filesShowHidden") private var showHidden = false
    @State private var folder: MacFolder?
    @State private var error: String?
    @State private var query = ""
    @State private var preview: URL?
    @State private var loadingFile: String?
    @State private var sendItem: SendItem?
    @State private var shareURL: ShareFile?
    @State private var textFile: TextFile?

    private var entries: [MacFile] {
        guard let folder else { return [] }
        guard !query.isEmpty else { return folder.entries }
        return folder.entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if !entries.isEmpty {
                Section { ForEach(entries) { file in row(file) } }
            }
        }
        .listStyle(.insetGrouped)
        .overlay { overlay }
        .searchable(text: $query, prompt: "Filter this folder")
        .navigationTitle(folder?.name ?? "Files")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task(id: showHidden) { await load() }
        .refreshable { await load() }
        .quickLookPreview($preview)
        .sheet(item: $sendItem) { SendToBotSheet(text: $0.text) }
        .sheet(item: $shareURL) { ShareSheet(url: $0.url) }
        .sheet(item: $textFile) { TextFileView(file: $0) }
    }

    @ViewBuilder
    private func row(_ file: MacFile) -> some View {
        let label = FileRow(file: file, loading: loadingFile == file.path)
        Group {
            if file.isFolder {
                NavigationLink(value: FolderLink(path: file.path)) { label }
            } else {
                Button { open(file) } label: { label }.buttonStyle(.plain)
            }
        }
        .contextMenu { actions(file) }
        .swipeActions(edge: .trailing) {
            Button { sendPath(file) } label: { Label("Send", systemImage: "paperplane") }.tint(.accentColor)
            Button { copyPath(file) } label: { Label("Copy path", systemImage: "doc.on.doc") }.tint(.gray)
        }
    }

    @ViewBuilder
    private func actions(_ file: MacFile) -> some View {
        Button { copyPath(file) } label: { Label("Copy path", systemImage: "doc.on.doc") }
        Button { sendPath(file) } label: { Label("Send path to a bot", systemImage: "paperplane") }
        if !file.isFolder {
            Button { open(file) } label: { Label("Preview", systemImage: "eye") }
            Button { share(file) } label: { Label("Share or save…", systemImage: "square.and.arrow.up") }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let folder {
                    Button { UIPasteboard.general.string = folder.absolute } label: {
                        Label("Copy this folder's path", systemImage: "doc.on.doc")
                    }
                    Button { sendItem = SendItem(text: folder.absolute) } label: {
                        Label("Send this folder to a bot", systemImage: "paperplane")
                    }
                }
                Toggle(isOn: $showHidden) { Label("Show hidden files", systemImage: "eye.slash") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Folder actions")
        }
    }

    @ViewBuilder private var overlay: some View {
        if let error {
            ContentUnavailableView {
                Label("Can't open this folder", systemImage: "folder.badge.questionmark")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { Task { await load() } }
            }
        } else if folder == nil {
            ProgressView()
        } else if entries.isEmpty {
            ContentUnavailableView(query.isEmpty ? "Empty folder" : "No matches", systemImage: "folder")
        }
    }

    // MARK: Actions

    private func load() async {
        do {
            folder = try await lens.folder(path, hidden: showHidden)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func absolute(_ file: MacFile) -> String { folder?.absolute(file) ?? file.path }

    private func copyPath(_ file: MacFile) {
        UIPasteboard.general.string = absolute(file)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func sendPath(_ file: MacFile) {
        sendItem = SendItem(text: absolute(file))
    }

    private func open(_ file: MacFile) {
        let path = absolute(file)
        fetch(file) { url in
            if TextFile.readable(file), let data = try? Data(contentsOf: url),
               let text = String(data: data, encoding: .utf8) {
                textFile = TextFile(name: file.name, path: path, text: text, url: url)
            } else {
                preview = url
            }
        }
    }

    private func share(_ file: MacFile) {
        fetch(file) { shareURL = ShareFile(url: $0) }
    }

    private func fetch(_ file: MacFile, then use: @escaping (URL) -> Void) {
        guard loadingFile == nil else { return }
        loadingFile = file.path
        Task {
            do { use(try await lens.download(file.path)) } catch { self.error = error.localizedDescription }
            loadingFile = nil
        }
    }
}

private struct FileRow: View {
    @Environment(LensStore.self) private var lens
    let file: MacFile
    let loading: Bool
    @State private var thumbnail: UIImage?

    var body: some View {
        ItemRow(title: file.name, subtitle: detail) {
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFill()
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else {
                IconTile(systemImage: file.isFolder ? "folder.fill" : symbol, tone: file.isFolder ? .working : nil)
            }
        } trailing: {
            if loading { ProgressView() }
            if file.link { Image(systemName: "arrow.turn.up.right").font(.caption2).foregroundStyle(Color.secondaryText) }
        }
        .contentShape(Rectangle())
        .task(id: file.path) {
            if file.isImage { thumbnail = try? await lens.fileThumbnail(file.path) }
        }
    }

    private var detail: String {
        let date = file.modified?.relative ?? ""
        if file.isFolder { return date }
        return ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file) + " · " + date
    }

    private var symbol: String {
        if file.isFolder { return "folder.fill" }
        let ext = (file.name as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext"
        case "md", "txt", "rtf", "log": return "doc.plaintext"
        case "swift", "py", "js", "ts", "tsx", "rs", "go", "cs", "c", "h", "cpp", "java", "kt", "rb", "sh", "json",
             "yaml", "yml", "toml", "html", "css": return "chevron.left.forwardslash.chevron.right"
        case "zip", "gz", "tar", "7z": return "doc.zipper"
        case "mov", "mp4", "m4v": return "film"
        case "mp3", "wav", "m4a", "aiff": return "waveform"
        case "png", "jpg", "jpeg", "gif", "webp", "heic": return "photo"
        default: return "doc"
        }
    }
}

/// A text, markdown or code file opened in the app's own viewer.
struct TextFile: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let text: String
    let url: URL

    private static let extensions: Set<String> = [
        "md", "markdown", "txt", "log", "json", "jsonl", "yaml", "yml", "toml", "ini", "cfg", "conf", "csv", "tsv",
        "swift", "py", "js", "mjs", "ts", "tsx", "jsx", "rs", "go", "cs", "c", "h", "cpp", "hpp", "m", "mm", "java",
        "kt", "rb", "php", "sh", "zsh", "bash", "fish", "sql", "html", "css", "scss", "xml", "plist", "gradle",
        "gitignore", "env", "dockerfile", "makefile", "lock", "tex", "bib", "r", "lua", "dart", "vue", "svelte", "astro",
    ]

    static func readable(_ file: MacFile) -> Bool {
        guard file.size <= 3_000_000 else { return false }
        let ext = (file.name as NSString).pathExtension.lowercased()
        return file.type.hasPrefix("text/") || extensions.contains(ext)
            || extensions.contains(file.name.lowercased())
    }

    var isMarkdown: Bool { ["md", "markdown"].contains((name as NSString).pathExtension.lowercased()) }
}

private struct TextFileView: View {
    let file: TextFile
    @Environment(\.dismiss) private var dismiss
    @State private var sendItem: SendItem?
    @State private var raw = false

    var body: some View {
        NavigationStack {
            Group {
                if file.isMarkdown && !raw {
                    ScrollView {
                        MarkdownText(file.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                } else {
                    // Code keeps its lines: scroll sideways rather than wrap.
                    ScrollView([.vertical, .horizontal]) {
                        Text(file.text)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .padding()
                    }
                    .defaultScrollAnchor(.topLeading)
                }
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if file.isMarkdown { Toggle("Show source", isOn: $raw) }
                        Button { UIPasteboard.general.string = file.path } label: { Label("Copy path", systemImage: "doc.on.doc") }
                        Button { UIPasteboard.general.string = file.text } label: { Label("Copy contents", systemImage: "doc.on.clipboard") }
                        Button { sendItem = SendItem(text: file.path) } label: { Label("Send path to a bot", systemImage: "paperplane") }
                        ShareLink(item: file.url) { Label("Share or save…", systemImage: "square.and.arrow.up") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(item: $sendItem) { SendToBotSheet(text: $0.text) }
        }
    }
}

struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
