import XCTest

/// QA-007 against the scratch daemon on a copy of this Mac's board:
/// H-207 per-link card ids (UX-039) and H-160 AC2, AC3, AC9 on iPhone; H-207 hover and
/// H-160 AC6 (⌘1–5, ⌘⇧N, hover highlight) on iPad. Skips without SCRATCH_PORT/SCRATCH_TOKEN.
private func scratchLaunch(_ extra: [String]) -> XCUIApplication {
    let env = DemoApp.environment
    XCUIDevice.shared.appearance = .light
    let app = XCUIApplication()
    app.launchArguments = ["-gravHost", "127.0.0.1", "-gravPort", env["SCRATCH_PORT"]!,
                           "-gravToken", env["SCRATCH_TOKEN"]!, "-noNotificationPrompt", "YES"] + extra
    app.launch()
    return app
}

private func requireScratch() throws {
    let env = DemoApp.environment
    if (env["SCRATCH_PORT"] ?? "").isEmpty || (env["SCRATCH_TOKEN"] ?? "").isEmpty {
        throw XCTSkip("No scratch daemon (SCRATCH_PORT/SCRATCH_TOKEN)")
    }
}

/// "H-189: <title>" / "H-189, card" / "H-189".
private func cardLink(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.links.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@ OR label == %@", id, "\(id):", "\(id), card")).firstMatch
}

/// Re-tap a segment until `target` shows (the project shows from cache before it connects).
private func show(_ app: XCUIApplication, _ segment: String, until target: XCUIElement, timeout: TimeInterval = 45) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        app.pane(segment).tap()
        if target.waitForExistence(timeout: 4) { return true }
            // Lists are lazy: a row below the fold exists only once scrolled to.
            for _ in 0..<6 where !target.exists { app.swipeUp() }
            if target.exists { return true }
        app.pane(segment == "Overview" ? "Team" : "Overview").tap()
        sleep(1)
    } while Date() < deadline
    return target.exists
}

final class QA007Tests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
        if UIDevice.current.userInterfaceIdiom == .pad { throw XCTSkip("iPhone layout") }
        try requireScratch()
    }

    /// H-155's comments in the copy hold "see H-189 and `H-190`" (QA-006b): open the card there.
    private func commentWithTwoIds(_ app: XCUIApplication) -> XCUIElement {
        waitFor(app.navigationBars["The Hermes"], 30)
        let inbox = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Inbox'")).firstMatch
        XCTAssertTrue(show(app, "Board", until: inbox), "Board did not load")
        inbox.tap()
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'H-155'")).firstMatch
        app.scroll(to: card)
        waitFor(card, 15).tap()
        waitFor(app.navigationBars["H-155"], 15)
        let comment = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'see H-189 and' OR value CONTAINS 'see H-189 and'")).firstMatch
        app.scroll(to: comment)
        waitFor(comment, 15)
        return comment
    }

    /// H-207 AC0: a long-press on one id in running text previews that card only, with Open/Copy.
    func testH207LongPressOneIdPreviewsOnlyThatCard() {
        let app = scratchLaunch(["-openProject", "The Hermes", "-openSegment", "board"])
        _ = commentWithTwoIds(app)
        let h190 = cardLink(app, "H-190")
        XCTAssertTrue(waitFor(h190).exists)
        h190.press(forDuration: 1.5)
        sleep(2)
        screenshot("QA-007-h207-long-press-H-190")
        let words = app.visibleWords.joined(separator: " | ")
        XCTAssertTrue(words.contains("Open card"), "No Open card: \(words.prefix(300))")
        XCTAssertTrue(words.contains("Copy H-190"), "No Copy H-190: \(words.prefix(300))")
        XCTAssertTrue(words.contains("H-190 · "), "The preview does not name H-190")
        XCTAssertFalse(words.contains("Copy H-189") || words.contains("H-189 · "), "The menu lists H-189 too: \(words.prefix(400))")
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Open card'")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["H-190"].waitForExistence(timeout: 15), "Open card did not open H-190")
    }

    /// H-207: a tap on one id opens that card (and Back returns).
    func testH207TapOneIdOpensIt() {
        let app = scratchLaunch(["-openProject", "The Hermes", "-openSegment", "board"])
        _ = commentWithTwoIds(app)
        let h189 = cardLink(app, "H-189")
        waitFor(h189).tap()
        XCTAssertTrue(app.navigationBars["H-189"].waitForExistence(timeout: 15), "Tap on H-189 did not open it")
        screenshot("QA-007-h207-tap-opened")
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(app.navigationBars["H-155"].waitForExistence(timeout: 5), "Back did not return to H-155")
    }

    /// H-160 AC2: a Team row with something new reads "N new"; VoiceOver "New message from <bot>".
    func testH160AC2UnreadWords() {
        let app = scratchLaunch(["-openProject", "The Hermes", "-openSegment", "team"])
        waitFor(app.navigationBars["The Hermes"], 30)
        let spoken = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'New message from '")).firstMatch
        let found = show(app, "Team", until: spoken)
        let visible = app.staticTexts.matching(NSPredicate(format: "label MATCHES '[0-9]+ new' OR label == 'New'")).firstMatch
        if found { app.scroll(to: spoken) }
        screenshot("QA-007-h160-ac2-team-unread")
        XCTAssertTrue(found, "No 'New message from <bot>' on any Team row")
        XCTAssertTrue(visible.exists || spoken.label.contains("new"), "No visible 'N new' words")
        print("QA-007 AC2: spoken=\(spoken.label) visible=\(visible.exists ? visible.label : "-")")
    }

    /// H-160 AC3: a project whose board is kept on another computer says where.
    func testH160AC3BoardElsewhere() {
        var seen: [String] = []
        for project in ["Books", "Peer Test"] {
            let app = scratchLaunch(["-openProject", project, "-openSegment", "board"])
            waitFor(app.navigationBars[project], 30)
            let words = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH \"This project's board is kept on\"")).firstMatch
            let ok = show(app, "Board", until: words, timeout: 30)
            screenshot("QA-007-h160-ac3-\(project.replacingOccurrences(of: " ", with: "-"))-board")
            seen.append("\(project): \(ok ? words.label : app.visibleWords.prefix(12).joined(separator: " | "))")
            app.terminate()
            if ok { return }
        }
        XCTFail("No board-elsewhere words: \(seen)")
    }
}

final class QA007PadTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
        if UIDevice.current.userInterfaceIdiom != .pad { throw XCTSkip("iPad only") }
        XCUIDevice.shared.orientation = .landscapeLeft
        try requireScratch()
    }

    /// H-160 AC6: ⌘1–5 pick the segments, ⌘⇧N opens Needs you.
    func testH160AC6KeyboardShortcuts() {
        let app = scratchLaunch(["-openProject", "The Hermes", "-openSegment", "overview"])
        let overview = app.pane("Overview")
        waitFor(overview, 30)
        for (key, name) in [("2", "Board"), ("3", "Team"), ("4", "Releases"), ("5", "Meetings"), ("1", "Overview")] {
            app.typeKey(key, modifierFlags: .command)
            let selected = app.buttons.matching(NSPredicate(format: "label == %@ AND selected == true", name)).firstMatch
            XCTAssertTrue(selected.waitForExistence(timeout: 5), "⌘\(key) did not pick \(name)")
            screenshot("QA-007-h160-ac6-cmd-\(key)-\(name)")
        }
        app.typeKey("n", modifierFlags: [.command, .shift])
        // Projects, with the Needs you filter on (0.20).
        XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 5) && app.needsYouFilterIsOn, "⌘⇧N did not open Needs you")
        screenshot("QA-007-h160-ac6-cmd-shift-n")
    }

    /// H-160 AC6 hover highlight on rows/cards, and H-207 AC1: the pointer resting on an id previews it.
    func testHoverHighlightAndLinkPreview() {
        let app = scratchLaunch(["-openProject", "The Hermes", "-openSegment", "releases"])
        waitFor(app.pane("Releases"), 30)
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '0.17.4,'")).firstMatch
        XCTAssertTrue(show(app, "Releases", until: row), "Releases did not load")
        row.hover()
        sleep(1)
        screenshot("QA-007-h160-ac6-hover-release-row")
        row.tap()
        let link = cardLink(app, "H-182")
        XCTAssertTrue(link.waitForExistence(timeout: 15), "Changelog H-182 is not a link")
        link.hover()
        usleep(1_200_000)
        screenshot("QA-007-h207-hover-preview")
        let words = app.visibleWords.joined(separator: " | ")
        XCTAssertTrue(words.contains("H-182 · "), "Resting the pointer on H-182 shows no preview: \(words.prefix(400))")
        XCTAssertFalse(words.contains("H-184 · "), "Hover preview shows another card")
    }
}
