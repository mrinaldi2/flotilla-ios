import XCTest
@testable import Flotilla

/// A computer that lists commands, for the Commands tab's model: answers what
/// the test set, records what was asked.
@MainActor
final class FakeCommands: CommandsService {
    var pages: [String?: CommandsPage] = [:]
    var error: Error?
    var stopped: FleetCommand?
    var stopError: Error?
    private(set) var queries: [CommandsQuery] = []
    private(set) var stops: [(botId: String, commandId: String)] = []

    func listCommands(_ query: CommandsQuery, computerId: String) async throws -> CommandsPage {
        queries.append(query)
        if let error { throw error }
        return pages[query.before] ?? CommandsPage(commands: [], summary: [])
    }

    func stopCommand(botId: String, commandId: String, computerId: String) async throws -> FleetCommand {
        stops.append((botId, commandId))
        if let stopError { throw stopError }
        return stopped!
    }
}

/// 0.24 step 6 on the phone, Commands: `list_commands` rows and summary
/// decode, a linked bot's command is listed once, running first then newest,
/// the words match the design, the filters reach each computer as its own
/// ids, paging, `commands_changed` refetches once for a burst, and Stop.
@MainActor
final class FleetCommandsTests: XCTestCase {
    static func row(_ id: String, bot: String = "ml", status: String = "running", started: String = "2026-10-22T14:02:00Z",
                    ended: String? = nil, daemon: String = "d-mac", background: Bool = true, extra: JSONDict = [:]) -> JSONDict {
        var row: JSONDict = ["id": id, "bot_id": bot, "bot_name": "ML Engineer", "project_id": "p1", "daemon_id": daemon,
                             "command": "python -m dungeonflow.train --seed 7", "background": background, "status": status,
                             "started_at": started]
        if let ended { row["ended_at"] = ended }
        return row.merging(extra) { _, new in new }
    }

    private func command(_ id: String, computer: String = "mac", status: String = "running", started: String = "2026-10-22T14:02:00Z",
                         daemon: String = "d-mac", background: Bool = true) -> FleetCommand {
        FleetCommand(Self.row(id, status: status, started: started, daemon: daemon, background: background), computerId: computer)
    }

    // MARK: The contract

    func testARowAndTheSummaryDecode() {
        let reply: JSONDict = [
            "type": "commands",
            "commands": [Self.row("toolu_1", status: "failed", ended: "2026-10-22T14:04:00Z",
                                  extra: ["exit_code": 1, "item_id": "CASS-052", "description": "Train the RL baseline",
                                          "output": "episode 2430/4000", "task_id": "t-9"])],
            "summary": [["daemon_id": "d-mac", "computer_name": "mac", "running": 6, "failed_today": 3],
                        ["daemon_id": "d-pc", "computer_name": "win-pc", "running": 1, "failed_today": 0, "stale": true]],
            "next_before": "cursor-1",
        ]
        let page = CommandsPage(reply, computerId: "mac")
        let row = page.commands[0]
        XCTAssertEqual(row.commandId, "toolu_1")
        XCTAssertEqual(row.id, "d-mac/toolu_1", "one command once, by its computer and its own id")
        XCTAssertEqual(row.botName, "ML Engineer")
        XCTAssertEqual(row.exitCode, 1)
        XCTAssertEqual(row.itemId, "CASS-052")
        XCTAssertEqual(row.taskId, "t-9")
        XCTAssertEqual(row.output, "episode 2430/4000")
        XCTAssertEqual(row.title, "Train the RL baseline")
        XCTAssertEqual(row.computerId, "mac")
        XCTAssertFalse(row.canStop, "a finished command can't be stopped")
        XCTAssertEqual(page.summary.map(\.running), [6, 1])
        XCTAssertEqual(page.summary[1].stale, true)
        XCTAssertEqual(page.nextBefore, "cursor-1")
    }

    func testOnlyARunningBackgroundCommandCanBeStopped() {
        XCTAssertTrue(command("a").canStop)
        XCTAssertFalse(command("b", background: false).canStop, "a foreground command ends with the bot's turn")
        XCTAssertFalse(command("c", status: "done").canStop)
    }

    func testTheQueryCarriesTheFilters() {
        var query = CommandsQuery(projectId: "p1", botId: "b1", status: .failed, query: "  pytest ", before: "c2")
        XCTAssertEqual(query.fields["status"] as? String, "failed")
        XCTAssertEqual(query.fields["project_id"] as? String, "p1")
        XCTAssertEqual(query.fields["bot_id"] as? String, "b1")
        XCTAssertEqual(query.fields["query"] as? String, "pytest")
        XCTAssertEqual(query.fields["before"] as? String, "c2")
        XCTAssertEqual(query.fields["limit"] as? Int, 200)
        query = CommandsQuery()
        XCTAssertEqual(query.fields["status"] as? String, "running", "Running is the chip the design opens on")
        XCTAssertNil(query.fields["query"])
        XCTAssertNil(query.fields["project_id"])
    }

    // MARK: Merging computers

    func testALinkedBotsCommandIsListedOnceFromItsOwnComputer() {
        let fromMac = CommandsPage(commands: [command("x", computer: "mac", daemon: "d-pc")], summary: [])
        let fromPc = CommandsPage(commands: [command("x", computer: "pc", daemon: "d-pc")], summary: [])
        let rows = CommandsMerge.rows([("mac", "d-mac", fromMac), ("pc", "d-pc", fromPc)])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].computerId, "pc", "the bot's own computer answers for it")
    }

    func testRunningFirstThenNewest() {
        let page = CommandsPage(commands: [
            command("old", status: "done", started: "2026-10-22T10:00:00Z"),
            command("run-old", started: "2026-10-22T09:00:00Z"),
            command("new", status: "failed", started: "2026-10-22T12:00:00Z"),
            command("run-new", started: "2026-10-22T11:00:00Z"),
        ], summary: [])
        XCTAssertEqual(CommandsMerge.rows([("mac", "d-mac", page)]).map(\.commandId), ["run-new", "run-old", "new", "old"])
    }

    func testTheSummaryIsOnePerComputer() {
        let mac = CommandsPage(commands: [], summary: [CommandSummary(daemonId: "d-mac", computerName: "mac", running: 6, failedToday: 3),
                                                     CommandSummary(daemonId: "d-pc", computerName: "win-pc", running: 0, failedToday: 0, stale: true)])
        let pc = CommandsPage(commands: [], summary: [CommandSummary(daemonId: "d-pc", computerName: "win-pc", running: 1, failedToday: 0)])
        let summary = CommandsMerge.summary([("mac", "d-mac", mac), ("pc", "d-pc", pc)])
        XCTAssertEqual(summary.map(\.computerName), ["mac", "win-pc"])
        XCTAssertEqual(summary.map(\.running), [6, 1], "a computer's own count wins over a stale one")
        XCTAssertEqual(CommandWords.totals(summary).running, 7)
        XCTAssertEqual(CommandWords.totals(summary).failedToday, 3)
        XCTAssertEqual(CommandWords.perComputer(summary), "mac 6 · win-pc 1")
        XCTAssertNil(CommandWords.perComputer([summary[0]]), "one computer needs no split")
    }

    // MARK: Words

    func testTheWordsMatchTheDesign() {
        let now = WireDate.parse("2026-10-22T14:20:00Z")!
        let running = command("a")
        XCTAssertEqual(CommandWords.status(running), "Running")
        XCTAssertEqual(CommandWords.took(running, now: now), "18 min")
        XCTAssertEqual(CommandWords.headline(running, now: now), "Running · background · 18 min")
        let failed = FleetCommand(Self.row("b", status: "failed", started: "2026-10-22T13:41:00Z", ended: "2026-10-22T13:43:00Z",
                                           extra: ["exit_code": 1]), computerId: "mac")
        XCTAssertEqual(CommandWords.status(failed), "Failed · 1")
        XCTAssertEqual(CommandWords.took(failed, now: now), "2 min")
        XCTAssertEqual(CommandWords.tone(failed), .failed)
        let stopped = FleetCommand(Self.row("c", status: "stopped", extra: ["stopped_by_owner": true]), computerId: "mac")
        XCTAssertEqual(CommandWords.status(stopped), "Stopped by you")
        XCTAssertEqual(CommandWords.duration(41), "41 s")
        XCTAssertEqual(CommandWords.duration(3600 + 300), "1 h 5 min")
        XCTAssertEqual(CommandWords.duration(7200), "2 h")
        XCTAssertEqual(CommandWords.place(running, project: "PhD", computer: nil), "ML Engineer · PhD")
        XCTAssertEqual(CommandWords.place(running, project: "PhD", computer: "mac"), "ML Engineer · PhD · mac")
    }

    // MARK: The model

    private func source(_ fake: FakeCommands, id: String = "mac", daemon: String = "d-mac", supported: Bool = true) -> CommandsSource {
        CommandsSource(computerId: id, name: id, daemonId: daemon, supported: supported, service: fake)
    }

    func testLoadingListsAndCountsAndNamesOlderComputers() async {
        let fake = FakeCommands()
        fake.pages[nil] = CommandsPage(commands: [command("a")], summary: [CommandSummary(daemonId: "d-mac", computerName: "mac", running: 1, failedToday: 2)])
        let old = FakeCommands()
        let model = CommandsModel()
        await model.load([source(fake), source(old, id: "imac", daemon: "d-imac", supported: false)])
        XCTAssertEqual(model.rows.map(\.commandId), ["a"])
        XCTAssertEqual(model.totals.failedToday, 2)
        XCTAssertEqual(model.unsupported, ["imac"])
        XCTAssertTrue(old.queries.isEmpty, "an older daemon isn't asked")
        XCTAssertTrue(model.loaded)
        XCTAssertFalse(model.hasMore)
    }

    func testAFailureIsSaidPerComputer() async {
        let fake = FakeCommands()
        fake.error = DaemonError(code: "unavailable", message: "Offline")
        let model = CommandsModel()
        await model.load([source(fake)])
        XCTAssertEqual(model.failures["mac"], "Offline")
        XCTAssertTrue(model.rows.isEmpty)
    }

    func testFiltersReachEachComputerAsItsOwnIds() async {
        let mac = FakeCommands()
        let pc = FakeCommands()
        let model = CommandsModel()
        model.status = .failed
        model.query = "pytest"
        model.project = CommandsProjectChoice(name: "PhD", ids: ["mac": "p-mac", "pc": "p-pc"])
        await model.load([source(mac), source(pc, id: "pc", daemon: "d-pc")])
        XCTAssertEqual(mac.queries.last?.projectId, "p-mac")
        XCTAssertEqual(pc.queries.last?.projectId, "p-pc")
        XCTAssertEqual(mac.queries.last?.status, .failed)
        XCTAssertEqual(mac.queries.last?.query, "pytest")

        model.bot = CommandsBotChoice(computerId: "pc", botId: "b7", name: "Unity Dev")
        await model.load([source(mac), source(pc, id: "pc", daemon: "d-pc")])
        XCTAssertEqual(mac.queries.count, 1, "a bot is asked of its own computer only")
        XCTAssertEqual(pc.queries.last?.botId, "b7")
    }

    func testAProjectAComputerDoesntKnowIsntAskedOfIt() async {
        let mac = FakeCommands()
        let model = CommandsModel()
        model.project = CommandsProjectChoice(name: "Books", ids: ["pc": "p-books"])
        await model.load([source(mac)])
        XCTAssertTrue(mac.queries.isEmpty)
    }

    func testShowMoreAppendsTheNextPage() async {
        let fake = FakeCommands()
        fake.pages[nil] = CommandsPage(commands: [command("a", started: "2026-10-22T14:00:00Z")], summary: [], nextBefore: "c1")
        fake.pages["c1"] = CommandsPage(commands: [command("b", status: "done", started: "2026-10-22T13:00:00Z")], summary: [])
        let model = CommandsModel()
        await model.load([source(fake)])
        XCTAssertTrue(model.hasMore)
        await model.loadMore()
        XCTAssertEqual(model.rows.map(\.commandId), ["a", "b"])
        XCTAssertEqual(fake.queries.last?.before, "c1")
        XCTAssertFalse(model.hasMore)
    }

    func testABurstOfPushesReadsOnce() async throws {
        let fake = FakeCommands()
        let model = CommandsModel()
        model.debounce = .milliseconds(50)
        await model.load([source(fake)])
        model.changed()
        model.changed()
        model.changed()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(fake.queries.count, 2, "the first load, then one read for the burst")
    }

    func testStopReplacesTheRowAndSaysARefusal() async {
        let fake = FakeCommands()
        fake.pages[nil] = CommandsPage(commands: [command("a")], summary: [])
        fake.stopped = FleetCommand(Self.row("a", status: "stopped", extra: ["stopped_by_owner": true]), computerId: "mac")
        let model = CommandsModel()
        await model.load([source(fake)])
        let ok = await model.stop(model.rows[0])
        XCTAssertTrue(ok)
        XCTAssertEqual(fake.stops.first?.botId, "ml")
        XCTAssertEqual(fake.stops.first?.commandId, "a", "the command's own id, not the merged one")
        XCTAssertEqual(model.rows[0].status, "stopped")
        XCTAssertTrue(model.rows[0].stoppedByOwner)

        fake.pages[nil] = CommandsPage(commands: [command("b")], summary: [])
        fake.stopError = DaemonError(code: "conflict", message: "It already ended.")
        await model.load([source(fake)])
        let refused = await model.stop(model.rows[0])
        XCTAssertFalse(refused)
        XCTAssertEqual(model.stopFailure, "It already ended.")
        let foreground = await model.stop(command("c", background: false))
        XCTAssertFalse(foreground, "a foreground command isn't sent")
        XCTAssertEqual(fake.stops.count, 2)
    }

    func testTheCapabilityGatesTheList() {
        let store = AppStore(defaults: ComputerDefaults(id: "commands-test"))
        XCTAssertFalse(store.hasCommandsList)
        store.capabilities = ["commands_v1"]
        XCTAssertTrue(store.hasCommandsList)
    }
}
