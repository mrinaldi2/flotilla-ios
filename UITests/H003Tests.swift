import XCTest

/// H-003: safe destructive actions and the AA contrast floor (4.5:1), checked on screen
/// in light and dark. Unlink's confirmation is in `SmokeTests.testLinkSheetUnlink`.
/// Labels follow the R1-I1 glossary (Clear conversation, Publish ruling, Put on hold).
final class H003Tests: XCTestCase {
    static let floor = 4.5

    override func setUp() { continueAfterFailure = true }

    func testClearChatIsDestructiveAndConfirms() throws {
        let app = try DemoApp.launch()
        allowSystemAlerts()
        app.openBot("Architect")
        waitFor(app.pane("More")).tap()
        let clear = app.buttons["Clear conversation"]
        app.scroll(to: clear)
        waitFor(clear)
        // The words, not the icon: the eraser keeps the tint.
        XCTAssertTrue(Contrast(of: clear).redShare > 0.01, "Clear conversation is not drawn in the destructive red")
        screenshot("QA-004-clear-chat-row")
        clear.tap()
        waitFor(app.staticTexts["Clear Architect's conversation?"])
        // The dialog's button carries the same words as the row.
        XCTAssertTrue(app.buttons.matching(identifier: "Clear conversation").count >= 2, "No confirming button")
        let confirm = app.buttons.matching(identifier: "Clear conversation").allElementsBoundByIndex.last!
        screenshot("QA-004-clear-chat-confirm")
        XCTAssertTrue(Contrast(of: confirm).redShare > 0.01, "The confirming Clear conversation is not destructive")
        // Dismiss without confirming (away from the popover's button): the demo keeps its history.
        if app.buttons["Cancel"].exists {
            app.buttons["Cancel"].tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
        }
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5), "The confirmation did not close")
    }

    func testPermissionCardContrastLight() throws { try permissionCard(dark: false) }
    func testPermissionCardContrastDark() throws { try permissionCard(dark: true) }
    func testDecisionDetailContrastLight() throws { try decisionDetail(dark: false) }
    func testDecisionDetailContrastDark() throws { try decisionDetail(dark: true) }

    private func permissionCard(dark: Bool) throws {
        try DemoControl.ensurePermissionPrompts()
        let app = try DemoApp.launch(dark: dark)
        allowSystemAlerts()
        app.openDecisions()
        let allow = waitFor(app.buttons["Allow once"].firstMatch)
        sleep(1)
        XCTAssertEqual(DemoApp.isDark(app), dark, "Measured in the wrong appearance")
        screenshot("QA-004-permission-card-\(dark ? "dark" : "light")")
        for label in ["Allow once", "Allow for session", "Deny"] {
            check(app.buttons[label].firstMatch, label, dark)
        }
        _ = allow
    }

    private func decisionDetail(dark: Bool) throws {
        let app = try DemoApp.launch(dark: dark)
        allowSystemAlerts()
        app.needsYou()
        waitFor(app.needsRow("Resolve conflicts automatically or always ask?")).tap()
        waitFor(app.navigationBars["Decision"])
        sleep(1)
        XCTAssertEqual(DemoApp.isDark(app), dark, "Measured in the wrong appearance")
        screenshot("QA-004-decision-detail-\(dark ? "dark" : "light")")
        check(waitFor(app.staticTexts["Urgent"]), "Urgent pill", dark)
        let recommended = app.staticTexts["Recommended"]
        app.scroll(to: recommended)
        check(recommended, "Recommended pill", dark)
        app.buttons.containing(NSPredicate(format: "label CONTAINS 'Always ask'")).firstMatch.tap()
        let publish = app.buttons["Put on hold"]
        app.scroll(to: publish)
        sleep(1)
        screenshot("QA-004-decision-answer-\(dark ? "dark" : "light")")
        for label in ["Publish ruling", "Save as draft", "Put on hold"] {
            check(app.buttons[label], label, dark)
        }
    }

    private func check(_ element: XCUIElement, _ name: String, _ dark: Bool) {
        guard element.waitForExistence(timeout: 5) else { return XCTFail("\(name) not found") }
        XCUIApplication().scroll(to: element)
        XCTAssertTrue(element.isHittable, "\(name) is not on screen")
        let contrast = Contrast(of: element)
        let line = String(format: "%@ %@: %@ on %@ = %.2f:1", dark ? "dark" : "light", name,
                          contrast.text.description, contrast.background.description, contrast.ratio)
        print("CONTRAST \(line)")
        let attachment = XCTAttachment(string: line)
        attachment.name = "contrast \(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThanOrEqual(contrast.ratio, Self.floor, line)
    }
}
