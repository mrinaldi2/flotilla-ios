import Foundation
import Observation
import UIKit

// Gravity Lens: the companion on each computer (companion/gravity_lens.py) that
// turns each bot's Claude Code log into readable turns. Its JSON is ours, so
// it is decoded strictly.

struct LensTrigger: Decodable, Hashable {
    /// `message`, `typed`, `background` or `continued`.
    let kind: String
    let from: String
    let msgKind: String
    let text: String
}

struct LensOutcome: Decodable, Hashable {
    /// `text`, `message`, `completed` or `none`.
    let kind: String
    let text: String
    let to: String
}

/// An image a turn touched: one the bot opened, or a file its work mentions.
struct LensImageRef: Decodable, Hashable, Identifiable {
    let id: String
    /// `inline` (kept in the log) or `file` (read from disk when asked for).
    let kind: String
    let name: String
    let path: String
    /// False when the file has since been deleted.
    let exists: Bool?
}

struct LensStats: Decodable, Hashable {
    let images: Int
    let commands: Int
    let reads: Int
    let edits: Int
    let added: Int
    let removed: Int
    let sent: Int
    let incoming: Int
    let errors: Int
    let steps: Int
    let files: [String]
}

struct LensTurn: Decodable, Identifiable, Hashable {
    let id: String
    let startedAt: String
    let updatedAt: String
    let endedAt: String?
    let durationMs: Int?
    /// Still running: no end marker yet and it is the bot's latest turn.
    let open: Bool
    let trigger: LensTrigger
    let outcome: LensOutcome
    let stats: LensStats
    /// Title of the latest step, for "now doing".
    let current: String
    let botId: String?
    let botName: String?
    let cover: LensImageRef?

    var started: Date? { WireDate.parse(startedAt) }
    var updated: Date? { WireDate.parse(updatedAt) }
}

struct LensEvent: Decodable, Identifiable, Hashable {
    let id: String
    let at: String
    /// `tool`, `text`, `incoming`, `sent`, `completed` or `compacted`.
    let kind: String
    let title: String
    let subtitle: String?
    let tool: String?
    let error: Bool?
    let added: Int?
    let removed: Int?
    let path: String?
    let text: String?
    let to: String?
    let from: String?
    let msgKind: String?
    let artifacts: [String]?
    let minor: Bool?
    let hasDetail: Bool?
    let images: [LensImageRef]?
    /// From the daemon's chat: a step still running, a decision raised, a task completed.
    let running: Bool?
    let decisionId: String?
    let taskId: String?

    var date: Date? { WireDate.parse(at) }
}

struct LensEventDetail: Decodable {
    let event: LensEvent?
    let input: String?
    let command: String?
    let output: String?
    let diff: [String]?
    let content: String?
}

struct LensArtifact: Decodable, Identifiable, Hashable {
    let project: String
    let name: String
    let title: String
    let size: Int
    let modifiedAt: String

    var id: String { "\(project)/\(name)" }
    var modified: Date? { WireDate.parse(modifiedAt) }
}

private struct OverviewReply: Decodable {
    struct Row: Decodable {
        let botId: String
        let lastTurn: LensTurn?
    }
    let bots: [Row]
}

private struct TurnsReply: Decodable {
    let turns: [LensTurn]
    let hasMore: Bool?
}

private struct TurnReply: Decodable {
    let turn: LensTurn
    let events: [LensEvent]
}

/// A file or folder on the Mac, from the file browser.
struct MacFile: Decodable, Identifiable, Hashable {
    let name: String
    /// `~/…` for display.
    let path: String
    let kind: String
    let link: Bool
    let size: Int
    let modifiedAt: String
    let type: String

    var id: String { path }
    var isFolder: Bool { kind == "folder" }
    var modified: Date? { WireDate.parse(modifiedAt) }
    var isImage: Bool { type.hasPrefix("image/") }
}

struct MacFolder: Decodable {
    let path: String
    let absolute: String
    let name: String
    let parent: String?
    let roots: [String]
    let entries: [MacFile]

    /// The absolute path of an entry, for copying and sending to bots.
    func absolute(_ file: MacFile) -> String { (absolute as NSString).appendingPathComponent(file.name) }
}

/// One of the Mac's displays, in points, as macOS arranges them.
struct MacDisplay: Codable, Hashable {
    let id: Int
    let main: Bool
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

private struct DisplaysReply: Decodable { let displays: [MacDisplay] }
private struct ArtifactsReply: Decodable { let artifacts: [LensArtifact] }
private struct ServerMessage: Decodable { let message: String? }
private struct ArtifactReply: Decodable { let text: String }

enum LensStatus: Equatable {
    case unknown
    case ok
    case unauthorized
    case unreachable(String)

    var label: String {
        switch self {
        case .unknown: "Checking…"
        case .ok: "Connected"
        case .unauthorized: "Token rejected"
        case .unreachable: "Not reachable"
        }
    }
}

@MainActor
@Observable
final class LensStore {
    var status: LensStatus = .unknown
    /// bot id → its latest turn.
    var latest: [String: LensTurn] = [:]
    var feed: [LensTurn] = []
    var artifacts: [LensArtifact] = []
    /// project id → the cursor of its next page of files, while it has more.
    var artifactCursors: [String: String] = [:]
    /// From the daemon's chat: bot id → its loaded turns, oldest first.
    var chats: [String: [ChatTurn]] = [:]
    /// bot id → older turns exist than the ones loaded.
    var chatHasMore: [String: Bool] = [:]

    /// Turns, steps, images and reports come from the daemon when it serves
    /// chat; Gravity Lens is then used only for files and the screen layout.
    var fromDaemon: Bool { app.hasChat }

    @ObservationIgnored private let app: AppStore
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let decoder: JSONDecoder
    @ObservationIgnored private let imageCache = NSCache<NSString, UIImage>()

    static let defaultPort = 49778

    /// Where this computer's Lens answers; set from its saved settings.
    @ObservationIgnored var host = ""
    var port = LensStore.defaultPort

    init(app: AppStore) {
        self.app = app
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        app.onChatTurns = { [weak self] botId, rows in self?.merge(botId, ChatDecoding.turns(rows)) }
    }

    // MARK: Requests

    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        let data = try await fetch(path, query)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw DaemonError(code: "decode", message: "Unexpected reply from Lens (\(error)).")
        }
    }

    private func fetch(_ path: String, _ query: [String: String] = [:]) async throws -> Data {
        guard let endpoint = app.endpoint else {
            throw DaemonError(code: "not_connected", message: "No computer configured.")
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = path
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components.url else { throw DaemonError(code: "invalid", message: "Bad Lens address.") }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 {
                status = .unauthorized
                throw DaemonError(code: "unauthorized", message: "Lens rejected the device token.")
            }
            guard code == 200 else {
                let message = (try? decoder.decode(ServerMessage.self, from: data))?.message
                throw DaemonError(code: "http_\(code)", message: message ?? "Lens answered \(code).")
            }
            status = .ok
            return data
        } catch let error as DaemonError {
            throw error
        } catch {
            status = .unreachable(error.localizedDescription)
            throw error
        }
    }

    private func encode(_ part: String) -> String {
        part.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? part
    }

    // MARK: Loading

    /// Everything at once: on opening and on (re)connecting.
    func refresh() async {
        if fromDaemon {
            await refreshChats(onlyNew: false)
            return
        }
        async let overview: OverviewReply? = try? get("/v1/overview")
        async let recent: TurnsReply? = try? get("/v1/feed", ["limit": String(Page.size)])
        if let overview = await overview {
            latest = Dictionary(overview.bots.compactMap { row in row.lastTurn.map { (row.botId, $0) } },
                                uniquingKeysWith: { first, _ in first })
        }
        if let recent = await recent { feed = recent.turns }
    }

    func turns(bot: String, before: String? = nil) async throws -> (turns: [LensTurn], hasMore: Bool) {
        if fromDaemon {
            let page = try await chatPage(bot, before: before, limit: Page.turns)
            return (page.turns.reversed().compactMap { $0.lensTurn(botName: app.bot(bot)?.name) }, page.hasMore)
        }
        var query = ["limit": String(Page.turns)]
        if let before { query["before"] = before }
        let reply: TurnsReply = try await get("/v1/bots/\(encode(bot))/turns", query)
        return (reply.turns, reply.hasMore ?? false)
    }

    func turn(bot: String, id: String) async throws -> (turn: LensTurn, events: [LensEvent]) {
        if fromDaemon {
            var found = chats[bot]?.first { $0.id == id }
            if found == nil {
                found = try await chatPage(bot, before: nil, limit: 200).turns.first { $0.id == id }
            }
            guard let chatTurn = found, let turn = chatTurn.lensTurn(botName: app.bot(bot)?.name) else {
                throw DaemonError(code: "not_found", message: "That turn is no longer in the bot's transcript.")
            }
            return (turn, chatTurn.lensEvents)
        }
        let reply: TurnReply = try await get("/v1/bots/\(encode(bot))/turns/\(encode(id))")
        return (reply.turn, reply.events)
    }

    func detail(bot: String, event: String) async throws -> LensEventDetail {
        if fromDaemon {
            let reply = try await app.client.request("get_chat_step", ["bot_id": bot, "item_id": event])
            let row = reply.dict("detail") ?? [:]
            guard let data = try? JSONSerialization.data(withJSONObject: row),
                  let detail = try? decoder.decode(LensEventDetail.self, from: data) else {
                throw DaemonError(code: "decode", message: "Unexpected step detail from the Flotilla service.")
            }
            return detail
        }
        return try await get("/v1/bots/\(encode(bot))/events/\(encode(event))")
    }

    enum ImageSource: Hashable {
        case bot(String, LensImageRef)
        case report(project: String, name: String, src: String)
        /// A card's attachment, read from the board's home (`attachment_read`, K7).
        case attachment(id: String, name: String)

        var title: String {
            switch self {
            case .bot(_, let ref): ref.name
            case .report(_, _, let src): (src as NSString).lastPathComponent
            case .attachment(_, let name): name
            }
        }
    }

    func image(_ source: ImageSource, thumb: Bool) async throws -> UIImage {
        let key: String
        let path: String
        var query = ["size": thumb ? "thumb" : "full"]
        if case .attachment(let id, _) = source { return try await attachmentImage(id, thumb: thumb) }
        switch source {
        case .bot(let bot, let ref):
            key = "\(bot)/\(ref.id)"
            path = "/v1/bots/\(encode(bot))/images/\(encode(ref.id))"
        case .report(let project, let name, let src):
            key = "\(project)/\(name)/\(src)"
            path = "/v1/artifacts/\(encode(project))/\(encode(name))/image"
            query["src"] = src
        case .attachment:
            throw DaemonError(code: "image", message: "Not an image.")
        }
        let cacheKey = "\(key)#\(thumb)" as NSString
        if let cached = imageCache.object(forKey: cacheKey) { return cached }
        let data = fromDaemon ? try await daemonImage(source) : try await fetch(path, query)
        guard var image = UIImage(data: data) else {
            throw DaemonError(code: "image", message: "Not an image the phone can show.")
        }
        // The daemon sends images whole; thumbnails are made here.
        if fromDaemon, thumb, let small = await image.byPreparingThumbnail(ofSize: Self.thumbSize(image.size)) {
            image = small
        }
        imageCache.setObject(image, forKey: cacheKey)
        return image
    }

    // MARK: Displays

    func displays() async throws -> [MacDisplay] {
        let reply: DisplaysReply = try await get("/v1/displays")
        return reply.displays
    }

    // MARK: Files

    func folder(_ path: String, hidden: Bool) async throws -> MacFolder {
        try await get("/v1/files", ["path": path, "hidden": hidden ? "1" : "0"])
    }

    /// Downloads a file into the app's cache under its own name, for preview and sharing.
    func download(_ path: String) async throws -> URL {
        let data = try await fetch("/v1/files/raw", ["path": path])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mac-files/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent((path as NSString).lastPathComponent)
        try data.write(to: url)
        return url
    }

    func fileThumbnail(_ path: String) async throws -> UIImage {
        let key = "file:\(path)" as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        let data = try await fetch("/v1/files/raw", ["path": path, "size": "thumb"])
        guard let image = UIImage(data: data) else { throw DaemonError(code: "image", message: "Not an image.") }
        imageCache.setObject(image, forKey: key)
        return image
    }

    func loadArtifacts() async {
        if fromDaemon {
            await loadDaemonArtifacts()
            return
        }
        if let reply: ArtifactsReply = try? await get("/v1/artifacts") { artifacts = reply.artifacts }
    }

    func artifact(project: String, name: String) async throws -> String {
        if fromDaemon {
            let file = try await readFile(["project_id": project, "path": name])
            return file.text ?? ""
        }
        let reply: ArtifactReply = try await get("/v1/artifacts/\(encode(project))/\(encode(name))")
        return reply.text
    }

    /// `~/.flotilla/projects/<project>/artifacts/<name>` → its report, if it is one.
    func report(forPath path: String) -> (project: String, name: String)? {
        let parts = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
        guard let index = parts.lastIndex(of: "artifacts"), index >= 2, index + 1 < parts.count,
              parts[index - 2] == "projects" else { return nil }
        guard fromDaemon else { return (parts[index - 1], parts[index + 1]) }
        // The daemon names projects by id and artifacts by their path inside the folder.
        guard let project = app.projects.first(where: { $0.dirName == parts[index - 1] })
                ?? app.projects.first(where: { $0.name == parts[index - 1] }) else { return nil }
        return (project.id, parts[(index + 1)...].joined(separator: "/"))
    }

    // MARK: Daemon chat

    /// The newest turns of every bot. Listing a chat also makes the daemon
    /// push its changes (`chat_turns`), so after this the feed follows by
    /// itself. A bot already loaded needs only its latest turn, to subscribe
    /// again after a reconnect: every bot's last ten turns came to over half a
    /// megabyte, a burst a phone on a mobile link pays on every reconnect.
    private func refreshChats(onlyNew: Bool) async {
        for bot in app.bots {
            let known = chats[bot.id] != nil
            if onlyNew, known { continue }
            _ = try? await chatPage(bot.id, before: nil, limit: known ? 1 : 3)
        }
    }

    /// A bot's chat for its Chat pane: the newest page, if nothing is loaded yet.
    func loadChat(_ botId: String) async throws {
        _ = try await chatPage(botId, before: nil, limit: Page.turns)
    }

    /// After the bot's conversation was cleared: forget its turns and load the new, empty chat.
    func resetChat(_ botId: String) async {
        chats[botId] = nil
        chatHasMore[botId] = nil
        latest[botId] = nil
        rebuildFeed()
        try? await loadChat(botId)
    }

    func loadOlderChat(_ botId: String) async throws {
        guard let list = chats[botId], let first = list.first else { return try await loadChat(botId) }
        let limit = ChatPaging.earlierLimit(loaded: list.count)
        guard limit > 0 else { return }
        _ = try await chatPage(botId, before: first.id, limit: limit)
    }

    private func chatPage(_ botId: String, before: String?, limit: Int) async throws -> (turns: [ChatTurn], hasMore: Bool) {
        var fields: JSONDict = ["bot_id": botId, "limit": limit]
        if let before { fields["before"] = before }
        let reply = try await app.client.request("list_chat", fields)
        let turns = ChatDecoding.turns(reply.list("turns"))
        let hasMore = reply.bool("has_more")
        let wasEmpty = chats[botId]?.isEmpty ?? true
        merge(botId, turns)
        // Only a page that reaches the oldest loaded turn says whether more exist.
        if wasEmpty || before != nil || turns.first?.id == chats[botId]?.first?.id {
            chatHasMore[botId] = hasMore
        }
        status = .ok
        return (turns, hasMore)
    }

    /// New or changed turns, from a page or a push, merged by id.
    private func merge(_ botId: String, _ turns: [ChatTurn]) {
        guard !turns.isEmpty else { return }
        var list = chats[botId] ?? []
        for turn in turns {
            if let index = list.firstIndex(where: { $0.id == turn.id }) {
                list[index] = turn
            } else {
                list.append(turn)
            }
        }
        list.sort { $0.startedAt < $1.startedAt }
        // Live turns past the cap push the oldest out (H-228): the chat stays bounded.
        let (kept, dropped) = ChatPaging.trimmed(list)
        chats[botId] = kept
        if dropped { chatHasMore[botId] = true }
        list = kept
        let name = app.bot(botId)?.name
        latest[botId] = list.last?.lensTurn(botName: name)
        rebuildFeed()
    }

    private func rebuildFeed() {
        var all: [LensTurn] = []
        for (botId, turns) in chats {
            let name = app.bot(botId)?.name
            all += turns.suffix(20).compactMap { $0.lensTurn(botName: name) }
        }
        feed = Array(all.sorted { $0.updatedAt > $1.updatedAt }.prefix(60))
    }

    private func readFile(_ fields: JSONDict) async throws -> DaemonFile {
        let reply = try await app.client.request("read_file", fields)
        guard let row = reply.dict("file") else {
            throw DaemonError(code: "not_found", message: "The Flotilla service did not return the file.")
        }
        return DaemonFile(row)
    }

    private func daemonImage(_ source: ImageSource) async throws -> Data {
        let file: DaemonFile
        switch source {
        case .bot(let bot, let ref):
            let reply = try await app.client.request("get_chat_image", ["bot_id": bot, "image_id": ref.id])
            file = DaemonFile(reply.dict("file") ?? [:])
        case .report(let project, let name, let src):
            file = try await readFile(["project_id": project, "path": Self.resolve(src, besideFile: name)])
        case .attachment(let id, _):
            return try await app.attachmentData(id)
        }
        guard let data = file.data else { throw DaemonError(code: "image", message: "Not an image.") }
        return data
    }

    /// An attachment's image, whole from the daemon; the thumbnail is made here.
    private func attachmentImage(_ id: String, thumb: Bool) async throws -> UIImage {
        let cacheKey = "attachment/\(id)#\(thumb)" as NSString
        if let cached = imageCache.object(forKey: cacheKey) { return cached }
        guard var image = UIImage(data: try await app.attachmentData(id)) else {
            throw DaemonError(code: "image", message: "Not an image the phone can show.")
        }
        if thumb, let small = await image.byPreparingThumbnail(ofSize: Self.thumbSize(image.size)) { image = small }
        imageCache.setObject(image, forKey: cacheKey)
        return image
    }

    /// A report's image path, relative to the report, as a path inside the artifacts folder.
    static func resolve(_ src: String, besideFile file: String) -> String {
        var parts = file.split(separator: "/").map(String.init).dropLast()
        for part in src.split(separator: "/").map(String.init) {
            switch part {
            case ".", "": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return parts.joined(separator: "/")
    }

    private static func thumbSize(_ size: CGSize) -> CGSize {
        let scale = min(1, 480 / max(size.width, size.height, 1))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private static let reportSuffixes = [".md", ".markdown", ".txt", ".json", ".csv", ".log", ".yaml", ".yml", ".toml"]

    /// Each project's newest page of files, keeping the reports among them.
    private func loadDaemonArtifacts() async {
        var found: [LensArtifact] = []
        var cursors: [String: String] = [:]
        for project in app.projects {
            guard let page = await artifactPage(project.id, before: nil) else { continue }
            found += page.reports
            if let next = page.next { cursors[project.id] = next }
        }
        artifacts = found.sorted { $0.modifiedAt > $1.modifiedAt }
        artifactCursors = cursors
        status = .ok
    }

    /// The next page of every project that has more.
    func loadMoreArtifacts() async {
        var found = artifacts
        for (project, cursor) in artifactCursors {
            guard let page = await artifactPage(project, before: cursor) else { continue }
            let fresh = Set(page.reports.map(\.id))
            found = found.filter { !fresh.contains($0.id) } + page.reports
            artifactCursors[project] = page.next
        }
        artifacts = found.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private func artifactPage(_ projectId: String, before: String?) async -> (reports: [LensArtifact], next: String?)? {
        var fields: JSONDict = ["project_id": projectId, "limit": Page.size]
        if let before { fields["before"] = before }
        guard let reply = try? await app.client.request("list_artifacts", fields) else { return nil }
        let reports: [LensArtifact] = reply.list("artifacts").compactMap { row in
            let rel = row.str("rel").isEmpty ? row.str("name") : row.str("rel")
            guard Self.reportSuffixes.contains(where: { rel.lowercased().hasSuffix($0) }) else { return nil }
            let name = row.str("name")
            return LensArtifact(project: projectId, name: rel,
                                title: row.optStr("title") ?? (name as NSString).deletingPathExtension,
                                size: row.int("size"), modifiedAt: row.str("modified"))
        }
        // An older daemon sends every file and no `has_more`: nothing more to load.
        return (reports, reply.bool("has_more") ? reply.optStr("next_before") : nil)
    }

    /// Keeps the feed and "now doing" lines fresh while the app is open.
    func poll() async {
        var last = Date.distantPast
        var wasConnected = false
        while !Task.isCancelled {
            let connected = app.status == .connected && !app.inBackground
            // The daemon pushes chat changes; a slow refresh only catches new bots.
            let interval: TimeInterval = fromDaemon ? 60 : (app.bots.contains { $0.state == .working } ? 4 : 10)
            // Straight away on (re)connecting, then on the interval.
            if connected, !wasConnected {
                await refresh()
                last = Date()
            } else if connected, Date().timeIntervalSince(last) >= interval {
                // Pushes keep loaded chats current: only new bots need a look.
                if fromDaemon { await refreshChats(onlyNew: true) } else { await refresh() }
                last = Date()
            }
            wasConnected = connected
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
