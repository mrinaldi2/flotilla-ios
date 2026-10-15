import XCTest

/// QA-006 H-202 failure path on the demo world: the demo pauses its daemon (/freeze), so
/// a comment can't reach the board: Not posted with the reason, Retry and Discard, the
/// text kept; Retry once the daemon is back posts it.
final class QA006DemoTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
        if UIDevice.current.userInterfaceIdiom == .pad { throw XCTSkip("iPhone layout") }
        try requireLiveDaemon()
        addTeardownBlock { _ = try? DemoControl.post("/thaw") }
    }

    private func openLabCard(_ app: XCUIApplication, _ title: String) {
        waitFor(app.navigationBars["Flotilla Lab"], 20)
        sleep(3) // board_get creates the Lab board
        _ = try? DemoControl.post("/items")
        app.pane("Overview").tap()
        app.pane("Board").tap()
        waitFor(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Inbox'")).firstMatch, 20).tap()
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        waitFor(card, 20).tap()
        sleep(2)
    }

    /// A comment's words: LinkedText shows them as value, plain text as label.
    private func text(_ app: XCUIApplication, _ words: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", words, words)).firstMatch
    }

    private func send(_ app: XCUIApplication, _ text: String) {
        // The comment box, not the first TextView: card text is LinkedText, a TextView too.
        let field = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Comment' OR placeholderValue BEGINSWITH 'Comment on'")).firstMatch
        app.scroll(to: field)
        waitFor(field).tap()
        field.typeText(text)
        app.buttons["Send"].tap()
    }

    func testCommentNotPostedThenRetryAndDiscard() throws {
        try DemoControl.post("/lab")
        let app = try DemoApp.launch(["-openProject", "Flotilla Lab", "-openSegment", "board"])
        allowSystemAlerts()
        openLabCard(app, "Board chips on iPad")

        // The board can't be reached: Not posted, the reason, Retry and Discard, text kept.
        try DemoControl.post("/freeze")
        let first = "QA-006 retry me \(Int(Date().timeIntervalSince1970))"
        send(app, first)
        waitFor(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Sending'")).firstMatch, 5)
        screenshot("QA-006-h202-demo-sending")
        // "Couldn’t post" since 0.6 ("Not posted" before).
        let notPosted = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Couldn' OR label CONTAINS 'Not posted'")).firstMatch
        waitFor(notPosted, 45)
        XCTAssertTrue(app.buttons["Retry"].exists, "No Retry")
        XCTAssertTrue(app.buttons["Discard"].exists, "No Discard")
        XCTAssertTrue(text(app, first).exists, "The text was not kept")
        screenshot("QA-006-h202-not-posted")

        // Back, and Retry posts it.
        try DemoControl.post("/thaw")
        sleep(3)
        app.buttons["Retry"].firstMatch.tap()
        let posted = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Posted'")).firstMatch
        let reply = app.buttons["Reply"]
        XCTAssertTrue(posted.waitForExistence(timeout: 20) || reply.waitForExistence(timeout: 5), "Retry did not post it")
        XCTAssertFalse(notPosted.exists, "Still Not posted after Retry")
        screenshot("QA-006-h202-retried-posted")

        // Fails again, and Discard drops it.
        try DemoControl.post("/freeze")
        let second = "QA-006 discard me \(Int(Date().timeIntervalSince1970))"
        send(app, second)
        waitFor(notPosted, 45)
        app.buttons["Discard"].firstMatch.tap()
        XCTAssertTrue(text(app, second).waitForNonExistence(timeout: 5),
                      "Discard left the comment")
        screenshot("QA-006-h202-discarded")
        try DemoControl.post("/thaw")
    }
}
