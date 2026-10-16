import XCTest

/// The main flows against the demo world: launch, what needs you, a bot's chat,
/// answering a decision, and the link sheet. Each test starts the app fresh.
/// Navigation follows 0.20: Projects (Needs you is its filter) · Chat · Settings.
final class SmokeTests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = try DemoApp.launch()
        allowSystemAlerts()
    }

    func testLaunchShowsProjects() {
        waitFor(app.navigationBars["Projects"])
        for tab in ["Projects", "Chat", "Settings"] {
            XCTAssertTrue(app.tabBars.buttons[tab].exists, "Tab \(tab)")
        }
        XCTAssertEqual(app.tabBars.buttons.count, 3, "Only the three 0.20 tabs: Needs you is a filter on Projects")
        waitFor(app.projectCard("Aurora Notes"))
    }

    func testNeedsYouShowsWhatNeedsYou() throws {
        try DemoControl.ensurePermissionPrompts()
        app.needsYou()
        // The demo's three permission prompts, as rows here and as cards in Decisions.
        // Titled by the app ("… wants to run Bash") or, on 0.17, by the daemon ("… asks: Bash: …").
        for (bot, tool) in [("Backend Dev", "Bash"), ("iOS Dev", "Write"), ("Web Dev", "WebFetch")] {
            let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", bot, tool)).firstMatch
            app.scroll(to: row)
            waitFor(row)
        }
        screenshot("QA-004-smoke-needs-you")
        app.openDecisions()
        // Each bot's card, scrolled to (a terminal card on top can push the third below the fold).
        for command in ["Bash: rm -rf build/ && npm ci", "Write: Sources/Sync/ConflictBanner.swift", "WebFetch: https://example.com/pricing"] {
            let card = app.staticTexts[command]
            app.scroll(to: card)
            waitFor(card)
        }
        XCTAssertGreaterThanOrEqual(app.buttons.matching(identifier: "Allow once").count, 1)
        screenshot("QA-004-smoke-decisions")
    }

    func testBotChat() {
        app.openBot("iOS Dev")
        waitFor(app.pane("Chat")).tap()
        // The bot's own transcript. Lines are LinkedText (a TextView with its words as value),
        // and the list is lazy: chat opens on its newest turn, so the first line needs scrolling to.
        let first = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@",
                                                                         "Starting on the conflict banner", "Starting on the conflict banner")).firstMatch
        app.scroll(to: first, max: 25)
        waitFor(first)
        // The composer, not a transcript TextView.
        let field = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Message iOS Dev' OR placeholderValue == 'Message iOS Dev'")).firstMatch
        waitFor(field).tap()
        let text = "UI smoke \(Int(Date().timeIntervalSince1970))"
        field.typeText(text)
        app.buttons["Send"].tap()
        // Sent from up the transcript: the new line is at the bottom, beyond the lazy fold.
        let sent = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
        app.scroll(to: sent, max: 25)
        waitFor(sent)
        screenshot("QA-004-smoke-chat")
    }

    func testAnswerDecision() throws {
        app.needsYou()
        waitFor(app.needsRow("Launch the site with the offline headline?")).tap()
        waitFor(app.navigationBars["Decision"])
        // hermesd 0.17.4 keeps approve from the demo's owner token: no answer form (H-234).
        if app.staticTexts["This device can’t approve decisions."].waitForExistence(timeout: 3) {
            screenshot("QA-012-decision-cannot-approve")
            throw XCTSkip("The demo's token can't approve decisions on this daemon; H-234")
        }
        app.buttons.containing(NSPredicate(format: "label CONTAINS 'Yes, go live Monday'")).firstMatch.tap()
        let publish = app.buttons["Publish ruling"]
        app.scroll(to: publish)
        XCTAssertTrue(publish.isEnabled)
        publish.tap()
        // Settled: the answer form gives way to the ruling.
        XCTAssertTrue(publish.waitForNonExistence(timeout: 10), "Still open after Publish ruling")
        screenshot("QA-004-smoke-decision-answered")
    }

    func testLinkSheetUnlink() throws {
        // hermesd 0.17.4 keeps peer invites from the demo's owner token: no link to show (H-234).
        if (DemoApp.environment["DEMO_SKIPPED"] ?? "").contains("peer-link") {
            throw XCTSkip("The demo has no peer link on this daemon (create_peer_invite needs approve); H-234")
        }
        app.openProject("Aurora Notes")
        waitFor(app.navigationBars["Aurora Notes"].buttons["More"]).tap()
        waitFor(app.buttons["Project settings"]).tap()
        let change = app.buttons["Change linked computers"]
        app.scroll(to: change)
        waitFor(change).tap()
        waitFor(app.staticTexts["on Studio PC"])
        app.buttons["Unlink"].firstMatch.tap()
        // H-003: a confirmation first, and nothing unlinked yet.
        waitFor(app.staticTexts["Unlink Aurora Notes?"])
        XCTAssertTrue(app.staticTexts["on Studio PC"].exists)
        screenshot("QA-004-unlink-confirm")
        waitFor(app.buttons["Unlink project"]).tap()
        XCTAssertTrue(app.staticTexts["on Studio PC"].waitForNonExistence(timeout: 10), "Still linked after confirming Unlink")
        screenshot("QA-004-unlink-done")
    }
}
