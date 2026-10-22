import Foundation
import Observation

// Commands (0.24.0, `commands_v1`): one list of every bot's commands, across
// projects and linked computers, in place of the main chat. `list_commands`
// answers the rows and a summary per computer; `commands_changed` says to read
// it again; the owner may Stop a running background command.

/// One command a bot ran, as `list_commands` lists it.
struct FleetCommand: Identifiable, Equatable {
    /// The command's own id (its tool call's id on the bot's computer).
    let commandId: String
    /// This computer's ids: a linked bot's stand-in here, so Stop can name it.
    let botId: String
    let botName: String
    let projectId: String
    /// The computer the bot runs on.
    let daemonId: String
    let command: String
    let description: String?
    let background: Bool
    /// running, done, failed or stopped.
    let status: String
    let startedAt: Date?
    let endedAt: Date?
    let exitCode: Int?
    /// The card of the task whose turn ran it.
    let itemId: String?
    let taskId: String?
    /// The last 4 KB of its output.
    let output: String?
    let stoppedByOwner: Bool
    /// The phone's computer that answered for it, where Stop goes.
    var computerId: String

    /// One command once, however many computers list it.
    var id: String { "\(daemonId)/\(commandId)" }

    init(_ d: JSONDict, computerId: String) {
        commandId = d.str("id")
        botId = d.str("bot_id")
        botName = d.str("bot_name")
        projectId = d.str("project_id")
        daemonId = d.str("daemon_id")
        command = d.str("command")
        description = d.optStr("description")
        background = d.bool("background")
        status = d.str("status")
        startedAt = d.date("started_at")
        endedAt = d.date("ended_at")
        exitCode = d.optInt("exit_code")
        itemId = d.optStr("item_id")
        taskId = d.optStr("task_id")
        output = (d["output"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        stoppedByOwner = d.bool("stopped_by_owner")
        self.computerId = computerId
    }

    var isRunning: Bool { status == "running" }

    /// Only a running background command can be stopped: a foreground one
    /// ends with the bot's turn.
    var canStop: Bool { isRunning && background }

    /// What it is for, else the command's first line.
    var title: String {
        if let description, !description.trimmed.isEmpty { return description }
        return firstLine
    }

    var firstLine: String {
        command.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? command
    }
}

/// How many commands one computer runs, and how many failed today.
struct CommandSummary: Equatable {
    let daemonId: String
    let computerName: String
    let running: Int
    let failedToday: Int
    /// The computer didn't answer for one of its bots: the counts may be short.
    let stale: Bool

    init(_ d: JSONDict) {
        daemonId = d.str("daemon_id")
        computerName = d.str("computer_name")
        running = d.int("running")
        failedToday = d.int("failed_today")
        stale = d.bool("stale")
    }

    init(daemonId: String, computerName: String, running: Int, failedToday: Int, stale: Bool = false) {
        self.daemonId = daemonId
        self.computerName = computerName
        self.running = running
        self.failedToday = failedToday
        self.stale = stale
    }
}

/// One `list_commands` answer.
struct CommandsPage {
    var commands: [FleetCommand]
    var summary: [CommandSummary]
    /// Pass as `before` for the next page.
    var nextBefore: String?

    init(_ reply: JSONDict, computerId: String) {
        commands = reply.list("commands").map { FleetCommand($0, computerId: computerId) }
        summary = reply.list("summary").map(CommandSummary.init)
        nextBefore = reply.optStr("next_before")
    }

    init(commands: [FleetCommand], summary: [CommandSummary], nextBefore: String? = nil) {
        self.commands = commands
        self.summary = summary
        self.nextBefore = nextBefore
    }
}

/// The status chips: Running · Failed · All.
enum CommandStatusFilter: String, CaseIterable, Identifiable {
    case running, failed, all

    var id: Self { self }

    var title: String {
        switch self {
        case .running: "Running"
        case .failed: "Failed"
        case .all: "All"
        }
    }
}

/// What one `list_commands` asks for.
struct CommandsQuery: Equatable {
    var projectId: String?
    var botId: String?
    var status: CommandStatusFilter = .running
    var query = ""
    var limit = 200
    var before: String?

    var fields: JSONDict {
        var fields: JSONDict = ["status": status.rawValue, "limit": limit]
        if let projectId { fields["project_id"] = projectId }
        if let botId { fields["bot_id"] = botId }
        if !query.trimmed.isEmpty { fields["query"] = query.trimmed }
        if let before { fields["before"] = before }
        return fields
    }
}

/// What the Commands tab asks a computer.
@MainActor
protocol CommandsService: AnyObject {
    func listCommands(_ query: CommandsQuery, computerId: String) async throws -> CommandsPage
    /// The row as the list now shows it.
    func stopCommand(botId: String, commandId: String, computerId: String) async throws -> FleetCommand
}

extension AppStore: CommandsService {
    /// One list of every bot's commands (0.24.0).
    var hasCommandsList: Bool { capabilities.contains("commands_v1") }

    func listCommands(_ query: CommandsQuery, computerId: String) async throws -> CommandsPage {
        CommandsPage(try await client.request("list_commands", query.fields), computerId: computerId)
    }

    func stopCommand(botId: String, commandId: String, computerId: String) async throws -> FleetCommand {
        let reply = try await client.request("stop_command", ["bot_id": botId, "command_id": commandId])
        guard let row = reply.dict("command") else {
            throw DaemonError(code: "decode", message: "The Flotilla service didn’t say how the command ended.")
        }
        return FleetCommand(row, computerId: computerId)
    }
}

/// The rows of several computers as one list.
enum CommandsMerge {
    /// One row per command: a linked bot's command is listed by each computer
    /// it is linked to, so the bot's own computer's row wins, else the first.
    /// Running first, then newest started.
    static func rows(_ pages: [(computerId: String, daemonId: String?, page: CommandsPage)]) -> [FleetCommand] {
        var byId: [String: (row: FleetCommand, own: Bool)] = [:]
        var order: [String] = []
        for (_, daemonId, page) in pages {
            for row in page.commands {
                let own = daemonId != nil && row.daemonId == daemonId
                if let known = byId[row.id] {
                    if own && !known.own { byId[row.id] = (row, true) }
                } else {
                    byId[row.id] = (row, own)
                    order.append(row.id)
                }
            }
        }
        return sorted(order.compactMap { byId[$0]?.row })
    }

    static func sorted(_ rows: [FleetCommand]) -> [FleetCommand] {
        rows.enumerated().sorted { a, b in
            if a.element.isRunning != b.element.isRunning { return a.element.isRunning }
            let at = a.element.startedAt ?? .distantPast
            let bt = b.element.startedAt ?? .distantPast
            if at != bt { return at > bt }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// One count per computer: the computer's own answer, else the first.
    static func summary(_ pages: [(computerId: String, daemonId: String?, page: CommandsPage)]) -> [CommandSummary] {
        var byDaemon: [String: (summary: CommandSummary, own: Bool)] = [:]
        var order: [String] = []
        for (_, daemonId, page) in pages {
            for summary in page.summary {
                let key = summary.daemonId.isEmpty ? summary.computerName : summary.daemonId
                let own = daemonId != nil && summary.daemonId == daemonId
                if let known = byDaemon[key] {
                    if own && !known.own { byDaemon[key] = (summary, true) }
                } else {
                    byDaemon[key] = (summary, own)
                    order.append(key)
                }
            }
        }
        return order.compactMap { byDaemon[$0]?.summary }
    }
}

/// Commands in the glossary's words.
enum CommandWords {
    static func status(_ row: FleetCommand) -> String {
        switch row.status {
        case "running": return "Running"
        case "done": return "Done"
        case "failed": return row.exitCode.map { "Failed · \($0)" } ?? "Failed"
        case "stopped": return row.stoppedByOwner ? "Stopped by you" : "Stopped"
        default: return row.status.capitalizedFirst
        }
    }

    /// ◑ running, ✓ done, ✗ failed, ■ stopped, as on the design.
    static func symbol(_ row: FleetCommand) -> String {
        switch row.status {
        case "running": "circle.lefthalf.filled"
        case "done": "checkmark"
        case "failed": "xmark"
        default: "stop.fill"
        }
    }

    static func tone(_ row: FleetCommand) -> Tone {
        switch row.status {
        case "running": .working
        case "done": .ready
        case "failed": .failed
        default: .quiet
        }
    }

    /// How long it ran, or has run: "41 s", "18 min", "2 h 5 min".
    static func took(_ row: FleetCommand, now: Date = Date()) -> String? {
        guard let start = row.startedAt else { return nil }
        let end = row.endedAt ?? (row.isRunning ? now : nil)
        guard let end else { return nil }
        return duration(max(0, end.timeIntervalSince(start)))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        let minutes = s / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// "ML Engineer · PhD", with the computer when the bot runs elsewhere.
    static func place(_ row: FleetCommand, project: String?, computer: String?) -> String {
        [row.botName.isEmpty ? "A bot" : row.botName, project, computer].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// The detail screen's first line: "Running · background · 18 min".
    static func headline(_ row: FleetCommand, now: Date = Date()) -> String {
        var parts = [status(row)]
        if row.background { parts.append("background") }
        if let took = took(row, now: now) { parts.append(took) }
        return parts.joined(separator: " · ")
    }

    /// The row's second line under the command: its description, "background".
    static func subtitle(_ row: FleetCommand) -> String {
        var parts: [String] = []
        if let description = row.description, !description.trimmed.isEmpty { parts.append(description) }
        if row.background { parts.append("background") }
        if row.status == "failed", let code = row.exitCode { parts.append("exit \(code)") }
        if row.stoppedByOwner { parts.append("stopped by you") }
        return parts.joined(separator: " · ")
    }

    /// The summary's tiles, summed over the computers.
    static func totals(_ summary: [CommandSummary]) -> (running: Int, failedToday: Int) {
        summary.reduce((0, 0)) { ($0.0 + $1.running, $0.1 + $1.failedToday) }
    }

    /// "mac 6 · win-pc 1": running per computer, when there are several.
    static func perComputer(_ summary: [CommandSummary]) -> String? {
        guard summary.count > 1 else { return nil }
        return summary.map { "\($0.computerName) \($0.running)\($0.stale ? "?" : "")" }.joined(separator: " · ")
    }

    /// What Stop asks before it kills the process.
    static func stopQuestion(_ row: FleetCommand) -> String {
        "Stop \(PermissionWords.middleTruncated(row.firstLine, limit: 60))?"
    }

    static let stopMessage = "Its process is ended and the bot is told not to run it again without asking you."
}

/// A computer the Commands tab reads, and the project and bot ids it knows.
struct CommandsSource {
    let computerId: String
    let name: String
    let daemonId: String?
    /// Serves `list_commands`; an older daemon doesn't.
    let supported: Bool
    let service: CommandsService
}

/// A project to filter by, with each computer's own id for it.
struct CommandsProjectChoice: Identifiable, Hashable {
    let name: String
    /// computer id → the project's id there.
    let ids: [String: String]
    var id: String { name + "|" + ids.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",") }
}

/// A bot to filter by, on the computer that knows it.
struct CommandsBotChoice: Identifiable, Hashable {
    let computerId: String
    let botId: String
    let name: String
    var id: String { "\(computerId)/\(botId)" }
}

/// The Commands tab: its filters, its rows across the computers, the summary,
/// a page at a time, read again on `commands_changed`.
@MainActor @Observable
final class CommandsModel {
    var status: CommandStatusFilter = .running
    var project: CommandsProjectChoice?
    var bot: CommandsBotChoice?
    var query = ""

    private(set) var rows: [FleetCommand] = []
    private(set) var summary: [CommandSummary] = []
    private(set) var loading = false
    private(set) var loaded = false
    /// computer name → why it didn't answer.
    private(set) var failures: [String: String] = [:]
    /// Computers whose Flotilla is older than Commands.
    private(set) var unsupported: [String] = []
    /// Stops on their way, by row id.
    private(set) var stopping: Set<String> = []
    private(set) var stopFailure: String?

    @ObservationIgnored private var sources: [CommandsSource] = []
    /// Each computer's next page, by computer id.
    @ObservationIgnored private var cursors: [String: String] = [:]
    @ObservationIgnored private var pages: [String: CommandsPage] = [:]
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    /// The shortest wait between two reads after a push.
    @ObservationIgnored var debounce: Duration = .seconds(1)

    var hasMore: Bool { !cursors.isEmpty }

    var totals: (running: Int, failedToday: Int) { CommandWords.totals(summary) }

    func row(_ id: String) -> FleetCommand? { rows.first { $0.id == id } }

    func clearStopFailure() { stopFailure = nil }

    /// What one computer is asked, by the filters.
    func query(for source: CommandsSource, before: String? = nil) -> CommandsQuery? {
        var query = CommandsQuery(status: status, query: self.query, before: before)
        if let bot {
            guard bot.computerId == source.computerId else { return nil }
            query.botId = bot.botId
        }
        if let project {
            guard let id = project.ids[source.computerId] else { return nil }
            query.projectId = id
        }
        return query
    }

    /// Reads the first page from every computer again.
    func load(_ sources: [CommandsSource]) async {
        self.sources = sources
        generation += 1
        let run = generation
        loading = true
        defer { if run == generation { loading = false } }
        unsupported = sources.filter { !$0.supported }.map(\.name)
        var answers: [String: CommandsPage] = [:]
        var failed: [String: String] = [:]
        await withTaskGroup(of: (String, String, Result<CommandsPage, Error>?).self) { group in
            for source in sources where source.supported {
                guard let query = query(for: source) else { continue }
                group.addTask { @MainActor in
                    do {
                        return (source.computerId, source.name, .success(try await source.service.listCommands(query, computerId: source.computerId)))
                    } catch {
                        return (source.computerId, source.name, .failure(error))
                    }
                }
            }
            for await (id, name, result) in group {
                switch result {
                case .success(let page)?: answers[id] = page
                case .failure(let error)?: failed[name] = error.localizedDescription
                case nil: break
                }
            }
        }
        guard run == generation else { return }
        pages = answers
        cursors = answers.compactMapValues(\.nextBefore)
        failures = failed
        rebuild()
        loaded = true
    }

    /// The next page from each computer that has one.
    func loadMore() async {
        guard !cursors.isEmpty, !loading else { return }
        loading = true
        defer { loading = false }
        let run = generation
        for source in sources {
            guard let before = cursors[source.computerId], let query = query(for: source, before: before) else { continue }
            do {
                let page = try await source.service.listCommands(query, computerId: source.computerId)
                guard run == generation else { return }
                var known = pages[source.computerId] ?? CommandsPage(commands: [], summary: [])
                known.commands += page.commands
                known.summary = page.summary.isEmpty ? known.summary : page.summary
                known.nextBefore = page.nextBefore
                pages[source.computerId] = known
                cursors[source.computerId] = page.nextBefore
            } catch {
                failures[source.name] = error.localizedDescription
                cursors[source.computerId] = nil
            }
        }
        rebuild()
    }

    /// A `commands_changed` push: read again soon, once for a burst.
    func changed() {
        guard pending == nil, !sources.isEmpty else { return }
        pending = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.debounce)
            self.pending = nil
            await self.load(self.sources)
        }
    }

    /// Stop (owner only): the row as the list now shows it.
    func stop(_ row: FleetCommand) async -> Bool {
        guard row.canStop, !stopping.contains(row.id),
              let source = sources.first(where: { $0.computerId == row.computerId }) else { return false }
        stopping.insert(row.id)
        stopFailure = nil
        defer { stopping.remove(row.id) }
        do {
            let stopped = try await source.service.stopCommand(botId: row.botId, commandId: row.commandId, computerId: row.computerId)
            replace(stopped)
            return true
        } catch {
            stopFailure = error.localizedDescription
            return false
        }
    }

    private func replace(_ row: FleetCommand) {
        guard var page = pages[row.computerId], let index = page.commands.firstIndex(where: { $0.id == row.id }) else {
            if let index = rows.firstIndex(where: { $0.id == row.id }) { rows[index] = row }
            return
        }
        page.commands[index] = row
        pages[row.computerId] = page
        rebuild()
    }

    private func rebuild() {
        let ordered = sources.compactMap { source in pages[source.computerId].map { (source.computerId, source.daemonId, $0) } }
        // A row Stop just ended stays on Running until the next read.
        rows = CommandsMerge.rows(ordered)
        summary = CommandsMerge.summary(ordered)
    }
}
