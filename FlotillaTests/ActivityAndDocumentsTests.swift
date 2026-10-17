import XCTest
@testable import Flotilla

/// Board activity toasts (0.20, as the desktop) and reading a card's
/// documents on the phone.
@MainActor
final class ActivityAndDocumentsTests: XCTestCase {
    private func activity(_ kind: Flotilla_Home_V1_BoardActivityKind, actor: String = "bot:b1") -> BoardActivity {
        var a = BoardActivity()
        a.kind = kind
        a.actor = actor
        a.actorName = "Writer"
        a.projectID = "p"
        a.itemID = "PH-12"
        a.itemTitle = "Dataset card"
        a.fromName = "Doing"
        a.toName = "Review"
        return a
    }

    private func notice(_ item: String = "PH-12", word: String = "Moved", actor: String = "bot:b1") -> ActivityNotice {
        ActivityNotice(actor: actor, actorLabel: "Writer", computerId: "mac", projectId: "p", itemId: item, itemTitle: "",
                       line: ActivityLine(glyph: "→", word: word, detail: ""))
    }

    override func setUp() {
        UserDefaults.standard.removeObject(forKey: ActivityFeed.enabledKey)
    }

    func testTheToastsSayWhatTheDesktopSays() {
        XCTAssertEqual(ActivityWords.line(activity(.moved)), ActivityLine(glyph: "→", word: "Moved", detail: "Doing → Review"))
        var picked = activity(.assigned)
        picked.assignee = "b1"
        XCTAssertEqual(ActivityWords.line(picked)?.word, "Picked up")
        var assigned = activity(.assigned, actor: "user")
        assigned.assignee = "b2"
        assigned.assigneeName = "Tester"
        XCTAssertEqual(ActivityWords.line(assigned)?.detail, "to Tester")
        var refused = activity(.moveRefused)
        refused.unmet = ["Review needs a PR."]
        XCTAssertEqual(ActivityWords.line(refused)?.detail, "to Review · Review needs a PR.")
        XCTAssertNil(ActivityWords.line(activity(.unspecified)))
        XCTAssertEqual(ActivityWords.actor("user", name: "", botName: { _ in nil }), "You")
        XCTAssertEqual(ActivityWords.actor("device:d", name: "iPad", botName: { _ in nil }), "You, on iPad")
        XCTAssertEqual(ActivityWords.actor("daemon", name: "", botName: { _ in nil }), "Automatic")
        XCTAssertEqual(ActivityWords.actor("bot:b1", name: "Old", botName: { _ in "Writer" }), "Writer")
    }

    func testTheOwnersOwnActionHereShowsNoToast() {
        var mine = activity(.moved, actor: "device:phone")
        mine.fromThisClient = true
        XCTAssertNil(ActivityWords.notice(mine, computerId: "mac", botName: { _ in nil }))
    }

    func testATurnOnACardStartsAndFinishesOnce() {
        var turns = TurnTracker()
        let bot = Bot(["id": "b1", "name": "Writer", "project_id": "p"])
        let start = turns.notice(botId: "b1", state: .working, itemId: "PH-12", itemTitle: "Card", bot: bot, computerId: "mac")
        XCTAssertEqual(start?.line.word, "Started")
        XCTAssertNil(turns.notice(botId: "b1", state: .waitingForApproval, itemId: nil, itemTitle: nil, bot: bot, computerId: "mac"),
                     "a wait inside the turn")
        let end = turns.notice(botId: "b1", state: .ready, itemId: nil, itemTitle: nil, bot: bot, computerId: "mac")
        XCTAssertEqual(end?.line.word, "Finished")
        XCTAssertEqual(end?.itemId, "PH-12")
        XCTAssertNil(turns.notice(botId: "b1", state: .working, itemId: nil, itemTitle: nil, bot: bot, computerId: "mac"),
                     "a chat turn says nothing")
    }

    func testOneActorsNoticesOnACardFoldIntoOneToast() {
        let feed = ActivityFeed()
        let now = Date()
        feed.add(notice(word: "Moved"), now: now)
        feed.add(notice(word: "Finished"), now: now.addingTimeInterval(3))
        XCTAssertEqual(feed.toasts.count, 1)
        XCTAssertEqual(feed.toasts[0].lines.map(\.word), ["Moved", "Finished"])
        feed.add(notice(word: "Moved"), now: now.addingTimeInterval(20))
        XCTAssertEqual(feed.toasts.count, 2, "after the window, a new toast")
        for n in 0..<4 { feed.add(notice("PH-\(n)"), now: now.addingTimeInterval(21)) }
        XCTAssertEqual(feed.toasts.count, ActivityFeed.maxToasts)
        XCTAssertEqual(feed.toasts.first?.itemId, "PH-3", "newest on top")
        feed.expire(now: now.addingTimeInterval(30))
        XCTAssertTrue(feed.toasts.isEmpty)
    }

    func testTheSwitchInSettingsKeepsToastsAway() {
        UserDefaults.standard.set(false, forKey: ActivityFeed.enabledKey)
        let feed = ActivityFeed()
        feed.add(notice())
        XCTAssertTrue(feed.toasts.isEmpty)
    }

    // MARK: Documents

    func testDocumentsAreReadByTypeOrName() {
        XCTAssertEqual(DocumentKind(mime: "text/markdown", name: "x"), .markdown)
        XCTAssertEqual(DocumentKind(mime: "", name: "specs/SPEC.md"), .markdown)
        XCTAssertEqual(DocumentKind(mime: "text/html", name: "r"), .html)
        XCTAssertEqual(DocumentKind(mime: "", name: "report.HTM"), .html)
        XCTAssertEqual(DocumentKind(mime: "application/pdf", name: "a"), .pdf)
        XCTAssertEqual(DocumentKind(mime: "text/plain", name: "build.log"), .text)
        XCTAssertNil(DocumentKind(mime: "application/zip", name: "a.zip"))
    }

    func testAPagesFilesAreAskedForBesideIt() throws {
        let page = try XCTUnwrap(DocumentURL.url(for: "reports/run 1/index.html"))
        XCTAssertEqual(DocumentURL.path(of: page, absolute: false), "reports/run 1/index.html")
        let css = try XCTUnwrap(URL(string: "style.css", relativeTo: page)?.absoluteURL)
        XCTAssertEqual(DocumentURL.path(of: css, absolute: false), "reports/run 1/style.css")
        let up = try XCTUnwrap(URL(string: "../shared/plot.png", relativeTo: page)?.absoluteURL)
        XCTAssertEqual(DocumentURL.path(of: up, absolute: false), "reports/shared/plot.png")
        // A bot's file on disk keeps its root.
        let file = try XCTUnwrap(DocumentURL.url(for: "/Users/a/bot/workspace/out/report.html"))
        let beside = try XCTUnwrap(URL(string: "chart.js", relativeTo: file)?.absoluteURL)
        XCTAssertEqual(DocumentURL.path(of: beside, absolute: true), "/Users/a/bot/workspace/out/chart.js")
        XCTAssertNil(DocumentURL.path(of: URL(string: "https://example.com/x.js")!, absolute: false))
    }

    func testAnAttachedPageIsOneFile() {
        let source = DocumentSource.attachment(id: "a1", name: "report.html", mime: "text/html")
        XCTAssertEqual(source.path, "report.html")
        XCTAssertEqual(AppStore.mime(for: "s.css"), "text/css")
        XCTAssertEqual(AppStore.mime(for: "plot.SVG"), "image/svg+xml")
    }
}
