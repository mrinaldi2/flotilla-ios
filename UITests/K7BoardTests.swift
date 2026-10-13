import XCTest

/// K7 on the demo world: the board live from pushes, its label chips (K8),
/// Move to… with the daemon's checks, a draft from + with a label and a
/// photo, and a lead's board proposal in Needs you. The draft and proposal tests
/// need a 0.19 daemon (DEMO_DAEMON) and skip on an older one.
///
/// The demo connects with the owner token, which a 0.19 daemon never lets
/// finalize, invite to or approve: those answers are checked as refusals
/// (or as done, on a paired device).
final class K7BoardTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
        if UIDevice.current.userInterfaceIdiom == .pad { throw XCTSkip("iPhone layout") }
        try requireLiveDaemon()
        // The Lab and its lead before any board starts: 0.19 gives the lead role to the project's lead.
        _ = try? DemoControl.post("/lab")
    }

    private func any(_ app: XCUIApplication, _ format: String, _ args: CVarArg...) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: format, argumentArray: args)).firstMatch
    }

    /// Opens the Lab's board, then has Desktop Dev file 3 cards; false when the
    /// daemon refused them (0.18.3 wants a board role the demo's bots lack).
    @discardableResult
    private func openBoard(_ app: XCUIApplication) -> Bool {
        waitFor(app.navigationBars["Hermes Lab"], 20)
        sleep(3) // board_get creates the Lab board
        return (try? DemoControl.post("/items"))?["ok"] as? Bool ?? false
    }

    func testTheBoardIsLiveAndAMoveSaysWhatItNeeds() throws {
        let app = try DemoApp.launch(["-openProject", "Hermes Lab", "-openSegment", "board"])
        allowSystemAlerts()
        guard openBoard(app) else { throw XCTSkip("The demo daemon refused the seed cards (item_create needs a board role)") }
        // Filed after the board opened: they arrive by push, with no pull to refresh.
        let card = any(app, "label CONTAINS %@", "Board chips on iPad")
        waitFor(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Inbox'")).firstMatch, 20).tap()
        waitFor(card, 20)
        screenshot("K7-board-live")

        // The seed cards' label groups as chips, one row per group (K8): platform filters the column.
        let other = any(app, "label CONTAINS %@", "Owner threads read marks")
        let ios = app.buttons["board-label-platform:ios"]
        if ios.waitForExistence(timeout: 5) {
            XCTAssertTrue(app.buttons["board-label-area:board"].exists, "a row for the area group too")
            XCTAssertTrue(any(app, "label CONTAINS %@", "ios · board").exists, "the card shows its labels")
            XCTAssertTrue(other.exists)
            ios.tap()
            let hidden = NSPredicate(format: "exists == false")
            expectation(for: hidden, evaluatedWith: other)
            waitForExpectations(timeout: 10)
            XCTAssertTrue(card.exists, "an ios card stays")
            // Each test files the seed again, so the totals vary: "Inbox 2 of 3", "Inbox 6 of 9".
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label MATCHES 'Inbox [0-9]+ of [0-9]+.*'")).firstMatch.exists,
                          "the chip counts what the filter shows")
            screenshot("K7-label-filter")
            waitFor(app.buttons["board-labels-clear"]).tap()
            waitFor(other, 10)
        } else {
            XCTFail("no label chips for the seed cards' labels")
        }

        // The card's menu (a sideways swipe pages to the next column).
        card.press(forDuration: 1.2)
        waitFor(app.buttons["Move to…"]).tap()
        waitFor(app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH 'Move '")).firstMatch, 10)
        let verdict = any(app, "label CONTAINS '✓ Can move' OR label CONTAINS '⛔' OR label CONTAINS '✎ '")
        waitFor(verdict, 15)
        XCTAssertFalse(app.navigationBars.buttons["Move"].isEnabled, "nothing chosen yet")
        screenshot("K7-move-sheet")

        // A column that wants a reason keeps Move off until one is given.
        let reasoned = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Needs a reason'")).firstMatch
        if reasoned.exists {
            reasoned.tap()
            XCTAssertFalse(app.navigationBars.buttons["Move"].isEnabled, "no reason yet")
        }
        // An allowed column: Move, the sheet goes, and the card leaves the column by push.
        let allowed = app.buttons.matching(NSPredicate(format: "label CONTAINS '✓ Can move'")).firstMatch
        guard allowed.exists else {
            app.navigationBars.buttons["Cancel"].tap()
            return
        }
        allowed.tap()
        XCTAssertTrue(app.navigationBars.buttons["Move"].isEnabled)
        app.navigationBars.buttons["Move"].tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH 'Move '")).firstMatch)
        waitForExpectations(timeout: 15)
        sleep(2)
        screenshot("K7-moved")
    }

    /// A 585 KiB PNG: two upload chunks.
    private static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/hero.png").path

    func testPlusSavesADraftWithAnImageAndOpensIt() throws {
        let app = try DemoApp.launch(["-openProject", "Hermes Lab", "-openSegment", "board", "-attachFixture", Self.fixture])
        allowSystemAlerts()
        openBoard(app)
        let plus = app.buttons["board-new-item"]
        guard plus.waitForExistence(timeout: 15) else { throw XCTSkip("The demo daemon predates 0.19 (no boards, no drafts)") }
        plus.tap()
        let title = waitFor(app.descendants(matching: .any)["quick-add-title"])
        title.tap()
        let words = "K7 draft \(Int(Date().timeIntervalSince1970))"
        title.typeText(words)
        // A label from the board's groups, when its cards use any (the seed cards do once filed).
        let label = app.buttons["quick-add-label-platform:ios"]
        let labelled = label.exists
        if labelled { label.tap() }

        // A photo from the library, when the simulator has one.
        let photo: Bool
        // The photo picker runs out of process: -attachFixture put a screenshot in the form.
        photo = any(app, "label BEGINSWITH 'hero.png'").waitForExistence(timeout: 5)
        XCTAssertTrue(photo, "the fixture image is in the form")
        screenshot("K7-quick-add")
        waitFor(app.buttons["quick-add-save"]).tap()

        waitFor(app.descendants(matching: .any)["draft-banner"], 30)
        XCTAssertTrue(any(app, "label CONTAINS %@", words).exists, "the draft's title")
        if labelled {
            XCTAssertTrue(any(app, "label CONTAINS %@", "platform:ios").exists, "the label picked, on the draft")
        }
        if photo {
            // Uploaded in chunks, attached, and read back with attachment_read for the thumbnail.
            let thumbnail = waitFor(any(app, "label BEGINSWITH 'Image hero.png'"), 20)
            app.scroll(to: thumbnail)
            sleep(3)
            screenshot("K7-draft-attachment")
            XCTAssertFalse(any(app, "label == 'Unavailable'").exists, "the thumbnail loaded")
        }
        XCTAssertTrue(app.descendants(matching: .any)["draft-discuss"].exists, "Discuss with a bot")
        screenshot("K7-draft")

        // Finalize: on the board, or the daemon's refusal said in place.
        let finalize = app.descendants(matching: .any)["draft-finalize"]
        app.scroll(to: finalize)
        finalize.tap()
        let refused = any(app, "label CONTAINS 'paired device' OR label CONTAINS 'not met' OR label CONTAINS 'changed meanwhile'")
        let live = NSPredicate(format: "exists == false")
        let outcome = XCTWaiter().wait(for: [expectation(for: live, evaluatedWith: app.descendants(matching: .any)["draft-banner"])], timeout: 10)
        XCTAssertTrue(outcome == .completed || refused.exists, "neither finalized nor refused")
        screenshot("K7-finalize")
    }

    func testALeadsBoardProposalShowsItsChange() throws {
        // The board exists once the Lab's board has been read.
        let warm = try DemoApp.launch(["-openProject", "Hermes Lab", "-openSegment", "board"])
        allowSystemAlerts()
        openBoard(warm)
        guard let reply = try? DemoControl.post("/proposal"), let id = reply["decision_id"] as? String,
              let board = reply["board"] as? String else {
            throw XCTSkip("The demo daemon predates 0.19 (no board proposals)")
        }
        warm.terminate()
        let app = try DemoApp.launch(["-route", "decision/\(id)", "-ownerAuthStub", "pass"])
        waitFor(any(app, "label CONTAINS %@", "Board change"), 20)
        XCTAssertTrue(any(app, "label CONTAINS %@", "Create board “\(board)”").exists, "the change, in words")
        screenshot("K7-proposal")
        let approve = app.buttons["proposal-approve"]
        if approve.exists {
            approve.tap()
            let settled = NSPredicate(format: "exists == false")
            expectation(for: settled, evaluatedWith: approve)
            waitForExpectations(timeout: 15)
            screenshot("K7-proposal-approved")
        } else {
            XCTAssertTrue(any(app, "label CONTAINS 'can’t approve board changes'").exists, "says why there is no Approve")
        }
    }
}
