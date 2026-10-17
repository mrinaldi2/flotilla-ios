import PDFKit
import SwiftUI
import WebKit

// A card's document, read on the phone (0.20): Markdown formatted, an HTML
// page in a web view with no network, text, PDFs and images.

/// The document screen, in its own navigation stack (a sheet).
struct DocumentScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let source: DocumentSource
    @State private var state: Loaded?

    private enum Loaded {
        case ready(DocumentFile, DocumentKind)
        case none(String)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case nil:
                    ProgressView()
                case .ready(let file, let kind)?:
                    content(file, kind)
                case .none(let why)?:
                    ContentUnavailableView("No preview", systemImage: "doc", description: Text(why))
                case .failed(let why)?:
                    ContentUnavailableView("Couldn’t open \(source.name)", systemImage: "exclamationmark.triangle", description: Text(why))
                }
            }
            .navigationTitle(source.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task(id: source) { await load() }
    }

    @ViewBuilder private func content(_ file: DocumentFile, _ kind: DocumentKind) -> some View {
        switch kind {
        case .html:
            PageView(source: source, store: store)
                .ignoresSafeArea(edges: .bottom)
        case .markdown:
            ScrollView {
                MarkdownText(file.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        case .text:
            ScrollView([.vertical, .horizontal]) {
                Text(file.text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
            }
        case .pdf:
            if let document = PDFDocument(data: file.data) {
                DocumentPDF(document: document)
            } else {
                ContentUnavailableView("Couldn’t read the PDF", systemImage: "doc")
            }
        case .image:
            if let image = UIImage(data: file.data) {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
                }
            } else {
                ContentUnavailableView("Couldn’t read the image", systemImage: "photo")
            }
        }
    }

    private func load() async {
        do {
            let file = try await store.readDocument(source, path: source.path)
            if let kind = DocumentKind(mime: file.mime, name: source.name) {
                state = .ready(file, kind)
            } else {
                state = .none("This kind of file (\(file.mime)) can't be shown here.")
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

/// An HTML page: loaded from `flotilla-doc://`, its relative files read
/// through the app, no network, no bridge to the app. A link tapped to the
/// web opens in Safari.
struct PageView: UIViewRepresentable {
    let source: DocumentSource
    let store: AppStore

    func makeCoordinator() -> PageCoordinator { PageCoordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let absolute = source.path.hasPrefix("/")
        configuration.setURLSchemeHandler(DocumentSchemeHandler(store: store, source: source, absolute: absolute),
                                          forURLScheme: DocumentURL.scheme)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsLinkPreview = false
        if let url = DocumentURL.url(for: source.path) { view.load(URLRequest(url: url)) }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}

@MainActor
final class PageCoordinator: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if url.scheme == DocumentURL.scheme { return .allow }
        // The owner tapped a link out of the page: the web, in Safari.
        if action.navigationType == .linkActivated, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            await UIApplication.shared.open(url)
        }
        return .cancel
    }
}

/// Answers the page's `flotilla-doc://` requests from the daemon.
private final class DocumentSchemeHandler: NSObject, WKURLSchemeHandler {
    private let store: AppStore
    private let source: DocumentSource
    private let absolute: Bool
    @MainActor private var stopped = Set<ObjectIdentifier>()

    init(store: AppStore, source: DocumentSource, absolute: Bool) {
        self.store = store
        self.source = source
        self.absolute = absolute
    }

    @MainActor
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        guard let url = task.request.url, let path = DocumentURL.path(of: url, absolute: absolute) else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        Task { @MainActor in
            do {
                let file = try await store.readDocument(source, path: path)
                guard !stopped.contains(id) else { return }
                let mime = file.mime.isEmpty || file.mime == "text/plain" ? AppStore.mime(for: path) : file.mime
                let headers = ["Content-Type": mime.hasPrefix("text/") ? "\(mime); charset=utf-8" : mime,
                               "Content-Security-Policy": DocumentURL.policy,
                               "Content-Length": "\(file.data.count)"]
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)
                    ?? URLResponse(url: url, mimeType: mime, expectedContentLength: file.data.count, textEncodingName: "utf-8")
                task.didReceive(response)
                task.didReceive(file.data)
                task.didFinish()
            } catch {
                guard !stopped.contains(id) else { return }
                let missing = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])
                if let missing { task.didReceive(missing) }
                task.didFinish()
            }
            stopped.remove(id)
        }
    }

    @MainActor
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }
}

private struct DocumentPDF: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = document
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}
}
