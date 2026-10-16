import SwiftProtobuf
import XCTest
@testable import Flotilla

/// Board glance, phase 2 (0.20): a project's bots from its bot list, a
/// stopped bot first with Restart, hidden columns, and when an offline
/// computer was last seen.
@MainActor
final class BoardGlanceBotsTests: XCTestCase {
    private func bot(_ name: String, _ status: Flotilla_Home_V1_BotStatus, lead: Bool = false) -> HomeBotBrief {
        var bot = HomeBotBrief()
        bot.daemonID = "d-mac"
        bot.botID = name.lowercased()
        bot.name = name
        bot.status = status
        bot.lead = lead
        return bot
    }

    private func attention(_ kind: HomeAttentionKind, id: String, state: String = "") -> HomeAttentionRow {
        var row = HomeAttentionRow()
        row.id = id
        row.kind = kind
        row.botState = state
        return row
    }

    private func column(_ name: String, _ category: String, _ count: UInt32, hidden: Bool = false) -> HomeColumn {
        var column = HomeColumn()
        column.key = name.lowercased()
        column.name = name
        column.category = category
        column.count = count
        column.hidden = hidden
        return column
    }

    // MARK: Fleet

    func testTheBotListCountsTheFleet() {
        var row = HomeRow()
        row.bots = 8
        row.botList = [bot("Lead", .working, lead: true), bot("Ada", .waiting), bot("Tess", .failed),
                       bot("Ivo", .stopped), bot("Zed", .idle), bot("Pc", .offline)]
        XCTAssertEqual(GlanceWords.fleet(row), "1 working · 1 waiting · 2 stopped · 3 idle · 1 offline")
        XCTAssertEqual(GlanceWords.fleetSentence(row), "8 bots: 1 working, 1 waiting, 2 stopped, 3 idle, 1 offline.")
        row.botList = [bot("Lead", .idle, lead: true)]
        row.bots = 1
        XCTAssertEqual(GlanceWords.fleet(row), "1 idle")
        XCTAssertEqual(GlanceWords.fleetSentence(row), "1 bot, all idle.")
    }

    func testTheAvatarsAreWhoIsBusyElseTheLead() {
        let busy = GlanceFleet.shown([bot("Lead", .idle, lead: true), bot("Ada", .waiting), bot("Bo", .working),
                                      bot("Cy", .idle), bot("Di", .failed), bot("Ed", .working), bot("Fy", .working)])
        XCTAssertEqual(busy.map(\.name), ["Ada", "Bo", "Di", "Ed"])
        XCTAssertEqual(GlanceFleet.shown([bot("Lead", .idle, lead: true), bot("Cy", .idle)]).map(\.name), ["Lead"])
        XCTAssertTrue(GlanceFleet.shown([]).isEmpty)
    }

    // MARK: Stopped bots

    func testAStoppedBotRestartsUnlessItCantSignInOrIsLimited() {
        let crashed = attention(.botStopped, id: "a", state: "crashed")
        let stopped = attention(.botStopped, id: "b", state: "stopped")
        let auth = attention(.botStopped, id: "c", state: "auth_failed")
        let limited = attention(.botStopped, id: "d", state: "rate_limited")
        XCTAssertTrue(StoppedBot.restarts(crashed))
        XCTAssertTrue(StoppedBot.restarts(stopped))
        XCTAssertFalse(StoppedBot.restarts(auth))
        XCTAssertFalse(StoppedBot.restarts(limited))
        XCTAssertFalse(StoppedBot.restarts(attention(.botWaiting, id: "e")))
        XCTAssertEqual(AskAction.label(crashed, opens: .bot(computerId: "m", botId: "b", chat: true)), "Restart")
        XCTAssertNil(StoppedBot.advice(crashed, on: "mac"))
        XCTAssertEqual(StoppedBot.advice(auth, on: "mac"), "Sign its engine in again on mac, then restart it there.")
        XCTAssertNotNil(StoppedBot.advice(limited, on: "mac"))
    }

    func testAStoppedBotLeadsItsCardsAsks() {
        let rows = [attention(.releaseAwaiting, id: "r"), attention(.decision, id: "d"),
                    attention(.botStopped, id: "s", state: "crashed")]
        XCTAssertEqual(StoppedBot.first(rows).map(\.id), ["s", "r", "d"])
    }

    func testAStoppedBotsProjectLeadsNeedsYou() {
        func card(_ name: String, stopped: Bool) -> HomeCard {
            var row = HomeRow()
            row.projectID = name
            row.name = name
            row.attention.count = 1
            row.attention.byKind[stopped ? "bot_stopped" : "decision"] = 1
            return HomeCard(row: row, computerId: "mac", staleNames: [], staleSince: nil)
        }
        let ordered = BoardGlance.ordered([card("A", stopped: false), card("B", stopped: true), card("C", stopped: false)])
        XCTAssertEqual(ordered.map(\.row.name), ["B", "A", "C"])
    }

    func testTheTopRowStandsInUntilTheAsksLoad() {
        var row = HomeRow()
        row.projectID = "p"
        row.attention.count = 2
        row.topAttention = attention(.botStopped, id: "s", state: "crashed")
        let card = HomeCard(row: row, computerId: "mac", staleNames: [], staleSince: nil)
        XCTAssertEqual(HomeFeed(cacheDirectory: nil).asks(for: card).map(\.id), ["s"])
    }

    // MARK: Columns and presence

    func testHiddenColumnsAreLeftOutAndReviewIsFoundByItsKey() {
        let segments = MiniBoard.segments([column("To do", "inbox", 2), column("Review", "doing", 1),
                                           column("Done", "done", 4), column("Cancelled", "cancelled", 3, hidden: true)])
        XCTAssertEqual(segments.map(\.name), ["To do", "Review", "Done"])
        XCTAssertEqual(segments[1].shade, .review)
    }

    func testAnOfflineComputerIsLastSeenWhenItsLinkWasUp() {
        var row = HomeRow()
        var mac = Flotilla_Home_V1_Member()
        mac.daemonID = "d-mac"
        mac.online = true
        var pc = Flotilla_Home_V1_Member()
        pc.daemonID = "d-pc"
        pc.online = false
        let seen = Date(timeIntervalSince1970: 1_800_000_000)
        pc.lastSeenAt = Google_Protobuf_Timestamp(date: seen)
        row.members = [mac, pc]
        XCTAssertEqual(GlanceFleet.lastSeen(row, among: ["d-pc"]), seen)
        XCTAssertNil(GlanceFleet.lastSeen(row, among: ["d-mac"]))
        let card = HomeCard(row: row, computerId: "mac", staleNames: ["pc"], staleSince: seen.addingTimeInterval(-600),
                            offline: ["d-pc"])
        XCTAssertEqual(GlanceWords.lastSeen(card, readOnly: false),
                       "Last seen \(seen.formatted(date: .omitted, time: .shortened))")
    }
}
