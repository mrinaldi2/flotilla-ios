import XCTest

/// H-011: a tapped notification opens what it announces. `-route kind/id[/bot]` is the
/// app's Debug hook that acts as a tapped notification; the ids come from the demo
/// (scripts/ui-tests.sh passes them).
final class RoutingTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testDecisionNotificationOpensDecisionDetail() throws {
        let id = try XCTUnwrap(DemoApp.decisionId, "No DEMO_DECISION_ID: run scripts/ui-tests.sh")
        let app = try DemoApp.launch(["-route", "decision/\(id)"])
        allowSystemAlerts()
        waitFor(app.navigationBars["Decision"])
        waitFor(app.staticTexts["Which accent colour for the App Store screenshots?"])
        // On Projects, with the Needs you filter under it (0.20).
        XCTAssertTrue(app.tabBars.buttons["Projects"].isSelected)
        screenshot("QA-004-route-decision")
    }

    func testWaitingNotificationOpensChat() throws {
        let bot = try XCTUnwrap(DemoApp.botId, "No DEMO_BOT_ID: run scripts/ui-tests.sh")
        let app = try DemoApp.launch(["-route", "waiting/\(bot)"])
        allowSystemAlerts()
        waitFor(app.pane("Reports"))
        sleep(1)
        screenshot("QA-004-route-waiting")
        // The Chat pane: its composer, not Reports (the Chat tab is selected too, so its
        // own selection can't tell them apart).
        XCTAssertFalse(app.pane("Reports").isSelected, "The bot opened on Reports, not its chat")
        let composer = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Message iOS Dev' OR placeholderValue == 'Message iOS Dev'")).firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "No chat composer: the bot did not open on its chat")
        XCTAssertTrue(app.tabBars.buttons["Chat"].isSelected)
    }
}
