import Foundation

// What the daemon tells about a bot beyond its chat: its own browser, the
// commands it runs, and what bots say to each other. Gravity's
// docs/protocol.md and docs/bot-browser.md are the contract.

// MARK: Browser

struct BrowserTab: Identifiable, Equatable {
    let id: String
    let title: String
    let url: String

    /// A tab without a title yet goes by its address.
    var label: String { title.isEmpty ? url : title }
}

/// `browser_tabs`: the bot's tabs, and which one is on show.
struct BrowserTabs: Equatable {
    let botId: String
    /// False while the bot has no browser running.
    let open: Bool
    let tabs: [BrowserTab]
    let active: String?
    /// The view follows whichever tab the bot used last.
    let following: Bool
    /// Why the browser cannot be shown, e.g. its machine is offline.
    let reason: String?

    init(_ d: JSONDict) {
        botId = d.str("bot_id")
        open = d.bool("open")
        tabs = d.list("tabs").map { BrowserTab(id: $0.str("id"), title: $0.str("title"), url: $0.str("url")) }
        active = d.optStr("active")
        following = d["following"] as? Bool ?? true
        reason = d.optStr("reason")
    }

    var activeTab: BrowserTab? { tabs.first { $0.id == active } }
}

/// `browser_frame`: the newest screen of the tab on show, a JPEG.
struct BrowserFrame: Equatable {
    let botId: String
    let tabId: String
    let jpeg: Data
    let width: Int
    let height: Int

    init?(_ d: JSONDict) {
        guard let jpeg = (d["data"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return nil }
        botId = d.str("bot_id")
        tabId = d.str("tab_id")
        self.jpeg = jpeg
        width = d.int("width")
        height = d.int("height")
    }

    /// Only the tab on show is drawn: a frame from the tab just left is stale.
    func belongs(to tabs: BrowserTabs?) -> Bool {
        guard let tabs, tabs.open, tabs.botId == botId else { return false }
        return tabs.active == tabId
    }
}

/// One thing the bot did in a browser (`list_browser_activity`).
struct BrowserAction: Identifiable, Equatable {
    let turnId: String
    let stepId: String
    let at: Date?
    /// In the owner's own Chrome rather than the bot's browser.
    let ownersChrome: Bool
    let title: String
    let subtitle: String?
    let status: String
    let trigger: ChatTrigger?

    var id: String { stepId }

    init(_ d: JSONDict) {
        turnId = d.str("turn_id")
        stepId = d.str("step_id")
        at = d.date("at")
        ownersChrome = d.str("browser") == "owners_chrome"
        title = d.str("title")
        subtitle = d.optStr("subtitle")
        status = d.str("status")
        trigger = d.dict("trigger").flatMap { row in
            (try? JSONSerialization.data(withJSONObject: row))
                .flatMap { try? ChatDecoding.decoder.decode(ChatTrigger.self, from: $0) }
        }
    }
}

/// Consecutive actions of one turn, under what started it.
struct BrowserTurnGroup: Identifiable, Equatable {
    let turnId: String
    let at: Date?
    /// "Task from lead", "You", …
    let why: String
    /// What was asked.
    let ask: String
    let actions: [BrowserAction]

    var id: String { "\(turnId)#\(actions.first?.stepId ?? "")" }

    /// Groups newest-first actions by turn, keeping that order.
    static func group(_ actions: [BrowserAction]) -> [BrowserTurnGroup] {
        var groups: [BrowserTurnGroup] = []
        for action in actions {
            if let last = groups.last, last.turnId == action.turnId {
                groups[groups.count - 1] = BrowserTurnGroup(
                    turnId: last.turnId, at: last.at, why: last.why, ask: last.ask, actions: last.actions + [action])
                continue
            }
            groups.append(BrowserTurnGroup(
                turnId: action.turnId, at: action.at,
                why: action.trigger?.headline ?? "Turn", ask: action.trigger?.text ?? "", actions: [action]))
        }
        return groups
    }
}

// MARK: Commands

/// A command the bot ran or is running (`list_bot_commands`).
struct BotCommand: Identifiable, Equatable {
    let id: String
    let command: String
    let description: String?
    let background: Bool
    /// running, done, failed or stopped.
    let status: String
    let startedAt: Date?
    let endedAt: Date?
    let exitCode: Int?
    let taskId: String?
    /// For a running background command, the live end of its output.
    let output: String?

    init(_ d: JSONDict) {
        id = d.str("id")
        command = d.str("command")
        description = d.optStr("description")
        background = d.bool("background")
        status = d.str("status")
        startedAt = d.date("started_at")
        endedAt = d.date("ended_at")
        exitCode = d.optInt("exit_code")
        taskId = d.optStr("task_id")
        output = d["output"] as? String
    }

    var isRunning: Bool { status == "running" }

    /// What it is for, or its first line.
    var title: String { description ?? command.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? "" }

    /// The command without the shell it was handed to: Codex on Windows runs
    /// everything as `"…\\pwsh.exe" -Command "…"`, which says nothing on a phone.
    var unwrapped: String { Self.unwrap(command) }

    static func unwrap(_ command: String) -> String {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrappers = [
            #"^"?[^"]*?(?:pwsh|powershell)(?:\.exe)?"?\s+(?:-NoProfile\s+|-NoLogo\s+)*-Command\s+"#,
            #"^(?:/usr/bin/|/bin/)?(?:bash|zsh|sh)\s+-l?c\s+"#,
            #"^cmd(?:\.exe)?\s+/c\s+"#,
        ]
        for pattern in wrappers {
            guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { continue }
            var inner = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if let first = inner.first, first == "\"" || first == "'", inner.count > 1, inner.last == first {
                inner = String(inner.dropFirst().dropLast())
            }
            return inner.isEmpty ? text : inner
        }
        return text
    }

    /// A finished command's outcome: its status, or the exit code when that says more.
    var outcome: String? {
        guard !isRunning else { return nil }
        if let exitCode, exitCode != 0 { return "exit \(exitCode)" }
        return status
    }

    /// The start time and, once ended, how long it took.
    func when(_ format: (Date) -> String) -> String {
        guard let startedAt else { return "" }
        guard let endedAt else { return format(startedAt) }
        return "\(format(startedAt)) · \(Self.elapsed(from: startedAt, to: endedAt))"
    }

    /// "12s", "4m 03s", "1h 05m".
    static func elapsed(from: Date, to: Date) -> String {
        let seconds = max(0, Int((to.timeIntervalSince(from)).rounded()))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m \(String(format: "%02d", seconds % 60))s" }
        return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
    }

    /// Running first, then what finished, each in the daemon's order.
    static func sections(_ commands: [BotCommand]) -> (running: [BotCommand], finished: [BotCommand]) {
        (commands.filter(\.isRunning), commands.filter { !$0.isRunning })
    }

    /// The output worth a Copy control: none when there is nothing to copy.
    var copyableOutput: String? {
        guard let output, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return output
    }

    /// A background command still writing output is worth polling.
    static func needsPolling(_ commands: [BotCommand]) -> Bool {
        commands.contains { $0.isRunning && $0.background }
    }
}

// MARK: Conversations between bots

struct AgentBot: Identifiable, Equatable {
    let id: String
    let name: String
    let avatar: String
    /// The peer it runs on, for a linked bot.
    let machine: String?
    let deleted: Bool

    init(id: String, name: String, avatar: String, machine: String?, deleted: Bool) {
        self.id = id
        self.name = name
        self.avatar = avatar
        self.machine = machine
        self.deleted = deleted
    }

    init(_ d: JSONDict) {
        self.init(id: d.str("id"), name: d.str("name"), avatar: d.str("avatar"),
                  machine: d.optStr("machine"), deleted: d.bool("deleted"))
    }

    /// "windev @ win-pc" for a linked bot.
    var label: String { machine.map { "\(name) @ \($0)" } ?? name }
}

/// A message between two bots (`list_agent_conversation`).
struct AgentMessage: Identifiable, Equatable {
    let id: String
    let num: Int
    let fromBotId: String
    let toBotId: String
    /// task, reply, done, note or chat.
    let kind: String
    let body: String
    let refMessageId: String?
    let taskState: String?
    let createdAt: Date?

    init(_ d: JSONDict) {
        id = d.str("id")
        num = d.int("num")
        fromBotId = d.str("from_bot_id")
        toBotId = d.str("to_bot_id")
        kind = d.str("kind")
        body = d.str("body")
        refMessageId = d.optStr("ref_message_id")
        taskState = d.dict("task")?.optStr("state")
        createdAt = d.date("created_at")
    }

    var kindLabel: String { MessageKind.label(kind) }
}

/// A pair of bots that talked, with the newest word (`list_agent_conversations`).
struct AgentConversation: Identifiable, Equatable {
    let botIds: [String]
    let messageCount: Int
    let lastAt: Date?
    let last: AgentMessage?

    init(_ d: JSONDict) {
        botIds = d.strings("bot_ids")
        messageCount = d.int("message_count")
        lastAt = d.date("last_at")
        last = d.dict("last").map(AgentMessage.init)
    }

    var id: String { AgentConversations.key(botIds) }
}

/// Naming pairs, merging pages, and which side each bot sits on.
enum AgentConversations {
    /// A stable key for a pair, whatever order its ids come in.
    static func key(_ ids: [String]) -> String { ids.sorted().joined(separator: "|") }

    /// A fetched page merged into what is loaded: one copy of each, oldest first.
    static func merge(_ loaded: [AgentMessage], _ page: [AgentMessage]) -> [AgentMessage] {
        var byId: [String: AgentMessage] = [:]
        for message in loaded + page { byId[message.id] = message }
        return byId.values.sorted { $0.num < $1.num }
    }

    /// The pair as (left, right): the bot higher in the project's list sits
    /// on the left, so a lead keeps its side however far back the thread is
    /// read. Bots no longer listed (archived) go after those that are.
    static func sides(_ ids: [String], order: [String]) -> (left: String, right: String) {
        let a = ids.first ?? "", b = ids.count > 1 ? ids[1] : ""
        func rank(_ id: String) -> Int { order.firstIndex(of: id) ?? .max }
        return rank(b) < rank(a) ? (b, a) : (a, b)
    }

    static func bot(_ id: String, in bots: [String: AgentBot]) -> AgentBot {
        bots[id] ?? AgentBot(id: id, name: "unknown bot", avatar: "", machine: nil, deleted: true)
    }

    /// "lead ↔ windev @ win-pc".
    static func title(_ pair: (left: String, right: String), bots: [String: AgentBot]) -> String {
        "\(bot(pair.left, in: bots).label) ↔ \(bot(pair.right, in: bots).label)"
    }

    /// The list's preview: who said the last thing, and what.
    static func preview(_ conversation: AgentConversation, bots: [String: AgentBot]) -> String {
        guard let last = conversation.last else { return "" }
        let body = last.body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return "\(bot(last.fromBotId, in: bots).name): \(body)"
    }
}

// MARK: Workers

/// A temporary worker a bot spawned (`list_workers`): queued for a slot,
/// running, or finished.
struct Worker: Identifiable, Equatable {
    let id: String
    let projectId: String
    let name: String
    /// queued, running, done, cancelled, expired or failed.
    let state: String
    let queuePosition: Int?
    /// "here", or the linked computer it runs on.
    let machine: String?
    let parentBotId: String
    let parentName: String?
    /// The opening of its task.
    let brief: String
    let taskId: String?
    /// Why it waits, failed or was cancelled.
    let note: String?
    /// Its bot, once placed.
    let botId: String?
    let createdAt: Date?
    let startedAt: Date?
    let finishedAt: Date?

    init(_ d: JSONDict) {
        id = d.str("id")
        projectId = d.str("project_id")
        name = d.str("name")
        state = d.str("state")
        queuePosition = d.optInt("queue_position")
        machine = d.optStr("machine")
        parentBotId = d.str("parent_bot_id")
        parentName = d.optStr("parent_name")
        brief = d.str("brief")
        taskId = d.optStr("task_id")
        note = d.optStr("note")
        botId = d.optStr("bot_id")
        createdAt = d.date("created_at")
        startedAt = d.date("started_at")
        finishedAt = d.date("finished_at")
    }

    var isActive: Bool { state == "queued" || state == "running" }

    /// "#2 in queue", "running", "running on win-pc", "done", …
    var chip: String {
        switch state {
        case "queued": return queuePosition.map { "#\($0) in queue" } ?? "Queued"
        case "running":
            guard let machine, machine != "here" else { return "Running" }
            return "Running on \(machine)"
        default: return state.prefix(1).uppercased() + state.dropFirst()
        }
    }

    /// When it last moved: finished, started, or was spawned.
    var when: Date? { finishedAt ?? startedAt ?? createdAt }

    /// Running, then the queue, then what finished, each in the daemon's order.
    static func sections(_ workers: [Worker]) -> (running: [Worker], queued: [Worker], finished: [Worker]) {
        (workers.filter { $0.state == "running" },
         workers.filter { $0.state == "queued" },
         workers.filter { !$0.isActive })
    }
}

/// A project's workers and how many of its slots are busy on this computer.
struct WorkerListing: Equatable {
    let workers: [Worker]
    let runningHere: Int
    let maxHere: Int

    init(_ d: JSONDict) {
        workers = d.list("workers").map(Worker.init)
        runningHere = d.int("running_here")
        maxHere = d.int("max_workers_here")
    }
}

// MARK: Permission prompts

/// A bot's tool waiting on the owner's answer (`list_permissions`,
/// `permission_request`). Unanswered by `expiresAt`, it is denied.
/// The separate fields of a terminal command's card; any of them but the
/// command may be missing.
struct TerminalOrigin: Equatable {
    let command: String
    let pid: Int?
    let process: String?
    let launchedFrom: String?
    let cwd: String?
    /// The bot whose workspace holds `cwd`: a bot is probably asking.
    let bot: String?

    init(_ d: JSONDict) {
        command = d.str("command")
        pid = d.optInt("pid")
        process = d.optStr("process")
        launchedFrom = d.optStr("launched_from")
        cwd = d.optStr("cwd")
        bot = d.optStr("bot")
    }

    /// "From claude in iTerm2 · in ~/x · process 4121", leaving out what is missing.
    var line: String? {
        var parts: [String] = []
        switch (process, launchedFrom) {
        case let (p?, l?): parts.append("From \(p) in \(l)")
        case let (p?, nil): parts.append("From \(p)")
        case let (nil, l?): parts.append("From \(l)")
        default: break
        }
        if let cwd { parts.append("in \(cwd)") }
        if let pid { parts.append("process \(pid)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct PermissionRequest: Identifiable, Equatable {
    let id: String
    let botId: String
    let tool: String
    /// One line saying what the tool would do.
    let summary: String
    /// The tool's input, pretty-printed JSON, truncated.
    let input: String
    let createdAt: Date?
    let expiresAt: Date?
    /// Where a terminal command comes from (T4, UX-014); nil for a bot's tool
    /// or a daemon that sends only `summary`.
    let origin: TerminalOrigin?

    init(_ d: JSONDict) {
        id = d.str("id")
        botId = d.str("bot_id")
        tool = d.str("tool")
        summary = d.str("summary")
        input = d.str("input")
        createdAt = d.date("created_at")
        expiresAt = d.date("expires_at")
        origin = d.dict("origin").map(TerminalOrigin.init).flatMap { $0.command.isEmpty ? nil : $0 }
    }

    /// A terminal command asking to act as the owner (T4). The phone never
    /// answers one: it can't see that terminal (H-108, UX-014 must-fix 4).
    var isTerminal: Bool { botId == "terminal" }

    /// The tool as people read it, never the `mcp__` form: "Bash",
    /// "Send message" for the bus's `mcp__hermes-bus__send_message`, and
    /// "Playwright: browser click" for another server's tool.
    var toolName: String { Self.displayName(ofTool: tool) }

    /// Any tool id as people read it, for prompts answered here and in the
    /// bot's terminal alike.
    static func displayName(ofTool tool: String) -> String {
        let parts = tool.components(separatedBy: "__")
        guard tool.hasPrefix("mcp__"), parts.count >= 3 else { return sentence(tool) }
        let action = sentence(parts.dropFirst(2).joined(separator: " "))
        if BusTool.isBus(tool) { return action }
        let server = sentence(parts[1].replacingOccurrences(of: "-", with: " "))
        return "\(server): \(action.prefix(1).lowercased())\(action.dropFirst())"
    }

    /// "send_message" → "Send message".
    private static func sentence(_ name: String) -> String {
        let words = name.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// The owner's answer. A reason goes back to the bot with a deny only.
    enum Answer: String, CaseIterable {
        case allowOnce = "allow_once"
        case allowSession = "allow_session"
        case deny

        var label: String {
            switch self {
            case .allowOnce: "Allow once"
            case .allowSession: "Allow for session"
            case .deny: "Deny"
            }
        }

        /// Context VoiceOver adds after the label.
        var hint: String? {
            self == .allowSession ? "For the rest of this bot's session" : nil
        }
    }

    /// Waiting prompts, oldest first, one per id: a list merged with a new prompt.
    static func adding(_ request: PermissionRequest, to list: [PermissionRequest]) -> [PermissionRequest] {
        ordered(list.filter { $0.id != request.id } + [request])
    }

    /// Terminal commands first, above bot cards (H-108); then oldest first.
    static func ordered(_ list: [PermissionRequest]) -> [PermissionRequest] {
        list.sorted {
            if $0.isTerminal != $1.isTerminal { return $0.isTerminal }
            return ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
        }
    }
}

/// How a message's kind reads: never the raw wire value.
enum MessageKind {
    static func label(_ kind: String) -> String {
        switch kind {
        case "done": "Result"
        case "task": "Task"
        case "reply": "Reply"
        case "note": "Note"
        default: "Message"
        }
    }
}

/// How a task's state reads: Open · Done · Cancelled · Expired.
enum TaskStateLabel {
    static func label(_ state: String) -> String {
        switch state {
        case "open": "Open"
        case "done": "Done"
        case "cancelled": "Cancelled"
        case "expired": "Expired"
        default: state.prefix(1).uppercased() + state.dropFirst().replacingOccurrences(of: "_", with: " ")
        }
    }
}

/// A bot waiting for approval in its own terminal (`approval_pending`), said
/// from the tool it wants to run when the daemon names it.
struct Approval: Equatable {
    var tool: String?

    init(tool: String?) {
        self.tool = tool.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }

    /// Notification title: "Backend Dev wants to run Bash", else "Backend Dev needs approval".
    func title(_ bot: String) -> String {
        tool.map { "\(bot) wants to run \(PermissionRequest.displayName(ofTool: $0))" } ?? "\(bot) needs approval"
    }

    /// The line under a bot's name: "Wants to run Bash", else "Needs approval".
    var line: String {
        tool.map { "Wants to run \(PermissionRequest.displayName(ofTool: $0))" } ?? "Needs approval"
    }
}
