import XCTest

/// H-134 against a 0.17 daemon (the demo world on desktop 0.17.0's hermesd): the live
/// overview, pinning, cache-first, Run cards, decision grants (H-118), the terminal
/// command card (H-108), the binary board and owner threads. Each test seeds what it
/// needs through the demo's control endpoint, in its own "Flotilla Lab" project, and
/// skips on an older daemon.
final class H134LiveTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
        if UIDevice.current.userInterfaceIdiom == .pad { throw XCTSkip("iPhone layout; the iPad has H134LivePadTests") }
        try requireLiveDaemon()
    }

    // MARK: I1 live overview, pinning, cache-first

    func testLiveCardsAndPinning() throws {
        let app = try DemoApp.launch()
        allowSystemAlerts()
        let aurora = waitFor(app.projectCard("Aurora Notes"), 20)
        XCTAssertFalse(aurora.label.contains("Update needed"), "A 0.17 daemon still gets the older-daemon card: \(aurora.label)")
        XCTAssertTrue(aurora.label.contains("bots"), aurora.label)
        screenshot("QA-005-live-projects")

        // Long press → Pin to top (project_pin), then back.
        aurora.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.5)
        waitFor(app.buttons["Pin to top"], 5).tap()
        XCTAssertTrue(waitForPins(contains: "Aurora Notes"), "The daemon did not record the pin")
        let pinned = app.projectCard("Aurora Notes")
        XCTAssertTrue(pinned.waitForExistence(timeout: 10) && pinned.label.contains("Pinned"), "No pin on the card: \(pinned.label)")
        screenshot("QA-005-live-pinned")
        pinned.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.5)
        waitFor(app.buttons["Unpin"], 5).tap()
        XCTAssertTrue(waitForPins(contains: nil), "The pin did not come off")
    }

    /// The last overview shows before the network: relaunched against a closed port, the
    /// cards are still there.
    func testLiveCacheFirst() throws {
        var app = try DemoApp.launch()
        allowSystemAlerts()
        waitFor(app.projectCard("Aurora Notes"), 20)
        sleep(2)
        app.terminate()
        app = try DemoApp.launch(port: "41309") // in my range, nothing listens there
        let cached = app.projectCard("Aurora Notes")
        XCTAssertTrue(cached.waitForExistence(timeout: 8), "No cached overview while the computer is unreachable")
        XCTAssertFalse(cached.label.contains("Update needed"), "The cached card is the older-daemon one: \(cached.label)")
        screenshot("QA-005-live-cache-first")
    }

    // MARK: Needs you: Run card

    func testLiveRunCard() throws {
        try seed("/runcard")
        let app = try DemoApp.launch()
        allowSystemAlerts()
        app.needsYou()
        let row = waitFor(app.needsRow("Run: Clear the stale build cache"), 20)
        screenshot("QA-005-live-run-card-row")
        row.tap()
        // Running it from the phone comes later in the 0.5.0 lane: the row says where.
        let note = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Run cards come to the phone'")).firstMatch  // "… in a later update" since e9d7eef
        waitFor(note, 10)
        screenshot("QA-005-live-run-card-note")
    }

    // MARK: I2b: decision grants (H-118)

    func testLiveDecisionGrants() throws {
        try seed("/grants")
        // A granting ruling asks for Face ID first (9a356e0); the simulator has none.
        let app = try DemoApp.launch(["-ownerAuthStub", "pass"])
        allowSystemAlerts()
        app.needsYou()
        waitFor(app.needsRow("Let DevOps install 0.17.1"), 20).tap()
        waitFor(app.navigationBars["Decision"])
        let grants = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Grants '")).firstMatch
        waitFor(grants, 10)
        for part in ["DevOps: install", "Desktop Dev: publish"] {
            XCTAssertTrue(grants.label.contains(part), "\"\(part)\" missing from: \(grants.label)")
        }
        screenshot("QA-005-live-grants")
        // Publishing the granting option echoes grants_sha; a mismatch would be refused.
        app.buttons.containing(NSPredicate(format: "label CONTAINS 'Grant both'")).firstMatch.tap()
        let publish = app.buttons["Publish ruling"]
        app.scroll(to: publish)
        publish.tap()
        XCTAssertTrue(publish.waitForNonExistence(timeout: 10), "Publishing a granting option did not settle it")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'conflict' OR label CONTAINS[c] 'changed'")).firstMatch.exists,
                       "A grants conflict on a fresh decision")
        screenshot("QA-005-live-grants-published")

        // The ruling reaches Team Lead's thread as words, not the bus envelope (c656476).
        app.tab("Chat")
        let lead = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Team Lead'")).firstMatch
        waitFor(lead, 15)
        sleep(2)
        XCTAssertFalse(lead.label.contains("[decision"), "Bus envelope in the preview: \(lead.label)")
        XCTAssertNil(lead.label.range(of: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}", options: .regularExpression),
                     "A UUID in the preview: \(lead.label)")
        screenshot("QA-005-live-ruling-preview")
    }

    /// Face ID refused: nothing is published, and the owner is told why.
    func testLiveDecisionGrantsRefusedWithoutFaceID() throws {
        try seed("/grants")
        let app = try DemoApp.launch(["-ownerAuthStub", "fail"])
        allowSystemAlerts()
        app.needsYou()
        waitFor(app.needsRow("Let DevOps install 0.17.1"), 20).tap()
        waitFor(app.navigationBars["Decision"])
        app.buttons.containing(NSPredicate(format: "label CONTAINS 'Grant both'")).firstMatch.tap()
        let publish = app.buttons["Publish ruling"]
        app.scroll(to: publish)
        publish.tap()
        waitFor(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Not published. Nothing was sent.'")).firstMatch, 10)
        screenshot("QA-005-live-grants-refused")
        // Still open: the answer form is there after dismissing the message.
        if app.buttons["OK"].exists { app.buttons["OK"].tap() }
        XCTAssertTrue(app.buttons["Publish ruling"].waitForExistence(timeout: 5), "The decision settled without Face ID")
    }

    // MARK: I2b: the terminal command card (H-108)

    func testLiveTerminalCard() throws {
        try seed("/terminal")
        let app = try DemoApp.launch()
        allowSystemAlerts()
        app.needsYou()
        // One element for VoiceOver: "Terminal command wants to act as you: <command>. …"
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'wants to act as you'")).firstMatch
        let shown = card.waitForExistence(timeout: 20)
        sleep(1)
        screenshot("QA-005-live-terminal-card")
        XCTAssertTrue(shown, "No terminal command card on Projects")
        guard shown else { return }
        let text = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'wants to act as you'"))
            .allElementsBoundByIndex.map(\.label).joined(separator: " | ")
        XCTAssertTrue(text.contains("git push --force origin main"), "No command on the card: \(text)")
        let words = app.visibleWords.joined(separator: " | ")
        for part in ["Desktop Dev’s workspace, so a bot is probably asking, not you", "Answer this on Demo Mac, in the Flotilla app"] {
            XCTAssertTrue(words.contains(part) || text.contains(part), "\"\(part)\" missing from the card")
        }
        // Read-only: no answers here, and it sits above the project sections.
        XCTAssertFalse(app.buttons["Allow once"].exists, "The terminal card offers answers on the phone")
        let firstCard = app.buttons.matching(NSPredicate(format: "label CONTAINS ', Needs you'")).firstMatch
        if firstCard.exists {
            XCTAssertLessThan(card.frame.minY, firstCard.frame.minY, "The terminal card is not on top of Projects")
        }
        // Tapping it never opens a bot page for "terminal".
        card.tap()
        sleep(2)
        XCTAssertFalse(app.pane("Reports").exists, "The terminal card opened a bot page")
        screenshot("QA-005-live-terminal-card-tapped")
    }

    /// The home feed loads at the root (c656476): a cold launch straight into Needs you
    /// (Projects, filtered) fills it.
    func testLiveColdLaunchIntoNeedsYou() throws {
        try DemoControl.ensurePermissionPrompts()
        let app = try DemoApp.launch(["-openTab", "needs"])
        allowSystemAlerts()
        XCTAssertTrue(app.tabBars.buttons["Projects"].waitForExistence(timeout: 10) && app.tabBars.buttons["Projects"].isSelected,
                      "Did not open on Projects")
        XCTAssertTrue(app.needsYouFilterIsOn, "Did not open with the Needs you filter on")
        waitFor(app.needsRow("Resolve conflicts automatically or always ask?"), 20)
        screenshot("QA-005-live-cold-needs-you")
    }

    // MARK: I2: the binary board

    func testLiveBoard() throws {
        try seed("/lab")
        let app = try DemoApp.launch(["-openProject", "Flotilla Lab", "-openSegment", "board"])
        allowSystemAlerts()
        waitFor(app.navigationBars["Flotilla Lab"], 20)
        sleep(3) // board_get creates the board for the owner
        let items = try seed("/items")
        XCTAssertEqual(items["ok"] as? Bool, true, "Seeding items: \(items)")
        // Back and forth refreshes the board.
        app.pane("Overview").tap()
        app.pane("Board").tap()
        // The column chips count the cards: new items land in Inbox.
        let inbox = waitFor(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Inbox'")).firstMatch, 20)
        XCTAssertEqual(inbox.label, "Inbox 3", "Inbox chip")
        screenshot("QA-005-live-board-chips")
        inbox.tap()
        sleep(2)
        let item = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Board chips on iPad'")).firstMatch
        let shown = item.waitForExistence(timeout: 10)
        screenshot("QA-005-live-board")
        XCTAssertTrue(shown, "Inbox counts 3 cards but its page shows none")
        guard shown else { return }
        item.tap()
        sleep(2)
        screenshot("QA-005-live-board-item")
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        if field.waitForExistence(timeout: 5) {
            field.tap()
            field.typeText("QA-004 comment from the phone")
            app.buttons["Send"].tap()
            waitFor(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'QA-004 comment from the phone'")).firstMatch, 10)
            screenshot("QA-005-live-board-comment")
        } else {
            XCTFail("No comment field on the item")
        }
    }

    // MARK: I3: owner threads

    func testLiveOwnerThreads() throws {
        try seed("/question")
        let app = try DemoApp.launch()
        allowSystemAlerts()
        app.tab("Chat")
        waitFor(app.navigationBars["Chat"])
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Threads come with'")).firstMatch.exists,
                       "A 0.17 daemon still gets the threads fallback")
        let question = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Desktop Dev'")).firstMatch
        waitFor(question, 20)
        XCTAssertTrue(question.label.contains("Question"), "No Question pill: \(question.label)")
        XCTAssertTrue(question.label.contains("unread"), "No unread count: \(question.label)")
        // Previews are plain text: no Markdown marks, no bus envelope.
        for row in app.buttons.allElementsBoundByIndex where row.label.contains(" · ") || row.label.contains("You: ") {
            XCTAssertFalse(row.label.contains("**"), "Markdown in a preview: \(row.label)")
            XCTAssertFalse(row.label.contains("[decision "), "Bus envelope in a preview: \(row.label)")
        }
        let backend = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Backend Dev'")).firstMatch
        if backend.exists { XCTAssertTrue(backend.label.contains("sync-conflicts.md"), backend.label) }
        let own = app.buttons.matching(NSPredicate(format: "label CONTAINS 'iOS Dev'")).firstMatch
        XCTAssertTrue(own.exists && own.label.contains("You: "), "No \"You: \" on the owner's last message: \(own.label)")
        // Open questions first.
        XCTAssertLessThan(question.frame.minY, own.frame.minY, "The open question is not first")
        screenshot("QA-005-live-threads")

        question.tap()
        waitFor(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Should the release notes mention the new board?'")).firstMatch)
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        waitFor(field).tap()
        field.typeText("Yes, mention it.")
        app.buttons["Send"].tap()
        waitFor(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Yes, mention it.'")).firstMatch, 10)
        screenshot("QA-005-live-thread")

        // Read: back on the list, no unread count.
        app.tab("Chat")
        let after = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Desktop Dev'")).firstMatch
        waitFor(after)
        sleep(2)
        XCTAssertFalse(after.label.contains("unread"), "Still unread after reading: \(after.label)")
    }

    // MARK: I2: the bot page's Reports, live

    func testLiveBotReports() throws {
        try seed("/question")
        let app = try DemoApp.launch(["-openProject", "Flotilla Lab", "-openSegment", "team"])
        allowSystemAlerts()
        waitFor(app.botRow("Desktop Dev"), 20).tap()
        waitFor(app.pane("Reports"))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Reports come with version 0.17'")).firstMatch.exists,
                       "A 0.17 daemon still gets the Reports fallback")
        let question = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Should the release notes mention the new board?'"))
        waitFor(question.firstMatch, 15)
        sleep(1)
        XCTAssertEqual(question.count, 1, "The question shows \(question.count) times on Reports")
        let answer = waitFor(app.buttons["Answer in Chat"].firstMatch)
        screenshot("QA-005-live-reports")
        answer.tap()
        let composer = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Message Desktop Dev' OR placeholderValue == 'Message Desktop Dev'")).firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10) || app.textViews.firstMatch.exists, "Answer in Chat did not open a composer")
    }

    // MARK: helpers

    @discardableResult
    private func seed(_ path: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let reply = try DemoControl.post(path)
        if let ok = reply["ok"] as? Bool, !ok, path != "/items" {
            XCTFail("Seeding \(path): \(reply)", file: file, line: line)
        }
        return reply
    }

    private func waitForPins(contains name: String?) -> Bool {
        for _ in 0..<20 {
            let pinned = ((try? DemoControl.post("/pins"))?["pinned"] as? [String]) ?? []
            if name.map({ pinned.contains($0) }) ?? pinned.isEmpty { return true }
            usleep(500_000)
        }
        return false
    }
}

/// The live iPad: ranked projects in the sidebar, owner threads in the chat panel.
final class H134LivePadTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
        if UIDevice.current.userInterfaceIdiom != .pad { throw XCTSkip("iPad only") }
        XCUIDevice.shared.orientation = .portrait
        try requireLiveDaemon()
    }

    func testLiveSidebarAndThreadsPanel() throws {
        _ = try DemoControl.post("/question")
        _ = try DemoControl.post("/grants")
        let app = try DemoApp.launch()
        allowSystemAlerts()
        waitFor(app.navigationBars["Flotilla"], 20)
        let lab = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Flotilla Lab'")).firstMatch
        waitFor(lab, 20)
        screenshot("QA-005-live-ipad-sidebar")
        lab.tap()
        waitFor(app.buttons["Overview"].firstMatch, 10)
        waitFor(app.buttons["Main chat"]).tap()
        let thread = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Desktop Dev'")).firstMatch
        waitFor(thread, 15)
        XCTAssertTrue(thread.label.contains("Question"), thread.label)
        screenshot("QA-005-live-ipad-threads-panel")
    }
}

/// Skips a test unless the demo daemon offers the 0.17 home (and creates the Lab project).
func requireLiveDaemon() throws {
    let reply = try DemoControl.post("/lab")
    let caps = reply["caps"] as? [String] ?? []
    if !caps.contains("owner_threads") || !caps.contains("projects_overview") {
        throw XCTSkip("The demo daemon predates 0.17 (no owner_threads/projects_overview)")
    }
}
