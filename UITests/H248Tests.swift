import XCTest

/// H-248: "▲ Waiting for you" on a release, from a stubbed release (Debug -releaseStub), no daemon.
final class H248Tests: XCTestCase {
    private static let release = #"{"release":{"id":"rel-qa","name":"0.17.5","display_version":"0.17.5","status":"approved","version":3,"work_item_id":"H-247","owner_blockers":[{"kind":"run","id":"a-1","title":"Clear the stale build cache","item_id":"H-242","bot":null,"computer":"mac","created_at":"2026-10-08T08:00:00Z"},{"kind":"decision","id":"d-2","title":"Which accent colour?","item_id":"H-241","bot":null,"computer":null,"created_at":"2026-10-08T10:00:00Z"},{"kind":"question","id":"c-9","title":"Ship the notes as they are?","item_id":"H-240","bot":null,"computer":null,"created_at":"2026-10-08T11:00:00Z"},{"kind":"decision","id":"d-3","title":"Hold 0.17.5 for the fix?","item_id":"H-244","bot":null,"computer":null,"created_at":"2026-10-08T12:00:00Z"}]}}"#

    /// From a service before owner_blockers: no field at all.
    private static let olderRelease = #"{"release":{"id":"rel-qa","name":"0.17.5","display_version":"0.17.5","status":"approved","version":3}}"#

    override func setUp() { continueAfterFailure = false }

    private func launch(_ release: String = release) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-gravHost", "127.0.0.1", "-gravPort", "41209", "-lensPort", "41208",
                               "-gravToken", "none", "-noNotificationPrompt", "YES", "-releaseStub", release]
        app.launch()
        return app
    }

    func testTheSectionShowsAndADecisionOpens() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["▲ Waiting for you · 4"].waitForExistence(timeout: 20), "No Waiting for you section")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'asks you to run a command on mac'")).firstMatch.exists,
                      "the Run card's title")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Run it on mac, in the Flotilla app.'")).firstMatch.exists,
                      "the Run card says where to run it")
        XCTAssertTrue(app.buttons["+1 more"].exists, "more than 3: +n more")
        screenshot("H-248-waiting-for-you")
        app.buttons.containing(NSPredicate(format: "label CONTAINS 'Decide: Which accent colour?'")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Decision"].waitForExistence(timeout: 10), "Answer did not open the decision")
    }

    /// QA-014: an older service shows no section, and points to Needs you.
    func testAnOlderServicePointsToNeedsYou() {
        let app = launch(Self.olderRelease)
        let link = app.buttons["Open Needs you to see what waits for you."]
        XCTAssertTrue(link.waitForExistence(timeout: 20), "No pointer to Needs you")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '▲ Waiting for you'")).firstMatch.exists)
        screenshot("H-248-older-service")
        link.tap()
        // The stub opened the release on Projects: the link goes back to its list, filtered.
        XCTAssertTrue(app.navigationBars["0.17.5"].waitForNonExistence(timeout: 5), "The link did not open Needs you")
        XCTAssertTrue(app.tabBars.buttons["Projects"].isSelected)
        XCTAssertTrue(app.needsYouFilterIsOn, "The link did not turn the Needs you filter on")
    }
}
