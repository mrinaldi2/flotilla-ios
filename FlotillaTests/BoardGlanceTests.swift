import SwiftProtobuf
import SwiftUI
import XCTest
@testable import Flotilla

/// Board glance (0.20 phase 1, BG-Rules): the Projects tab's filter, its
/// order and quiet rows, each card's state pill, mini board and ask, and the
/// routes that used to open the Needs you tab.
@MainActor
final class BoardGlanceTests: XCTestCase {
    /// The fixture's `as_of`: its times are read from here.
    private let now = ISO8601DateFormatter().date(from: "2026-10-16T10:42:00Z")!

    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures/home/board-glance.json")

    /// The fixture's cards as the feed merges them, for one computer.
    private func fixtureCards() throws -> [HomeCard] {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixture))
        let overview = try HomeJSON.decode(HomeOverview.self, json)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let computer = Computer(ComputerRecord(name: "Mac", kind: .mac, host: "127.0.0.1", port: 1), token: nil)
        let data: Data = try overview.serializedData()
        try data.write(to: folder.appendingPathComponent("\(computer.id).pb"))
        let feed = HomeFeed(cacheDirectory: folder)
        feed.loadCache([computer])
        return feed.cards([computer])
    }

    private func card(_ name: String, in cards: [HomeCard]) throws -> HomeCard {
        try XCTUnwrap(cards.first { $0.row.name == name }, name)
    }

    private func row(attention: UInt32 = 0, working: UInt32 = 0, waiting: UInt32 = 0, bots: UInt32 = 2,
                     columns: [(String, String, UInt32)] = [("To do", "inbox", 1)], active: Date? = nil,
                     home: String = "", members: [String] = [], stale: [String] = []) -> HomeRow {
        var row = HomeRow()
        row.projectID = "p"
        row.name = "P"
        row.attention.count = attention
        row.attention.score = attention
        row.botsWorking = working
        row.botsWaiting = waiting
        row.bots = bots
        row.columns = columns.map(column)
        if let active { row.lastActivityAt = Google_Protobuf_Timestamp(date: active) }
        row.boardHome = home
        row.members = members.map { id in
            var member = Flotilla_Home_V1_Member()
            member.daemonID = id
            return member
        }
        row.staleSources = stale
        return row
    }

    private func column(_ spec: (String, String, UInt32)) -> HomeColumn {
        var column = HomeColumn()
        column.name = spec.0
        column.key = spec.0.lowercased()
        column.category = spec.1
        column.count = spec.2
        return column
    }

    private func card(_ row: HomeRow, offline: Set<String> = []) -> HomeCard {
        HomeCard(row: row, computerId: "mac", staleNames: offline.isEmpty ? [] : ["imac"], staleSince: nil, offline: offline)
    }

    // MARK: Filter

    func testFilterCountsAndMembership() throws {
        let cards = try fixtureCards()
        XCTAssertEqual(cards.count, 10)
        let counts = BoardGlance.counts(cards, now: now)
        XCTAssertEqual(counts[.all], 10)
        XCTAssertEqual(counts[.needsYou], 2)
        XCTAssertEqual(counts[.working], 2)
        XCTAssertEqual(counts[.quiet], 4)
        func names(_ filter: HomeFilter) -> [String] {
            BoardGlance.ordered(cards, now: now).filter { BoardGlance.matches($0, filter, now: now) }.map(\.row.name)
        }
        XCTAssertEqual(names(.needsYou), ["PhD", "Recipe Box"], "by score")
        XCTAssertEqual(names(.working), ["Portfolio Site", "Unity Maze"], "by name")
        XCTAssertEqual(names(.quiet), ["Books", "Garden Planner", "Old Blog", "Tax 2026"])
        // Idle but active today, and a project still being set up: All only, as full cards.
        XCTAssertEqual(names(.all).filter { !names(.needsYou).contains($0) && !names(.working).contains($0) && !names(.quiet).contains($0) },
                       ["Calm", "Thesis writing"])
    }

    func testOrderIsNeedsYouWorkingTheRestThenQuiet() throws {
        let ordered = BoardGlance.ordered(try fixtureCards(), now: now).map(\.row.name)
        XCTAssertEqual(ordered, ["PhD", "Recipe Box", "Portfolio Site", "Unity Maze", "Calm", "Thesis writing",
                                 "Books", "Garden Planner", "Old Blog", "Tax 2026"])
    }

    func testOrderInsideAGroupDoesNotFollowActivity() {
        var a = row(working: 1, active: now)
        a.name = "Zeta"
        var b = row(working: 1, active: now.addingTimeInterval(-3600))
        b.name = "Alpha"
        var pinned = row(working: 1, active: now.addingTimeInterval(-7200))
        pinned.name = "Mid"
        pinned.pinned = true
        let ordered = BoardGlance.ordered([card(a), card(b), card(pinned)], now: now).map(\.row.name)
        XCTAssertEqual(ordered, ["Mid", "Alpha", "Zeta"], "pinned first, then by name; the latest activity doesn't move a card")
    }

    func testChipsShowFromFiveProjectsOrWhileAFilterIsOn() {
        XCTAssertFalse(BoardGlance.showsFilters(projects: 4, filter: .all))
        XCTAssertTrue(BoardGlance.showsFilters(projects: 5, filter: .all))
        XCTAssertTrue(BoardGlance.showsFilters(projects: 2, filter: .needsYou), "so it can be turned off")
    }

    // MARK: Quiet

    func testQuietRule() {
        let old = now.addingTimeInterval(-BoardGlance.quietAfter - 60)
        XCTAssertTrue(BoardGlance.isQuiet(row(active: old), now: now))
        XCTAssertFalse(BoardGlance.isQuiet(row(active: now.addingTimeInterval(-3600)), now: now), "active within a day")
        XCTAssertFalse(BoardGlance.isQuiet(row(attention: 1, active: old), now: now), "something needs you")
        XCTAssertFalse(BoardGlance.isQuiet(row(working: 1, active: old), now: now), "a bot works")
        XCTAssertFalse(BoardGlance.isQuiet(row(waiting: 1, active: old), now: now), "a bot waits for you")
        XCTAssertFalse(BoardGlance.isQuiet(row(), now: now), "never said when it was last active")
        XCTAssertFalse(BoardGlance.isQuiet(row(bots: 0, columns: [], active: old), now: now), "still being set up")
        XCTAssertEqual(BoardGlance.group(card(row(active: old)), now: now), .quiet)
    }

    func testQuietRowWords() throws {
        let books = try card("Books", in: try fixtureCards())
        XCTAssertEqual(GlanceWords.quietMeta(books.row, now: now), "16 cards · 3 d")
        XCTAssertEqual(GlanceWords.age(now.addingTimeInterval(-2 * 7 * 86_400), now: now), "2 w")
        XCTAssertEqual(GlanceWords.age(now.addingTimeInterval(-40 * 86_400), now: now), "1 mo")
        XCTAssertEqual(GlanceWords.age(now.addingTimeInterval(-5 * 3600), now: now), "5 h")
    }

    // MARK: State pill

    func testStatePillPrecedence() {
        XCTAssertEqual(BoardGlance.state(card(row())), .idle)
        XCTAssertEqual(BoardGlance.state(card(row(working: 2))), .working)
        XCTAssertEqual(BoardGlance.state(card(row(bots: 0, columns: []))), .setUp)
        XCTAssertEqual(BoardGlance.state(card(row(bots: 0, columns: [], active: now))), .setUp)
        XCTAssertEqual(BoardGlance.state(card(row(attention: 3, working: 2))), .needsYou(3), "Needs you over Working")
        XCTAssertEqual(BoardGlance.state(card(row(attention: 1, bots: 0, columns: []))), .needsYou(1), "over Set up")
        // The board's home away: read only, over everything.
        let away = row(attention: 2, working: 1, home: "d-imac", members: ["d-imac", "d-mac"], stale: ["d-imac"])
        XCTAssertEqual(BoardGlance.state(card(away, offline: ["d-imac"])), .readOnly)
        // A linked computer away while the board's home answers: the card keeps its state.
        let partly = row(attention: 2, home: "d-mac", members: ["d-mac", "d-imac"], stale: ["d-imac"])
        XCTAssertEqual(BoardGlance.state(card(partly, offline: ["d-imac"])), .needsYou(2))
        // Stale only because it is too old to say everything: not away.
        XCTAssertEqual(BoardGlance.state(card(away, offline: [])), .needsYou(2))
        // No board: read only when every member is away.
        XCTAssertEqual(BoardGlance.state(card(row(members: ["d-imac"], stale: ["d-imac"]), offline: ["d-imac"])), .readOnly)
    }

    func testPillWordsAndGlyphs() {
        XCTAssertEqual(ProjectState.needsYou(1).pill, "! Needs you")
        XCTAssertEqual(ProjectState.needsYou(5).pill, "! Needs you · 5")
        XCTAssertEqual(ProjectState.working.pill, "◔ Working")
        XCTAssertEqual(ProjectState.idle.pill, "○ Idle")
        XCTAssertEqual(ProjectState.readOnly.pill, "⌁ Read only")
        XCTAssertEqual(ProjectState.setUp.pill, "+ Set up")
        XCTAssertEqual(ProjectState.readOnly.spoken, "Read only", "VoiceOver hears the word, not the glyph")
    }

    func testOnlyAwayStaleSourcesMakeACardReadOnly() throws {
        let cards = try fixtureCards()
        let maze = try card("Unity Maze", in: cards)
        XCTAssertEqual(maze.offline, ["d-imac"])
        XCTAssertEqual(BoardGlance.state(maze), .readOnly)
        XCTAssertEqual(GlanceWords.offline(maze), "Studio iMac is offline")
        XCTAssertEqual(GlanceWords.fleet(maze.row, readOnly: true), "5 bots · status unknown")
        XCTAssertEqual(BoardGlance.state(try card("PhD", in: cards)), .needsYou(5))
        XCTAssertEqual(BoardGlance.state(try card("Thesis writing", in: cards)), .setUp)
    }

    // MARK: Mini board

    func testTheBarKeepsEveryColumnUpToFive() {
        let segments = MiniBoard.segments([("To do", "inbox", 9), ("Doing", "doing", 3), ("Review", "review", 0), ("Done", "done", 21)].map(column))
        XCTAssertEqual(segments.map(\.name), ["To do", "Doing", "Review", "Done"])
        XCTAssertEqual(segments.map(\.count), [9, 3, 0, 21], "an empty column keeps its label")
        XCTAssertEqual(segments.map(\.shade), [.todo, .doing, .review, .done])
        XCTAssertEqual(MiniBoard.spoken(segments), "9 To do, 3 Doing, 0 Review, 21 Done")
    }

    func testSixColumnsFoldToFiveBeforeDone() {
        let columns = [("Inbox", "inbox", 3), ("Ready", "ready", 2), ("Doing", "doing", 1), ("Review", "review", 1),
                       ("Release", "deploying", 2), ("Done", "done", 30)].map(column)
        let segments = MiniBoard.segments(columns)
        XCTAssertEqual(segments.count, 5)
        XCTAssertEqual(segments.map(\.name), ["Inbox", "Doing", "Review", "+2 more", "Done"])
        XCTAssertEqual(segments[3].count, 4, "Ready's 2 and Release's 2")
        XCTAssertEqual(segments[3].columns, 2)
        XCTAssertEqual(segments[3].shade, .more)
        XCTAssertEqual(MiniBoard.spoken(segments), "3 Inbox, 1 Doing, 1 Review, 4 in 2 more columns, 30 Done")
    }

    func testFoldingKeepsDoneLastWhenAColumnFollowsIt() {
        let columns = [("A", "inbox", 1), ("B", "ready", 1), ("C", "doing", 1), ("D", "review", 1), ("E", "verify", 1),
                       ("Done", "done", 5), ("Cancelled", "cancelled", 2)].map(column)
        let segments = MiniBoard.segments(columns)
        XCTAssertLessThanOrEqual(segments.count, MiniBoard.maxSegments)
        XCTAssertEqual(segments.last?.name, "Done")
        XCTAssertEqual(segments.map(\.name), ["A", "C", "D", "+3 more", "Done"])
        XCTAssertEqual(segments[3].count, 1 + 1 + 2, "B, E and Cancelled")
    }

    func testWithoutCategoriesTheLastColumnIsDone() {
        let columns = (1...7).map { ("Column \($0)", "", UInt32($0)) }.map(column)
        let segments = MiniBoard.segments(columns)
        XCTAssertEqual(segments.count, 5)
        XCTAssertEqual(segments.map(\.name), ["Column 1", "Column 2", "Column 3", "+3 more", "Column 7"])
        XCTAssertEqual(segments.first?.shade, .todo)
        XCTAssertEqual(segments.last?.shade, .done)
        XCTAssertEqual(segments[3].count, 4 + 5 + 6)
    }

    func testSegmentWidthsFollowCountsWithAFloor() {
        let widths = MiniBoardBar.widths([1, 30], room: 310)
        XCTAssertEqual(widths.reduce(0, +), 310, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(widths[0], 4)
        XCTAssertEqual(MiniBoardBar.widths([1, 1], room: 100), [50, 50])
    }

    // MARK: Fleet and words

    func testFleetWords() {
        XCTAssertEqual(GlanceWords.fleet(row(working: 2, bots: 14)), "2 working · 12 idle")
        XCTAssertEqual(GlanceWords.fleet(row(working: 1, waiting: 1, bots: 5)), "1 working · 1 waiting · 3 idle")
        XCTAssertEqual(GlanceWords.fleet(row(bots: 3)), "3 idle")
        XCTAssertEqual(GlanceWords.fleet(row(bots: 0)), "No bots yet")
        XCTAssertEqual(GlanceWords.fleetSentence(row(working: 2, bots: 14)), "2 bots working, 12 idle.")
        XCTAssertEqual(GlanceWords.fleetSentence(row(bots: 3)), "3 bots, all idle.")
    }

    func testMonogramsAndStableColours() {
        XCTAssertEqual(GlanceWords.monogram("PhD"), "Ph")
        XCTAssertEqual(GlanceWords.monogram("Recipe Box"), "RB")
        XCTAssertEqual(GlanceWords.monogram("gravity"), "Gr")
        XCTAssertEqual(GlanceWords.monogram("Tax 2026"), "Ta")
        XCTAssertEqual(GlanceWords.monogram("2026 plans"), "Pl")
        XCTAssertEqual(GlanceWords.monogram(""), "?")
        let count = Color.projectGlyphs.count
        XCTAssertEqual(GlanceWords.paletteIndex("p-phd", count: count), GlanceWords.paletteIndex("p-phd", count: count))
        XCTAssertEqual(GlanceWords.paletteIndex("p-phd", count: count), 6, "FNV-1a, the same on every launch")
        XCTAssertTrue((0..<count).contains(GlanceWords.paletteIndex("anything", count: count)))
    }

    func testSummaryLine() {
        XCTAssertEqual(GlanceWords.summary(projects: 7, needs: 0, working: 4, offline: 0), "7 projects · 4 bots working")
        XCTAssertEqual(GlanceWords.summary(projects: 3, needs: 6, working: 2, offline: 0), "3 projects · 6 things need you")
        XCTAssertEqual(GlanceWords.summary(projects: 1, needs: 1, working: 0, offline: 1), "1 project · 1 thing needs you · 1 computer offline")
    }

    // MARK: Asks

    private func attention(_ kind: HomeAttentionKind, _ configure: (inout HomeAttentionRow) -> Void = { _ in }) -> HomeAttentionRow {
        var row = HomeAttentionRow()
        row.kind = kind
        row.title = "Something"
        configure(&row)
        return row
    }

    func testAskActionLabels() {
        let decision = NeedsDestination.decision(computerId: "mac", decisionId: "d")
        let bot = NeedsDestination.bot(computerId: "mac", botId: "b", chat: true)
        let note = NeedsDestination.note(title: "x", text: "y")
        XCTAssertEqual(AskAction.label(attention(.ownerQuestion), opens: bot), "Answer")
        XCTAssertEqual(AskAction.label(attention(.decision), opens: decision), "Decide")
        XCTAssertEqual(AskAction.label(attention(.permissionPrompt), opens: bot), "Approve")
        XCTAssertEqual(AskAction.label(attention(.releaseAwaiting), opens: .release(computerId: "mac", releaseId: "r")), "Review")
        XCTAssertEqual(AskAction.label(attention(.draftUpdated), opens: .item(computerId: "mac", itemId: "H-1")), "Review")
        XCTAssertEqual(AskAction.label(attention(.p0Item), opens: .item(computerId: "mac", itemId: "H-1")), "Open")
        XCTAssertEqual(AskAction.label(attention(.botWaiting), opens: bot), "Open")
        XCTAssertEqual(AskAction.label(attention(.permissionPrompt), opens: note), "Details", "answered on its own computer")
        XCTAssertEqual(AskAction.label(attention(.ownerAction), opens: note), "Details")
    }

    func testAnAskReadsAsTheGlossarySaysIt() {
        let prompt = attention(.permissionPrompt) { $0.title = "Backend Dev asks: Bash: rm -rf build/" }
        XCTAssertEqual(prompt.displayTitle, "Backend Dev wants to run Bash")
        XCTAssertTrue(prompt.needsSubtitle.hasPrefix("rm -rf build/ · Permission request"))
        let card = attention(.p0Item) { $0.title = "Login is down"; $0.itemID = "H-9" }
        XCTAssertEqual(card.displayTitle, "H-9 · Login is down")
    }

    func testDestinationsNameTheirComputer() {
        XCTAssertEqual(NeedsDestination.decision(computerId: "mac", decisionId: "d").computerId, "mac")
        XCTAssertEqual(NeedsDestination.reply(computerId: "pc", itemId: "H-1", commentId: "c").computerId, "pc")
        XCTAssertNil(NeedsDestination.note(title: "", text: "").computerId)
    }

    // MARK: Routes

    /// Everything that set `tab = .needs` before 0.20 now lands on Projects with Needs you on.
    func testEveryFormerNeedsYouRouteLandsOnProjectsFiltered() {
        let landings: [(String, HomeLanding)] = [
            ("⌘⇧N, See all in Needs you", HomeRoute.needsYou),
            ("decision notification or toast", HomeRoute.decision("d1", on: "mac")),
            ("permission card of a bot", HomeRoute.permissionCard(on: "mac", botId: "b1")),
            ("terminal permission card", HomeRoute.permissionCard(on: "mac", botId: "terminal")),
            ("permission card, bot unknown", HomeRoute.permissionCard(on: "mac", botId: nil)),
            ("-releaseStub", HomeRoute.release("r1", on: "mac")),
            ("-openTab needs", HomeRoute.tab(named: "needs")!),
        ]
        for (name, landing) in landings {
            XCTAssertEqual(landing.tab, .projects, name)
            XCTAssertEqual(landing.filter, .needsYou, name)
        }
        XCTAssertEqual(HomeRoute.decision("d1", on: "mac").push, .decision(computerId: "mac", decisionId: "d1"))
        XCTAssertEqual(HomeRoute.permissionCard(on: "mac", botId: "b1").push, .bot(computerId: "mac", botId: "b1", chat: false))
        XCTAssertNil(HomeRoute.permissionCard(on: "mac", botId: "terminal").push, "its read-only card heads Projects (H-108)")
        XCTAssertNil(HomeRoute.permissionCard(on: "mac", botId: nil).push)
        XCTAssertEqual(HomeRoute.release("r1", on: "mac").push, .release(computerId: "mac", releaseId: "r1"))
        XCTAssertNil(HomeRoute.needsYou.push)
    }

    func testOtherTabsLeaveTheFilterAlone() {
        XCTAssertEqual(HomeRoute.tab(named: "chat"), HomeLanding(tab: .chat, filter: nil))
        XCTAssertEqual(HomeRoute.tab(named: "settings"), HomeLanding(tab: .settings, filter: nil))
        XCTAssertNil(HomeRoute.tab(named: nil))
        XCTAssertNil(HomeRoute.tab(named: "bots"))
    }

    func testTheFeedStartsOnAll() {
        XCTAssertEqual(HomeFeed(cacheDirectory: nil).filter, .all)
    }
}
