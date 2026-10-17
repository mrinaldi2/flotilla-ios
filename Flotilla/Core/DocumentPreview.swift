import Foundation

// Reading a card's documents on the phone (0.20): Markdown formatted, an
// HTML page in a web view, text, PDFs and images. A page's relative files
// (its CSS, images, scripts) come through the app's own connection to the
// daemon, so it shows without any server and reaches nothing else.

/// How a document is read.
enum DocumentKind: Equatable {
    case markdown, html, text, pdf, image

    init?(mime: String, name: String) {
        let lower = name.lowercased()
        if mime == "text/markdown" || lower.hasSuffix(".md") || lower.hasSuffix(".markdown") {
            self = .markdown
        } else if mime == "text/html" || lower.hasSuffix(".html") || lower.hasSuffix(".htm") {
            self = .html
        } else if mime == "application/pdf" || lower.hasSuffix(".pdf") {
            self = .pdf
        } else if mime.hasPrefix("image/") {
            self = .image
        } else if mime.hasPrefix("text/") || [".txt", ".log", ".json", ".csv", ".yml", ".yaml", ".toml"].contains(where: lower.hasSuffix) {
            self = .text
        } else {
            return nil
        }
    }
}

/// Where a document comes from, on the computer the screen talks to.
enum DocumentSource: Hashable {
    /// A file attached to a card: one file, nothing beside it.
    case attachment(id: String, name: String, mime: String)
    /// A file in the project's artifacts (a card's linked document), by its
    /// path there; a page's files are read beside it.
    case artifact(projectId: String, path: String, name: String)
    /// A bot's file (its folder or the artifacts), by the path it gave.
    case botFile(botId: String, path: String, name: String)

    var name: String {
        switch self {
        case .attachment(_, let name, _), .artifact(_, _, let name), .botFile(_, _, let name): name
        }
    }

    /// The path the page is read at, which its relative links start from.
    var path: String {
        switch self {
        case .attachment(_, let name, _): (name as NSString).lastPathComponent
        case .artifact(_, let path, _), .botFile(_, let path, _): path
        }
    }
}

/// The page's own URL scheme: every file it loads goes through the app.
enum DocumentURL {
    static let scheme = "flotilla-doc"

    /// `flotilla-doc://page/<path>`; an absolute path keeps its root, as `//`.
    static func url(for path: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "page"
        components.path = "/" + path
        return components.url
    }

    /// The path a page's request is for, as the source reads it: an
    /// artifact's relative to the artifacts folder, a bot file's as given.
    static func path(of url: URL, absolute: Bool) -> String? {
        guard url.scheme == scheme, url.host == "page" else { return nil }
        let path = url.path
        if absolute { return path.hasPrefix("//") ? String(path.dropFirst()) : path }
        let relative = path.drop { $0 == "/" }
        return relative.isEmpty ? nil : String(relative)
    }

    /// Only the app's own files: inline styles and scripts run, nothing
    /// is fetched from the network.
    static let policy = "default-src \(scheme): data: blob: 'unsafe-inline'; connect-src 'none'; frame-src 'none'"
}

/// A document's bytes and type.
struct DocumentFile {
    let data: Data
    let mime: String

    var text: String { String(decoding: data, as: UTF8.self) }
}

extension AppStore {
    /// A file in the project's artifacts (`read_file` with `project_id`).
    func readArtifact(projectId: String, path: String) async throws -> DaemonFile {
        let reply = try await client.request("read_file", ["project_id": projectId, "path": path])
        guard let row = reply.dict("file") else {
            throw DaemonError(code: "not_found", message: "The Flotilla service did not return the file.")
        }
        return DaemonFile(row)
    }

    /// The source's file at `path` (the document itself, or a file beside a page).
    func readDocument(_ source: DocumentSource, path: String) async throws -> DocumentFile {
        switch source {
        case .attachment(let id, let name, let mime):
            // An attached page is one file: what it links beside it isn't attached.
            guard path == source.path else { throw DaemonError(code: "not_found", message: "\(path) isn't attached.") }
            return DocumentFile(data: try await attachmentData(id), mime: mime.isEmpty ? Self.mime(for: name) : mime)
        case .artifact(let projectId, _, _):
            return Self.document(try await readArtifact(projectId: projectId, path: path))
        case .botFile(let botId, _, _):
            return Self.document(try await readFile(botId: botId, path: path))
        }
    }

    private static func document(_ file: DaemonFile) -> DocumentFile {
        DocumentFile(data: file.data ?? Data((file.text ?? "").utf8), mime: file.mime)
    }

    static func mime(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "html", "htm": "text/html"
        case "md", "markdown": "text/markdown"
        case "css": "text/css"
        case "js", "mjs": "text/javascript"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "pdf": "application/pdf"
        case "json": "application/json"
        default: "text/plain"
        }
    }
}
