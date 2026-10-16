import XCTest

/// QA-006: H-200 (release item states) and H-202 (comment feedback) against a scratch
/// daemon (`hermesd --scratch`) on a copy of this Mac's board: real releases, and
/// comments that stay in the copy. Skips unless the runner passes SCRATCH_PORT and
/// SCRATCH_TOKEN (and SCRATCH_READONLY_TOKEN for the refused path).
final class QA006ScratchTests: XCTestCase {
    private var env: [String: String] { DemoApp.environment }

    override func setUpWithError() throws {
        continueAfterFailure = true
        if UIDevice.current.userInterfaceIdiom == .pad { throw XCTSkip("iPhone layout") }
        if (env["SCRATCH_PORT"] ?? "").isEmpty || (env["SCRATCH_TOKEN"] ?? "").isEmpty {
            throw XCTSkip("No scratch daemon (SCRATCH_PORT/SCRATCH_TOKEN)")
        }
    }

    private func launch(token: String? = nil, _ extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.appearance = .light
        let app = XCUIApplication()
        app.launchArguments = ["-gravHost", "127.0.0.1", "-gravPort", env["SCRATCH_PORT"]!,
                               "-gravToken", token ?? env["SCRATCH_TOKEN"]!, "-noNotificationPrompt", "YES"] + extra
        app.launch()
        return app
    }

    // MARK: H-200: release item states

    /// The project opens from the cache before the connection is up ("Not connected to
    /// the Flotilla service."): tap the segment again until `target` shows.
    private func segment(_ app: XCUIApplication, _ name: String, until target: XCUIElement, timeout: TimeInterval = 40) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            app.pane(name).tap()
            if target.waitForExistence(timeout: 4) { return }
            app.pane("Overview").tap()
            sleep(1)
        } while Date() < deadline
    }

    private func openRelease(_ app: XCUIApplication, _ version: String) {
        waitFor(app.navigationBars["The Hermes"], 30)
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(version),")).firstMatch
        segment(app, "Releases", until: app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'iOS 0.5.1' OR label BEGINSWITH '0.17'")).firstMatch)
        app.scroll(to: row)
        waitFor(row).tap()
        sleep(2)
    }

    /// Every label on the release screen, scrolled through, with screenshots of each page.
    private func readRelease(_ app: XCUIApplication, _ name: String) -> [String] {
        var words: [String] = []
        for page in 0..<8 {
            words += app.visibleWords
            screenshot("QA-006-\(name)-\(page)")
            let before = app.visibleWords
            app.swipeUp()
            sleep(1)
            if app.visibleWords == before { break }
        }
        return words
    }

    private func assertNoPending(_ words: [String], _ release: String) {
        for word in words where word.range(of: "\\bpending\\b", options: [.regularExpression, .caseInsensitive]) != nil {
            XCTFail("\(release) shows \"pending\": \(word)")
        }
    }

    func testDeployedRelease0173() {
        let app = launch(["-openProject", "The Hermes", "-openSegment", "releases"])
        openRelease(app, "0.17.3")
        let words = readRelease(app, "h200-0.17.3")
        assertNoPending(words, "0.17.3")
        let joined = words.joined(separator: " | ")
        for item in ["H-167", "H-189"] { XCTAssertTrue(joined.contains(item), "0.17.3 lacks \(item)") }
        XCTAssertGreaterThanOrEqual(words.filter { $0.contains("Included") }.count, 2, "0.17.3: items not ✓ Included")
        XCTAssertTrue(joined.contains("Done ·"), "0.17.3: no board column under the titles")
    }

    func testPlannedRelease0174() {
        let app = launch(["-openProject", "The Hermes", "-openSegment", "releases"])
        openRelease(app, "0.17.4")
        let words = readRelease(app, "h200-0.17.4")
        assertNoPending(words, "0.17.4")
        let joined = words.joined(separator: " | ")
        XCTAssertTrue(joined.contains("Progress"), "0.17.4: no Progress section")
        XCTAssertTrue(joined.contains("7 of 15 items ready"), "0.17.4: the readiness line is not \"7 of 15 items ready\" (the board's plan)")
        // Each item's pill against the board's plan (desktop ReleaseProgress): the 7 ready are in Verify.
        let ready: Set<String> = ["H-174", "H-178", "H-182", "H-183", "H-187", "H-192", "H-193"]
        var pill: [String: String] = [:]
        var current: String?
        for word in words {
            if let match = word.range(of: "^H-[0-9]+ · ", options: .regularExpression) {
                current = String(word[match].dropLast(3))
            } else if let item = current, pill[item] == nil,
                      word.contains("Ready for the release") || word.contains("Still in progress") {
                pill[item] = word
            }
        }
        for (item, text) in pill {
            XCTAssertEqual(text.contains("Ready for the release"), ready.contains(item), "\(item): \(text)")
        }
        print("QA-006 0.17.4 pills: \(pill.count) read, \(pill.values.filter { $0.contains("Ready") }.count) ready")
        for item in ["H-155", "H-174", "H-176", "H-178", "H-182", "H-183", "H-184", "H-187", "H-188", "H-191",
                     "H-192", "H-193", "H-195", "H-201", "H-203"] {
            XCTAssertTrue(joined.contains(item), "0.17.4 lacks \(item)")
        }
        let pills = words.filter { $0.contains("Ready for the release") || $0.contains("Still in progress") }
        XCTAssertFalse(pills.isEmpty, "0.17.4: no Ready / Still in progress pills")
        for column in ["Inbox ·", "Verify ·", "Ready ·", "Doing ·"] {
            XCTAssertTrue(joined.contains(column), "0.17.4: no \"\(column)\" row")
        }
        XCTAssertFalse(joined.contains("Included"), "0.17.4 is not submitted: nothing is Included yet")
    }

    func testApprovedReleaseIOS050() {
        let app = launch(["-openProject", "The Hermes", "-openSegment", "releases"])
        openRelease(app, "iOS 0.5.0")
        let words = readRelease(app, "h200-ios-0.5.0")
        assertNoPending(words, "iOS 0.5.0")
        let joined = words.joined(separator: " | ")
        for item in ["H-108", "H-118", "H-134"] { XCTAssertTrue(joined.contains(item), "iOS 0.5.0 lacks \(item)") }
        XCTAssertGreaterThanOrEqual(words.filter { $0.contains("Included") }.count, 3, "iOS 0.5.0: items not ✓ Included")
        XCTAssertTrue(joined.contains("Deploying ·"), "iOS 0.5.0: no board column under the titles")
    }

    // MARK: H-202: comments

    private func openCard(_ app: XCUIApplication, _ id: String) {
        waitFor(app.navigationBars["The Hermes"], 30)
        let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Inbox'")).firstMatch
        segment(app, "Board", until: chip)
        let inbox = waitFor(chip, 5)
        inbox.tap()
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", id)).firstMatch
        app.scroll(to: card)
        waitFor(card, 15).tap()
        waitFor(app.navigationBars[id], 15)
    }

    private func composer(_ app: XCUIApplication) -> XCUIElement {
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        app.scroll(to: field)
        return waitFor(field)
    }

    func testCommentSendingThenPostedAndReply() {
        let app = launch(["-openProject", "The Hermes", "-openSegment", "board"])
        openCard(app, "H-155")
        let text = "QA-006 UI test, no action needed (scratch copy) \(Int(Date().timeIntervalSince1970))"
        let field = composer(app)
        field.tap()
        field.typeText(text)
        app.buttons["Send"].tap()
        // At once, optimistically, then confirmed by the board: sample the screen until the
        // board's copy (with its own Reply) has replaced ours.
        var seen: [String] = []
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let words = app.visibleWords
            for state in ["Sending…", "Posted", "Not posted"] where words.contains(where: { $0 == state || $0.hasSuffix(", \(state)") || $0.hasPrefix("\(state),") }) && !seen.contains(state) {
                seen.append(state)
                screenshot("QA-006-h202-\(state == "Sending…" ? "sending" : state == "Posted" ? "posted" : "not-posted-unexpected")")
            }
            if seen.contains("Posted") { break }
        }
        print("QA-006 states seen after Send: \(seen)")
        XCTAssertFalse(seen.contains("Not posted"), "The board refused a plain comment")
        let comment = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        waitFor(comment, 15)
        // Accepted by the board: the board's own copy, with its Reply, replaces ours. On a
        // 0.17.x daemon (with H-201 bodies) that happens before "Posted" can be seen.
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == 'Reply'")).count >= 1, "The comment never became the board's")
        print("QA-006 OBSERVATION: Sending…/Posted seen before the board copy: \(seen)")
        screenshot("QA-006-h202-on-the-board")

        // Reply to a comment: "Replying to …", sent and nested.
        let reply = app.buttons.matching(NSPredicate(format: "label == 'Reply'")).firstMatch
        app.scroll(to: reply)
        waitFor(reply).tap()
        waitFor(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Replying to'")).firstMatch)
        screenshot("QA-006-h202-replying-to")
        let replyText = "QA-006 reply, no action needed \(Int(Date().timeIntervalSince1970))"
        let replyField = composer(app)
        replyField.tap()
        replyField.typeText(replyText)
        app.buttons["Send"].tap()
        let sent = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", replyText)).firstMatch
        waitFor(sent, 15)
        sleep(2)
        // Nested: indented under the comment it answers.
        let parent = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        if parent.exists && sent.exists {
            XCTAssertGreaterThan(sent.frame.minX, parent.frame.minX, "The reply is not nested under its comment")
        }
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Not posted'")).firstMatch.exists)
        screenshot("QA-006-h202-reply-posted")
    }

    /// A device without control access gets no composer: the card can't be commented on.
    func testReadOnlyDeviceHasNoComposer() throws {
        let readonly = try XCTUnwrap(env["SCRATCH_READONLY_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }, "No read-only token")
        let app = launch(token: readonly, ["-openProject", "The Hermes", "-openSegment", "board"])
        openCard(app, "H-155")
        app.swipeUp(); app.swipeUp()
        sleep(1)
        screenshot("QA-006-h202-readonly-card")
        XCTAssertFalse(app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Comment'")).firstMatch.exists ||
                       app.textViews.firstMatch.exists, "A read-only device is offered a comment box")
        XCTAssertFalse(app.buttons["Reply"].exists, "A read-only device is offered Reply")
    }
}
