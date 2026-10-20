import XCTest
@testable import Flotilla

/// The terminal draws a bot's `term` pushes in order, once each, and picks
/// up after a reconnect from the last one drawn.
@MainActor
final class TerminalFeedTests: XCTestCase {
    private final class Screen: TerminalDisplay {
        var drawn: [String] = []
        func reset() { drawn.append("<reset>") }
        func write(_ data: String) { drawn.append(data) }
    }

    private var screen: Screen!
    private var feed: TerminalFeed!
    private var store: AppStore!

    override func setUp() {
        screen = Screen()
        feed = TerminalFeed(botId: "b1")
        feed.display = screen
        store = AppStore(defaults: ComputerDefaults(id: "test-terminal-feed"))
        store.register(feed, for: "b1")
    }

    private func attached(seq: Int, resumed: Bool) {
        store.pushReceived("attached", ["type": "attached", "bot_id": "b1", "seq": seq, "resumed": resumed])
    }

    private func term(_ seq: Int, _ data: String, bot: String = "b1") {
        store.pushReceived("term", ["type": "term", "bot_id": bot, "seq": seq, "data": data])
    }

    func testAnEmptyScreenAsksForTheWholeRing() {
        let fields = feed.attachFields()
        XCTAssertEqual(fields["bot_id"] as? String, "b1")
        XCTAssertNil(fields["after_seq"])
    }

    func testPushesAreDrawnInOrderAndOnlyOnce() {
        _ = feed.attachFields()
        attached(seq: 2, resumed: false)
        term(1, "\u{1b}[31mred\u{1b}[0m ")
        term(2, "plain ")
        term(2, "plain ")   // the same push again
        term(1, "stale ")   // older than what is on screen
        term(5, "merged")   // several reads in one push: seq is the newest
        term(9, "other", bot: "b2")
        XCTAssertEqual(screen.drawn, ["<reset>", "\u{1b}[31mred\u{1b}[0m ", "plain ", "merged"])
        XCTAssertEqual(feed.cursor, 5)
    }

    func testPushesBeforeTheAttachIsAnsweredAreLeftToItsReplay() {
        _ = feed.attachFields()
        attached(seq: 1, resumed: false)
        term(1, "a")
        // Attach again (a reconnect): what still comes from the old attachment
        // is in the new replay, which starts after seq 1.
        XCTAssertEqual(feed.attachFields()["after_seq"] as? Int, 1)
        term(2, "b")
        XCTAssertTrue(feed.isAttaching)
        attached(seq: 2, resumed: true)
        term(2, "b")
        XCTAssertEqual(screen.drawn, ["<reset>", "a", "b"])
    }

    func testAReconnectResumesAfterTheLastPushDrawn() {
        var reattached = 0
        var resumes: [Bool] = []
        feed.onReattach = { reattached += 1 }
        feed.onAttached = { resumes.append($0) }
        _ = feed.attachFields()
        attached(seq: 3, resumed: false)
        term(3, "before ")

        feed.reattach()
        XCTAssertEqual(reattached, 1)
        let fields = feed.attachFields()
        XCTAssertEqual(fields["after_seq"] as? Int, 3)
        // The ring still joins up: the screen stays, only what was missed comes.
        attached(seq: 4, resumed: true)
        term(4, "missed")
        XCTAssertEqual(screen.drawn, ["<reset>", "before ", "missed"])
        XCTAssertEqual(resumes, [false, true])
        XCTAssertEqual(feed.cursor, 4)
    }

    func testAResumeTheRingLostClearsTheScreenAndRedrawsIt() {
        _ = feed.attachFields()
        attached(seq: 40, resumed: false)
        term(40, "old screen")

        XCTAssertEqual(feed.attachFields()["after_seq"] as? Int, 40)
        // Evicted past the cursor: the replay starts over from what is left,
        // with a seq the screen had passed.
        attached(seq: 900, resumed: false)
        term(800, "redrawn ")
        term(900, "and new")
        XCTAssertEqual(screen.drawn, ["<reset>", "old screen", "<reset>", "redrawn ", "and new"])
        XCTAssertEqual(feed.cursor, 900)
    }

    func testAFailedAttachDoesNotHoldBackTheNextOne() {
        _ = feed.attachFields()
        feed.attachFailed()   // not connected yet
        XCTAssertFalse(feed.isAttaching)
        _ = feed.attachFields()
        attached(seq: 1, resumed: false)
        term(1, "up")
        XCTAssertEqual(screen.drawn, ["<reset>", "up"])
    }

    func testAClosedTerminalGetsNothing() {
        _ = feed.attachFields()
        attached(seq: 0, resumed: false)
        store.unregister(feed, for: "b1")
        term(1, "after close")
        XCTAssertEqual(screen.drawn, ["<reset>"])
    }
}
