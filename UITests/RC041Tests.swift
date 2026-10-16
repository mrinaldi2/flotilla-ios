import XCTest

/// iOS 0.4.1: approvals said from the tool, never the engine's detail (H-026); the
/// chat starting below its floating search button (H-025).
final class RC041Tests: XCTestCase {
    /// What the engine says in its terminal; the app must never show it.
    static let detail = "Claude needs your permission to use Bash"

    override func setUp() { continueAfterFailure = true }

    /// The demo's daemon sends `approval_pending` without `tool`, as every daemon so far
    /// does: the bot "needs approval", everywhere, and the detail shows nowhere.
    func testApprovalNeedsApprovalWithoutToolNeverDetail() throws {
        let app = try DemoApp.launch()
        allowSystemAlerts()
        waitFor(app.tabBars.buttons["Projects"])
        try DemoControl.approval(bot: "Architect")

        // Needs you (the Projects filter): a row for the waiting bot, never the engine's words.
        app.needsYou()
        let needs = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Architect'")).firstMatch
        sleep(2)
        app.scroll(to: needs)
        screenshot("QA-004-approval-needs-you")
        // On an older daemon too (QA-004 finding, fixed at 78b32bb as a bot_waiting row).
        XCTAssertTrue(needs.waitForExistence(timeout: 5), "No Needs you row for Architect's approval")
        assertNoDetail(app, "Needs you")

        // The project's Team: the line under the bot's name.
        app.openProject("Aurora Notes")
        app.pane("Team").tap()
        let row = waitFor(app.botRow("Architect"))
        XCTAssertTrue(row.label.contains("Needs approval"), "Team row: \(row.label)")
        assertNoDetail(app, "Team")
        screenshot("QA-004-approval-team")

        // The bot's approval banner.
        row.tap()
        waitFor(app.pane("Reports"))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Needs approval' OR label CONTAINS 'needs approval'")).firstMatch.waitForExistence(timeout: 5),
                      "No approval banner on the bot")
        assertNoDetail(app, "bot")
        screenshot("QA-004-approval-banner")
    }

    /// The notification, with the app in the background: "<bot> needs approval", no body.
    func testApprovalNotificationNeedsApproval() throws {
        let app = try DemoApp.launch()
        allowSystemAlerts()
        waitFor(app.tabBars.buttons["Projects"])
        XCUIDevice.shared.press(.home)
        sleep(1)
        try DemoControl.approval(bot: "Designer")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Designer needs approval'")).firstMatch
        let shown = banner.waitForExistence(timeout: 15)
        screenshot("QA-004-approval-notification")
        XCTAssertTrue(shown, "No \"Designer needs approval\" notification while the app is in the background")
        if shown {
            XCTAssertFalse(banner.label.contains(Self.detail), "The notification shows the engine's detail: \(banner.label)")
        }
        app.activate()
    }

    private func assertNoDetail(_ app: XCUIApplication, _ screen: String, file: StaticString = #filePath, line: UInt = #line) {
        for word in app.visibleWords where word.contains("Claude needs") || word.contains("permission to use") {
            XCTFail("\(screen) shows the engine's detail: \(word)", file: file, line: line)
        }
    }

    /// The transcript's first row starts below the floating search button.
    func testFirstChatRowBelowSearchButton() throws {
        let app = try DemoApp.launch()
        allowSystemAlerts()
        // Architect: no permission card above its transcript.
        app.openBot("Architect")
        let chat = waitFor(app.pane("Chat"))
        chat.tap()
        let search = waitFor(app.buttons["Search this chat"])
        // To the top of the transcript: drag down on it until nothing moves.
        var last: CGFloat = .nan
        for _ in 0..<25 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
            let top = topRow(app, below: chat)?.frame.minY ?? .nan
            if top == last { break }
            last = top
        }
        sleep(1)
        screenshot("QA-004-chat-top")
        let first = try XCTUnwrap(topRow(app, below: chat), "No transcript row")
        XCTAssertGreaterThanOrEqual(first.frame.minY, search.frame.maxY,
                                    "The first row \"\(first.label)\" (\(first.frame)) starts under the search button (\(search.frame))")
    }

    /// The highest text of the transcript: below the pane switcher, above the composer.
    private func topRow(_ app: XCUIApplication, below chat: XCUIElement) -> XCUIElement? {
        let floor = chat.frame.maxY
        let ceiling = app.frame.maxY * 0.85
        return app.staticTexts.allElementsBoundByIndex
            .filter { $0.frame.minY > floor - 200 && $0.frame.minY < ceiling && !$0.label.isEmpty && $0.frame.height > 0 }
            .filter { $0.frame.maxY > floor }
            .min { $0.frame.minY < $1.frame.minY }
    }
}

/// H-025's Settings → Notifications row. "Not set up" and "Off" need notifications
/// never asked for, so scripts/ui-tests.sh runs that test alone on a freshly erased
/// simulator; "On" follows the Allow the other tests give.
final class NotificationSettingsTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    static let states = ["On", "Off", "Not set up"]

    /// The row's state: as "Notifications, On", as the value of "Notifications", or as
    /// its own text, depending on how the row was read; nil until it has loaded.
    private func state(_ app: XCUIApplication) -> String? {
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Notifications'"))
        for row in rows.allElementsBoundByIndex {
            if row.label.hasPrefix("Notifications, ") { return String(row.label.dropFirst("Notifications, ".count)) }
            if let value = row.value as? String, Self.states.contains(value) { return value }
        }
        return Self.states.first { app.staticTexts[$0].exists }
    }

    private func waitForState(_ app: XCUIApplication, _ expected: String, timeout: TimeInterval = 10,
                              file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while state(app) != expected, Date() < deadline { usleep(300_000) }
        XCTAssertEqual(state(app), expected, "Settings → Notifications", file: file, line: line)
    }

    private func scrollToRow(_ app: XCUIApplication) {
        waitFor(app.navigationBars["Settings"])
        app.scroll(to: app.staticTexts["Notifications"].firstMatch)
        sleep(1)
    }

    func testNotSetUpThenOff() throws {
        // Settings is a tab (H-134); -noNotificationPrompt YES keeps iOS from being asked.
        let app = try DemoApp.launch(["-noNotificationPrompt", "YES", "-openTab", "settings"])
        scrollToRow(app)
        var found: String?
        for _ in 0..<20 where found == nil { found = state(app); if found == nil { usleep(300_000) } }
        guard found == "Not set up" else {
            throw XCTSkip("Notifications were already decided on this simulator: run through scripts/ui-tests.sh, which erases it first")
        }
        XCTAssertTrue(app.buttons["Turn on notifications"].exists)
        XCTAssertFalse(app.buttons["Change in iOS Settings"].exists)
        screenshot("QA-004-settings-notifications-not-set-up")

        app.buttons["Turn on notifications"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        waitFor(springboard.alerts.buttons["Don’t Allow"], 10).tap()
        waitForState(app, "Off")
        XCTAssertTrue(app.buttons["Change in iOS Settings"].exists)
        XCTAssertFalse(app.buttons["Turn on notifications"].exists)
        screenshot("QA-004-settings-notifications-off")
    }

    func testOn() throws {
        let app = try DemoApp.launch()
        allowSystemAlerts()
        app.tab("Settings")
        scrollToRow(app)
        waitForState(app, "On")
        XCTAssertTrue(app.buttons["Change in iOS Settings"].exists)
        XCTAssertFalse(app.buttons["Turn on notifications"].exists)
        screenshot("QA-004-settings-notifications-on")
    }
}
