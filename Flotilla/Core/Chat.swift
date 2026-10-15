import Foundation

// A bot's chat as the daemon serves it (`list_chat`, `chat_turns`): the same
// turns Gravity Lens used to make from the transcripts, now parsed by gravityd.
// See docs/superpowers/specs/2026-09-16-chat-pane-design.md in Gravity.

/// How far back the phone's chat goes (H-228): the newest page and up to
/// `earlierPages` more. Live turns count too: past the cap the oldest go.
enum ChatPaging {
    static let earlierPages = 5
    static var cap: Int { Page.turns * (1 + earlierPages) }

    static func canLoadEarlier(loaded: Int, hasMore: Bool) -> Bool {
        hasMore && loaded < cap
    }

    /// Older turns to ask for: a page, or what is left under the cap.
    static func earlierLimit(loaded: Int) -> Int { max(0, min(Page.turns, cap - loaded)) }

    /// The newest `cap` turns, and whether older ones were dropped.
    static func trimmed<T>(_ turns: [T]) -> (turns: [T], dropped: Bool) {
        turns.count > cap ? (Array(turns.suffix(cap)), true) : (turns, false)
    }

    /// At the cap (UX): where the rest is, without a link.
    static func capped(computer: String, bot: String) -> String {
        let place = computer.isEmpty ? "its computer" : computer
        return "Earlier activity is on \(place). Open \(bot) in The Hermes app there to see all of it."
    }
}

struct ChatTurn: Decodable, Identifiable, Equatable {
    let id: String
    let botId: String
    let startedAt: String
    let endedAt: String?
    let durationMs: Int?
    let open: Bool
    let trigger: ChatTrigger
    let items: [ChatItem]
    let stats: ChatStats
}

/// What woke the bot. `kind`: owner, bus, routine, ruling, resumed, background.
struct ChatTrigger: Decodable, Equatable {
    let kind: String
    let text: String?
    /// Owner: `chat` (the app's composer) or `terminal`.
    let via: String?
    let from: String?
    let msgKind: String?
    let num: Int?
    let taskId: String?
    /// Routine: its name.
    let name: String?
    let runId: String?
    let decisionId: String?
}

/// One thing in a turn. `type`: text, step, sent, completed, decision, aside.
struct ChatItem: Decodable, Equatable, Identifiable {
    let type: String
    let id: String
    let markdown: String?
    // step
    let tool: String?
    let title: String?
    let subtitle: String?
    /// running, ok or error.
    let status: String?
    let minor: Bool?
    let added: Int?
    let removed: Int?
    let images: [ChatImageRef]?
    // sent
    let to: String?
    let msgKind: String?
    let body: String?
    // completed
    let taskId: String?
    let result: String?
    let artifacts: [ChatFileRef]?
    // decision
    let decisionId: String?
    // aside: compacted, interrupted, incoming
    let kind: String?
    let text: String?
}

struct ChatImageRef: Decodable, Equatable {
    let id: String
    let mime: String
}

struct ChatFileRef: Decodable, Equatable {
    let path: String
    let name: String
}

struct ChatStats: Decodable, Equatable {
    let commands: Int
    let reads: Int
    let edits: Int
    let added: Int
    let removed: Int
    let sent: Int
    let images: Int
    let errors: Int
}

/// A file the daemon sends back (`read_file`, `get_chat_image`).
struct DaemonFile {
    let name: String
    let mime: String
    let text: String?
    let data: Data?
    /// Only the first 16 MB came back.
    let truncated: Bool

    init(_ d: JSONDict) {
        name = d.str("name")
        mime = d.str("mime")
        text = d["text"] as? String
        data = (d["base64"] as? String).flatMap { Data(base64Encoded: $0) }
        truncated = d.bool("truncated")
    }
}

/// A file in a project's shared artifacts folder (`list_artifacts`),
/// including files that arrived from bots on another computer.
/// One page of a project's files (`list_artifacts`).
struct ArtifactPage {
    let files: [ArtifactFile]
    let hasMore: Bool
    /// Opaque: passed back as `before` for the next page.
    let nextBefore: String?

    /// `page` folded into what is loaded, newest first. A file is known by
    /// its place in the folder, so an edited one moves up instead of doubling.
    static func merge(_ loaded: [ArtifactFile], _ page: [ArtifactFile]) -> [ArtifactFile] {
        let fresh = Set(page.map(\.rel))
        return (loaded.filter { !fresh.contains($0.rel) } + page)
            .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }
}

struct ArtifactFile: Identifiable, Hashable {
    /// Absolute, on the computer that holds it.
    let path: String
    /// Inside the artifacts folder, "/"-separated.
    let rel: String
    let name: String
    let size: Int
    let modified: Date?
    let mime: String
    /// A markdown file's first heading.
    let title: String?
    /// Who made the file, when the daemon can tell.
    let createdBy: FileCreator?

    var id: String { path }

    init(_ d: JSONDict) {
        path = d.str("path")
        rel = d.str("rel").isEmpty ? d.str("name") : d.str("rel")
        name = d.str("name")
        size = d.int("size")
        modified = d.date("modified")
        mime = d.str("mime")
        title = d.optStr("title")
        createdBy = d.dict("created_by").map(FileCreator.init)
    }
}

/// Who made an artifact (`created_by` in `list_artifacts`): a bot, or the
/// owner when there is no `bot_id`.
struct FileCreator: Hashable {
    let botId: String?
    let name: String
    /// Empty for the owner.
    let avatar: String
    /// The peer the bot runs on, for one on another machine.
    let machine: String?
    /// wrote, edited, command, upload or sent.
    let via: String

    init(_ d: JSONDict) {
        botId = d.optStr("bot_id")
        name = d.str("name")
        avatar = d.str("avatar")
        machine = d.optStr("machine")
        via = d.str("via")
    }

    /// The owner made it (an upload from the app): no avatar.
    var isOwner: Bool { botId == nil }

    /// "written by lead", "sent by windev @ win-pc", "uploaded by you".
    var label: String {
        let base: String
        switch via {
        case "wrote": base = "written by \(name)"
        case "edited": base = "first edited by \(name)"
        case "command": base = "made by a command of \(name)"
        case "upload": base = "uploaded by you"
        case "sent": base = "sent by \(name)"
        default: base = "made by \(name)"
        }
        return machine.map { "\(base) @ \($0)" } ?? base
    }
}

/// A task a bot was given or handed out (`list_tasks`, `get_task`).
struct BotTask: Identifiable, Equatable {
    let id: String
    /// open, done, cancelled or expired.
    let state: String
    /// `assigned`: this bot was asked; `delegated`: it asked someone else.
    let role: String
    let otherName: String
    /// Set when the other bot runs on a peer machine.
    let otherMachine: String?
    let request: String
    let requestTruncated: Bool
    let result: String?
    let resultTruncated: Bool
    let createdAt: Date?
    let deadlineAt: Date?
    let closedAt: Date?

    init(_ d: JSONDict) {
        id = d.str("id")
        state = d.str("state")
        role = d.str("role")
        let other = d.dict("other") ?? [:]
        otherName = other.str("name")
        otherMachine = other.optStr("machine")
        request = d.str("request")
        requestTruncated = d.bool("request_truncated")
        result = d["result"] as? String
        resultTruncated = d.bool("result_truncated")
        createdAt = d.date("created_at")
        deadlineAt = d.date("deadline_at")
        closedAt = d.date("closed_at")
    }

    var isOpen: Bool { state == "open" }

    /// "From lead" or "To windev @ PC".
    var counterpart: String {
        let machine = otherMachine.map { " @ \($0)" } ?? ""
        return role == "assigned" ? "From \(otherName)\(machine)" : "To \(otherName)\(machine)"
    }

    /// Cut in the list: `get_task` has the whole text.
    var cut: Bool { requestTruncated || resultTruncated }
}

enum ChatDecoding {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    static func turns(_ rows: [JSONDict]) -> [ChatTurn] {
        rows.compactMap { row in
            guard let data = try? JSONSerialization.data(withJSONObject: row) else { return nil }
            return try? decoder.decode(ChatTurn.self, from: data)
        }
    }
}

// MARK: Into the phone's turn model

extension ChatTrigger {
    /// The trigger as Gravity Lens described it, which the phone's labels read.
    var lensRow: JSONDict {
        let text = self.text ?? ""
        switch kind {
        case "owner":
            if via == "terminal" { return ["kind": "typed", "from": "You", "msg_kind": "", "text": text] }
            return ["kind": "owner", "from": "You", "msg_kind": "chat", "text": text]
        case "bus":
            return ["kind": "message", "from": from ?? "", "msg_kind": msgKind ?? "", "text": text]
        case "routine":
            return ["kind": "routine", "from": name ?? "", "msg_kind": "", "text": text]
        case "ruling":
            return ["kind": "message", "from": "You", "msg_kind": "decision", "text": text]
        case "resumed":
            return ["kind": "continued", "from": "", "msg_kind": "", "text": ""]
        default:
            return ["kind": "background", "from": "", "msg_kind": "", "text": text]
        }
    }

    /// "Task from lead", "You", "Routine nightly": what started the turn, in words.
    var headline: String {
        LensTrigger(kind: lensRow.str("kind"), from: lensRow.str("from"),
                    msgKind: lensRow.str("msg_kind"), text: lensRow.str("text")).headline
    }
}

/// The phone's views were built on Gravity Lens's turns and events; a daemon
/// turn is reshaped into those, so every view reads both.
extension ChatTurn {
    var lastActivity: String { open ? WireDate.string(Date()) : (endedAt ?? startedAt) }

    func lensTurn(botName: String?) -> LensTurn? {
        let steps = items.filter { $0.type == "step" }
        let current = open ? (steps.last { $0.minor != true }?.title ?? steps.last?.title ?? "") : ""
        let cover = steps.lazy.compactMap { $0.images?.first }.first
        var row: JSONDict = [
            "id": id, "started_at": startedAt, "updated_at": lastActivity, "open": open,
            "trigger": triggerRow, "outcome": outcomeRow, "current": current, "bot_id": botId,
            "stats": [
                "images": stats.images, "commands": stats.commands, "reads": stats.reads,
                "edits": stats.edits, "added": stats.added, "removed": stats.removed, "sent": stats.sent,
                "incoming": items.filter { $0.type == "aside" && $0.kind == "incoming" }.count,
                "errors": stats.errors, "steps": steps.count, "files": [String](),
            ] as JSONDict,
        ]
        if let endedAt { row["ended_at"] = endedAt }
        if let durationMs { row["duration_ms"] = durationMs }
        if let botName { row["bot_name"] = botName }
        if let cover { row["cover"] = Self.imageRow(cover) }
        return Self.decode(LensTurn.self, row)
    }

    var lensEvents: [LensEvent] {
        items.compactMap { item in Self.decode(LensEvent.self, eventRow(item)) }
    }

    private var triggerRow: JSONDict { trigger.lensRow }

    /// How the turn ended: its last words, a message it sent, or a finished task.
    private var outcomeRow: JSONDict {
        for item in items.reversed() {
            switch item.type {
            case "text": return ["kind": "text", "text": item.markdown ?? "", "to": ""]
            case "sent": return ["kind": "message", "text": item.body ?? "", "to": item.to ?? ""]
            case "completed": return ["kind": "completed", "text": item.result ?? "", "to": ""]
            default: continue
            }
        }
        return ["kind": "none", "text": "", "to": ""]
    }

    private func eventRow(_ item: ChatItem) -> JSONDict {
        var row: JSONDict = ["id": item.id, "at": startedAt, "title": item.title ?? ""]
        switch item.type {
        case "text":
            row["kind"] = "text"
            row["text"] = item.markdown ?? ""
        case "step":
            row["kind"] = "tool"
            row["tool"] = item.tool ?? ""
            if let subtitle = item.subtitle {
                row["subtitle"] = subtitle
                row["path"] = subtitle
            }
            row["error"] = item.status == "error"
            row["running"] = item.status == "running"
            row["minor"] = item.minor ?? false
            row["has_detail"] = true
            if let added = item.added { row["added"] = added }
            if let removed = item.removed { row["removed"] = removed }
            if let images = item.images, !images.isEmpty { row["images"] = images.map(Self.imageRow) }
        case "sent":
            row["kind"] = "sent"
            row["to"] = item.to ?? ""
            row["msg_kind"] = item.msgKind ?? ""
            row["text"] = item.body ?? ""
        case "completed":
            row["kind"] = "completed"
            row["text"] = item.result ?? ""
            if let taskId = item.taskId { row["task_id"] = taskId }
            row["artifacts"] = (item.artifacts ?? []).map(\.path)
        case "decision":
            row["kind"] = "decision"
            if let decisionId = item.decisionId { row["decision_id"] = decisionId }
        default:
            row["kind"] = item.kind == "compacted" ? "compacted" : (item.kind ?? "aside")
            row["text"] = item.text ?? ""
        }
        return row
    }

    private static func imageRow(_ ref: ChatImageRef) -> JSONDict {
        ["id": ref.id, "kind": "chat", "name": ref.mime.replacingOccurrences(of: "image/", with: "image."),
         "path": "", "exists": true]
    }

    private static let lensDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private static func decode<T: Decodable>(_ type: T.Type, _ row: JSONDict) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: row) else { return nil }
        return try? lensDecoder.decode(type, from: data)
    }
}
