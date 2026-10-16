import XCTest

/// H-134 (UX-024) on iPhone: Projects home and Needs you (I1), the project screen and
/// the bot page Reports-first (I2), the main chat (I3). Against the demo world, whose
/// daemon may predate 0.17: those checks take the legacy path the app shows it, and the
/// 0.17 paths (projects_overview cards) come from the golden fixture via -homeFixture.
/// The live 0.17 checks are in H134LiveTests.
final class H134Tests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
        if UIDevice.current.userInterfaceIdiom == .pad { throw XCTSkip("iPhone layout; the iPad has H134PadTests") }
    }

    private var fixture: String { (DemoApp.environment["FIXTURES"] ?? "") + "/home/overview.json" }

    private func label(_ element: XCUIElement, contains parts: [String], file: StaticString = #filePath, line: UInt = #line) {
        for part in parts {
            XCTAssertTrue(element.label.contains(part), "\"\(part)\" missing from: \(element.label)", file: file, line: line)
        }
    }

    // MARK: I1 Projects home

    /// The golden overview fixture's cards, as a 0.17 daemon sends them.
    func testProjectsHomeCardsFromFixture() throws {
        try XCTSkipIf(DemoApp.environment["FIXTURES"] == nil, "No FIXTURES: run scripts/ui-tests.sh")
        let app = try DemoApp.launch(["-homeFixture", fixture])
        allowSystemAlerts()
        waitFor(app.navigationBars["Projects"])
        let gravity = waitFor(app.projectCard("gravity"))
        label(gravity, contains: ["Rank 1", "1 Run card · 1 permission request · 1 bot waiting",
                                  "0.17.0 ready for you to test",
                                  "5 tasks running · 6 bots, 2 working, 1 waiting for you",
                                  "“Stand-up: H-130 in review.”", "imac is offline · last seen"])
        let calm = waitFor(app.projectCard("calm"))
        XCTAssertTrue(calm.label.hasPrefix("Nothing needs you, calm"), "calm: \(calm.label)")
        XCTAssertLessThan(gravity.frame.minY, calm.frame.minY, "Ranked #1 is not first")
        // The tab badge is the merged attention count (fixture total: 3).
        XCTAssertEqual(app.tabBars.buttons["Needs you"].value as? String, "3 items")
        screenshot("QA-004-i1-projects-fixture")

        // Pinning (long press → Pin to top) needs project_pin, a 0.17 daemon: H134LiveTests.
    }

    /// A daemon without projects_overview: cards built from its projects, ranked, with
    /// "Update needed for full info".
    func testProjectsHomeOnAnOlderDaemon() throws {
        let app = try DemoApp.launch()
        allowSystemAlerts()
        let aurora = waitFor(app.projectCard("Aurora Notes"))
        let website = waitFor(app.projectCard("Website"))
        if !aurora.label.contains("Update needed for full info") {
            throw XCTSkip("This daemon has projects_overview: H134LiveTests covers it")
        }
        label(aurora, contains: ["Rank 1", "decisions", "permission requests", "Update needed for full info"])
        label(website, contains: ["Rank 2", "Update needed for full info"])
        XCTAssertLessThan(aurora.frame.minY, website.frame.minY)
        screenshot("QA-004-i1-projects-legacy")
    }

    // MARK: I1 Needs you

    func testNeedsYouRowsOpenTheRightScreen() throws {
        try DemoControl.ensurePermissionPrompts()
        let app = try DemoApp.launch()
        allowSystemAlerts()
        app.tab("Needs you")
        // Grouped by project, in rank order.
        // Ranks depend on what else is waiting (the live tests add Flotilla Lab): order only.
        let first = waitFor(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Aurora Notes · #'")).firstMatch)
        let second = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Website · #'")).firstMatch
        app.scroll(to: second)
        waitFor(second)
        app.scroll(to: first)
        XCTAssertLessThan(first.frame.minY, second.frame.minY)
        let decision = waitFor(app.needsRow("Resolve conflicts automatically or always ask?"))
        XCTAssertTrue(decision.label.contains("decision"), decision.label)
        screenshot("QA-004-i1-needs-you")

        // A decision opens its detail.
        decision.tap()
        waitFor(app.navigationBars["Decision"])
        waitFor(app.staticTexts["Resolve conflicts automatically or always ask?"])
        app.tab("Needs you")

        // A permission request opens the bot, its card on top.
        let permission = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Backend Dev' AND label CONTAINS 'Bash'")).firstMatch
        app.scroll(to: permission)
        waitFor(permission).tap()
        sleep(2)
        screenshot("QA-004-i1-needs-permission-tapped")
        waitFor(app.pane("Reports"))
        waitFor(app.staticTexts["Bash: rm -rf build/ && npm ci"])
        waitFor(app.buttons["Allow once"].firstMatch)
        screenshot("QA-004-i1-needs-permission-bot")
        app.tab("Needs you")

        // The full list: Needs you → Decisions.
        app.openDecisions()
        waitFor(app.staticTexts["Permission requests"])
        screenshot("QA-004-i1-decisions")
    }

    // MARK: I2 Project screen and bot page

    func testProjectScreenSegments() throws {
        let app = try DemoApp.launch()
        allowSystemAlerts()
        app.openProject("Aurora Notes")
        for segment in ["Overview", "Board", "Team", "Releases"] {
            XCTAssertTrue(waitFor(app.pane(segment)).exists, segment)
        }
        // The meetings segment reads "Meet." (see the report).
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Meet'")).firstMatch.exists, "Meetings segment")
        XCTAssertTrue(app.pane("Overview").isSelected)
        waitFor(app.staticTexts["From the team"])
        screenshot("QA-004-i2-overview")

        app.pane("Board").tap()
        let board = app.staticTexts.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@",
            "Board needs an update", "Couldn’t load the board", "Couldn't load the board")).firstMatch
        if !board.waitForExistence(timeout: 8) {
            // A 0.17 daemon draws the board: columns as chips.
            XCTAssertTrue(app.buttons.count > 6, "No board, no board message")
        }
        screenshot("QA-004-i2-board")

        app.pane("Releases").tap()
        sleep(2)
        screenshot("QA-004-i2-releases")

        // More: Artifacts, Conversations, Project settings.
        waitFor(app.navigationBars["Aurora Notes"].buttons["More"]).tap()
        for item in ["Artifacts", "Conversations", "Project settings"] {
            XCTAssertTrue(waitFor(app.buttons[item], 5).exists, item)
        }
        screenshot("QA-004-i2-more-menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
    }

    /// A bot opens on Reports (UX-024); Work and Artifacts moved into More.
    func testBotPageOpensOnReports() throws {
        let app = try DemoApp.launch()
        allowSystemAlerts()
        app.openBot("Architect")
        let reports = waitFor(app.pane("Reports"))
        XCTAssertTrue(reports.isSelected, "The bot page did not open on Reports")
        for pane in ["Chat", "Terminal", "More"] { XCTAssertTrue(app.pane(pane).exists, pane) }
        XCTAssertFalse(app.pane("Work").exists, "Work should be inside More")
        let note = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Reports come with version 0.17'")).firstMatch
        if note.waitForExistence(timeout: 5) {
            // Older daemon: the note and the bot's live activity.
            XCTAssertTrue(note.label.contains("Demo Mac"), note.label)
        }
        screenshot("QA-004-i2-bot-reports")
    }

    // MARK: I3 Main chat (iPhone)

    func testMainChat() throws {
        let app = try DemoApp.launch()
        allowSystemAlerts()
        app.tab("Chat")
        waitFor(app.navigationBars["Chat"])
        let footer = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Threads come with version 0.17'")).firstMatch
        if footer.waitForExistence(timeout: 5) {
            // Older daemon: its bots under its name, each opening the bot's chat.
            waitFor(app.staticTexts["Demo Mac"])
            waitFor(app.buttons["Architect"])
        }
        screenshot("QA-004-i3-chat")

        if footer.exists {
            app.buttons["Architect"].tap()
            waitFor(app.pane("Reports"))
            sleep(1)
            screenshot("QA-004-i3-chat-bot-opened")
            // The Chat pane: its composer, and not Reports (the tab bar's Chat is selected too).
            XCTAssertFalse(app.pane("Reports").isSelected, "A bot from Chat opened on Reports, not its chat")
            let composer = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Message Architect' OR placeholderValue == 'Message Architect'")).firstMatch
            XCTAssertTrue(composer.waitForExistence(timeout: 5), "No chat composer: the bot did not open on its chat")
            app.tab("Chat")
        }

        // ✎ New message: every bot, grouped by project, with search.
        waitFor(app.buttons["New message"]).tap()
        waitFor(app.navigationBars["Message a bot"])
        let backend = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Backend Dev'"))
        let before = backend.count
        let search = app.searchFields.firstMatch
        waitFor(search).tap()
        search.typeText("Arch")
        sleep(1)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Architect'")).count > 0, "Search lost Architect")
        XCTAssertLessThan(backend.count, before, "Search did not filter Backend Dev out of Message a bot")
        screenshot("QA-004-i3-message-a-bot")
    }
}

/// H-134 I3 on iPad: the sidebar of ranked projects and the main chat sliding over.
/// Run on an iPad simulator: `SIMULATOR=<iPad> scripts/ui-tests.sh -only-testing:UITests/H134PadTests`.
final class H134PadTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
        if UIDevice.current.userInterfaceIdiom != .pad { throw XCTSkip("iPad only") }
        XCUIDevice.shared.orientation = .portrait
    }

    private func sidebarItem(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
    }

    func testSidebarAndProjectDetail() throws {
        let app = try DemoApp.launch()
        allowSystemAlerts()
        waitFor(app.navigationBars["Flotilla"], 20)
        for item in ["Needs you", "Chat", "All projects", "Settings"] {
            XCTAssertTrue(waitFor(sidebarItem(app, item), 5).exists, item)
        }
        // Ranked projects, each with its rank and attention count.
        let aurora = waitFor(sidebarItem(app, "Aurora Notes"))
        let website = waitFor(sidebarItem(app, "Website"))
        XCTAssertLessThan(aurora.frame.minY, website.frame.minY, "Sidebar projects not in rank order")
        screenshot("QA-004-i3-ipad-sidebar")

        aurora.tap()
        for segment in ["Overview", "Board", "Team", "Releases"] {
            XCTAssertTrue(waitFor(app.buttons[segment].firstMatch, 10).exists, segment)
        }
        screenshot("QA-004-i3-ipad-project")
    }

    func testMainChatSlidesOver() throws {
        let app = try DemoApp.launch()
        allowSystemAlerts()
        waitFor(app.navigationBars["Flotilla"], 20)
        sidebarItem(app, "Aurora Notes").tap()
        waitFor(app.buttons["Overview"].firstMatch, 10)
        waitFor(app.buttons["Main chat"]).tap()
        // The chat beside the project, not instead of it.
        waitFor(app.buttons["New message"], 10)
        XCTAssertTrue(app.buttons["Overview"].firstMatch.exists, "The project went away under the chat")
        screenshot("QA-004-i3-ipad-chat-panel")
    }

    func testChatPanelLaunchArgument() throws {
        let app = try DemoApp.launch(["-openProject", "Aurora", "-openChatPanel", "YES"])
        allowSystemAlerts()
        waitFor(app.buttons["New message"], 20)
        screenshot("QA-004-i3-ipad-chat-panel-arg")
    }
}
