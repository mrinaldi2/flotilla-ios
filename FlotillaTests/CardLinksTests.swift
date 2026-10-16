import SwiftProtobuf
import XCTest
@testable import Flotilla

/// H-204 (UX-035): card ids are links on known prefixes only, never inside
/// code or names; the preview and its notices use the UX words.
@MainActor
final class CardLinksTests: XCTestCase {
    private let prefixes: Set<String> = ["H", "QA"]

    func testOnlyKnownIdsOnWordBoundariesAreLinked() {
        // UX-035 §10.1.
        let text = "see H-189 and UTF-8, branch H-189-project-clicks, `H-190`"
        XCTAssertEqual(CardLinker.ids(in: text, prefixes: prefixes), ["H-189", "H-190"])
        let linked = CardLinker.linked(text, prefixes: prefixes)
        XCTAssertTrue(linked.hasPrefix("see [H-189](flotilla://item/H-189) and UTF-8"))
        XCTAssertTrue(linked.contains("branch H-189-project-clicks,"), "a branch name stays text")
        XCTAssertTrue(linked.hasSuffix("[`H-190`](flotilla://item/H-190)"), "inline code that is the id is linked, as code")
    }

    func testCodeLinksAndURLsAreLeftAlone() {
        let text = """
        Fixed in H-12.
        ```
        git log H-13
        ```
        See [the card](https://example.com/H-14), https://example.com/H-15 and `run H-16 now`.
        """
        XCTAssertEqual(CardLinker.ids(in: text, prefixes: prefixes), ["H-12"])
    }

    func testUnknownPrefixesAndLongNumbersStayText() {
        XCTAssertTrue(CardLinker.ids(in: "SHA-256, ISO-8601, X-1, H-123456", prefixes: prefixes).isEmpty)
        XCTAssertEqual(CardLinker.ids(in: "QA-7 then H-7, again H-7.", prefixes: prefixes), ["QA-7", "H-7"])
    }

    func testTheLinkURLRoundTrips() {
        XCTAssertEqual(CardLinker.id(from: CardLinker.url("H-293")), "H-293")
        XCTAssertEqual(CardLinker.url("H-293").absoluteString, "flotilla://item/H-293")
        XCTAssertEqual(CardLinker.id(from: URL(string: "flotilla://item/H-293")!), "H-293", "from a notification")
        XCTAssertEqual(CardLinker.id(from: URL(string: "thehermes://item/H-293")!), "H-293", "from before the rename")
        XCTAssertEqual(CardLinker.id(from: URL(string: "hermes://item/H-293")!), "H-293", "a link written before the rename")
        XCTAssertNil(CardLinker.id(from: URL(string: "https://example.com/item/H-1")!))
        XCTAssertNil(CardLinker.id(from: URL(string: "flotilla://pair?host=x")!))
    }

    func testTheProjectOnScreenWinsWhenPrefixesCollide() {
        let directory = CardDirectory()
        directory.setForTests(["H": [.init(computerId: "mac", projectId: "p1", projectName: "The Hermes"),
                                     .init(computerId: "imac", projectId: "p2", projectName: "Other")]])
        XCTAssertEqual(directory.home(for: "H-3")?.projectId, "p1", "else the first")
        XCTAssertEqual(directory.home(for: "H-3", preferring: ["p2"])?.projectId, "p2")
        XCTAssertNil(directory.home(for: "Z-3"))
    }

    func testALinkWaitsForTheProjectsThenOpensOrSaysNotFound() {
        // H-216: on a cold start the link arrives before the projects.
        let fleet = Fleet()
        let home = CardDirectory.Home(computerId: "mac", projectId: "p1", projectName: "The Hermes")
        fleet.cards.setForTests([:], settled: false)
        fleet.openCard = "H-216"
        XCTAssertEqual(fleet.cards.resolve("H-216"), .waiting)
        XCTAssertNil(fleet.takeOpenCard())
        XCTAssertEqual(fleet.openCard, "H-216", "kept until the projects load")
        XCTAssertNil(fleet.missingCard)

        fleet.cards.setForTests(["H": [home]], settled: true)
        let taken = fleet.takeOpenCard()
        XCTAssertEqual(taken?.id, "H-216")
        XCTAssertEqual(taken?.home, home)
        XCTAssertNil(fleet.openCard, "taken once")
        XCTAssertNil(fleet.takeOpenCard())

        // A prefix no project uses, once they have all loaded: dropped, and said.
        fleet.openCard = "ZZ-9"
        XCTAssertEqual(fleet.cards.resolve("ZZ-9"), .unknown)
        XCTAssertNil(fleet.takeOpenCard())
        XCTAssertNil(fleet.openCard)
        XCTAssertEqual(fleet.missingCard, "ZZ-9")
        XCTAssertEqual(CardPreview.unseen("ZZ-9"),
                       "ZZ-9 isn't on any board this iPhone can see. It may be mistyped, or kept on a computer this iPhone isn't linked to.")
        // A known prefix keeps the board's own form.
        XCTAssertEqual(CardPreview(id: "H-9", state: .missing).notice,
                       "H-9 isn't on the board. It may have been deleted or mistyped.")
    }

    func testAWaitingLinkSaysOpeningThenGivesUp() async {
        // UX-044: never hangs. "Opening…" after 3 s, given up after 15 s (scaled down here).
        let fleet = Fleet()
        fleet.cards.setForTests([:], settled: false)
        fleet.openCard = "ZZ-404"
        let watch = Task { await fleet.watchOpenCard(showAfter: .milliseconds(50), giveUpAfter: .milliseconds(150)) }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(fleet.openingCard, "not before showAfter")
        try? await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(fleet.openingCard, "ZZ-404")
        await watch.value
        XCTAssertNil(fleet.openCard)
        XCTAssertNil(fleet.openingCard)
        XCTAssertEqual(fleet.missingCard, "ZZ-404", "said as an unknown id is")
    }

    func testALinkThatOpensInTimeIsNotGivenUp() async {
        let fleet = Fleet()
        fleet.cards.setForTests([:], settled: false)
        fleet.openCard = "H-216"
        let watch = Task { await fleet.watchOpenCard(showAfter: .milliseconds(30), giveUpAfter: .milliseconds(100)) }
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(fleet.openingCard, "H-216")
        fleet.cards.setForTests(["H": [.init(computerId: "mac", projectId: "p1", projectName: "The Hermes")]])
        XCTAssertEqual(fleet.takeOpenCard()?.id, "H-216")
        XCTAssertNil(fleet.openingCard, "the banner goes with the link")
        await watch.value
        XCTAssertNil(fleet.missingCard)
    }

    func testTheDirectoryIsNotSettledUntilEveryConnectedComputersProjectsLoad() async {
        let directory = CardDirectory()
        await directory.refresh([])
        XCTAssertFalse(directory.settled, "no computer connected: nothing to tell yet")
        XCTAssertEqual(directory.resolve("H-1"), .waiting)
    }

    func testThePreviewSaysWhatTheCardIs() {
        var preview = CardPreview(id: "H-293", state: .found, project: "The Hermes")
        preview.type = "Bug"
        preview.priority = "P0"
        preview.title = "Main chat drops the bot's answer"
        preview.column = "Doing"
        preview.assignee = "Desktop Dev"
        preview.blocked = true
        preview.release = "0.17.3"
        XCTAssertEqual(preview.heading, "H-293 · Bug · P0")
        XCTAssertEqual(preview.placeLine, "Doing · Desktop Dev")
        XCTAssertEqual(preview.flagsLine, "⛔ Blocked · in 0.17.3")
        XCTAssertNil(preview.notice)
        XCTAssertEqual(preview.accessibilityName, "H-293: Main chat drops the bot's answer")

        preview.priority = "P2"
        preview.assignee = nil
        XCTAssertEqual(preview.heading, "H-293 · Bug", "priority only for P0/P1")
        XCTAssertEqual(preview.placeLine, "Doing · Unassigned")
    }

    func testNoticesSayWhatHappenedAndWhere() {
        XCTAssertEqual(CardPreview(id: "H-999", state: .missing, project: "The Hermes").notice,
                       "H-999 isn't on The Hermes's board. It may have been deleted or mistyped.")
        let seen = Calendar.current.date(bySettingHour: 13, minute: 30, second: 0, of: Date())!
        var offline = CardPreview(id: "H-293", state: .offline(computer: "imac", lastSeen: seen), project: "The Hermes")
        offline.title = "Main chat drops the bot's answer"
        let time = seen.formatted(date: .omitted, time: .shortened)
        XCTAssertEqual(offline.notice,
                       "H-293 is on The Hermes's board, kept on imac. imac is offline · last seen \(time).\nLast seen as: Main chat drops the bot's answer")
        XCTAssertEqual(CardPreview(id: "H-1", state: .oldService(computer: "win-pc")).notice,
                       "Update the Flotilla service on win-pc to see cards from here.")
        XCTAssertEqual(CardPreview(id: "H-1", state: .missing).accessibilityName, "H-1, card")
    }

    func testAnItemCardsAnswerFillsThePreview() {
        let answer = ItemCardAnswer([
            "id": "H-12", "project_name": "The Hermes", "computer": "mac", "column_name": "Review", "release": "0.17.4",
            "card": ["id": "H-12", "type": "ITEM_TYPE_FEATURE", "title": "Card links", "priority": "PRIORITY_P1",
                     "column_key": "review", "assignee": "b1", "blocked": false],
        ])
        let preview = answer.preview(CardPreview(id: "H-12", state: .found)) { $0 == "b1" ? "iOS Dev" : nil }
        XCTAssertEqual(preview.heading, "H-12 · Feature · P1")
        XCTAssertEqual(preview.placeLine, "Review · iOS Dev")
        XCTAssertEqual(preview.flagsLine, "in 0.17.4")
        XCTAssertEqual(ItemCardAnswer(["id": "H-9", "missing": true]).preview(CardPreview(id: "H-9", state: .found)) { _ in nil }.state,
                       .missing)
    }

    func testAnUnknownComputerIsAnotherComputer() {
        var offline = CardPreview(id: "H-293", state: .offline(computer: nil, lastSeen: nil), project: "The Hermes")
        XCTAssertEqual(offline.notice, "H-293 is on The Hermes's board, kept on another computer, which is offline.")
        offline.title = "Card links"
        XCTAssertEqual(offline.notice, "H-293 is on The Hermes's board, kept on another computer, which is offline.\nLast seen as: Card links")
    }

    func testMenuEntriesNeverShowABareId() {
        XCTAssertEqual(CardMenuWords.entry("HL-005", nil), "HL-005 · Loading…")
        var found = CardPreview(id: "HL-005", state: .found)
        found.title = "Owner threads read marks"
        XCTAssertEqual(CardMenuWords.entry("HL-005", found), "HL-005 · Owner threads read marks")
        XCTAssertEqual(CardMenuWords.entry("HL-009", CardPreview(id: "HL-009", state: .missing, project: "Hermes Lab")),
                       "HL-009 isn't on Hermes Lab's board. It may have been deleted or mistyped.")
    }

    func testTheCardScreenSaysWhereTheCardStands() {
        var item = Flotilla_Board_V1_Item()
        item.id = "HL-004"
        item.title = "Board chips on iPad"
        item.type = .bug
        item.priority = .p0
        item.columnKey = "doing"
        item.assignee = "b1"
        let facts = CardPreview.of(item) { $0 == "b1" ? "Desktop Dev" : nil }
        XCTAssertEqual(facts.kindLine, "Bug · P0")
        XCTAssertEqual(facts.placeLine, "Doing · Desktop Dev")
        item.priority = .p2
        item.clearAssignee()
        let plain = CardPreview.of(item) { _ in nil }
        XCTAssertEqual(plain.kindLine, "Bug")
        XCTAssertEqual(plain.placeLine, "Doing · Unassigned")
    }
}
