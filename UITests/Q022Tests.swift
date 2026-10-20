import XCTest

/// 0.22 on the demo world: a bot's questions answered on the card, in the
/// project's Questions list and in Needs you; the artifacts grouped as
/// Shared, Uploads and Checks with their cards, Tidy up, and the card's one
/// Documents list. They need a daemon with `questions_v1` and `artifacts_v2`
/// (DEMO_DAEMON built from flotilla's release-0.22.0) and skip on an older one.
///
/// Answering, keeping and removing need the `approve` grant, which the demo's
/// owner token lacks (H-234): there the tests check the app says so and offers
/// nothing that would be refused; on a paired device they answer for real.
final class Q022Tests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
        if UIDevice.current.userInterfaceIdiom == .pad { throw XCTSkip("iPhone layout") }
        try requireLiveDaemon()
    }

    private func require(_ capability: String) throws {
        let caps = (try DemoControl.post("/lab"))["caps"] as? [String] ?? []
        guard caps.contains(capability) else { throw XCTSkip("The demo daemon predates 0.22 (no \(capability))") }
    }

    private func any(_ app: XCUIApplication, _ format: String, _ args: CVarArg...) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: format, argumentArray: args)).firstMatch
    }

    /// The Lab's board, opened so it exists (the seed's cards need one), then `seed`.
    private func openLab(seed path: String) throws -> (XCUIApplication, [String: Any]) {
        let app = try DemoApp.launch(["-openProject", "Flotilla Lab", "-openSegment", "board"])
        allowSystemAlerts()
        waitFor(app.navigationBars["Flotilla Lab"], 20)
        sleep(3) // board_watch creates the Lab board
        return (app, try DemoControl.post(path))
    }

    /// A card on the Lab's board, found under its column's chip.
    private func openCard(_ app: XCUIApplication, title: String) -> XCUIElement {
        let card = any(app, "label CONTAINS %@", title)
        for chip in ["Inbox", "Research", "To do", "Ready", "Backlog"] where !card.exists {
            let button = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", chip)).firstMatch
            if button.exists { button.tap() }
            _ = card.waitForExistence(timeout: 4)
        }
        return waitFor(card, 20)
    }

    /// A part of one question: `question-<part>-<id>[-<option>]`.
    private func part(_ app: XCUIApplication, _ name: String, _ id: String, _ option: String? = nil) -> XCUIElement {
        app.descendants(matching: .any)["question-\(name)-\(id)" + (option.map { "-\($0)" } ?? "")]
    }

    /// The project's ⋯ menu, then one of its entries; tapped again if the menu
    /// was still opening and swallowed the first tap.
    private func more(_ app: XCUIApplication, _ entry: String, opens title: String) {
        waitFor(app.navigationBars.buttons["More"]).tap()
        for _ in 0..<3 {
            let item = app.buttons[entry]
            guard item.waitForExistence(timeout: 5) else { break }
            sleep(1)
            if item.isHittable { item.tap() }
            if app.navigationBars[title].waitForExistence(timeout: 5) { return }
        }
        waitFor(app.navigationBars[title])
    }

    func testACardsQuestionsAreAnsweredAndDismissedInPlace() throws {
        try require("questions_v1")
        let (app, seed) = try openLab(seed: "/questions")
        let ids = try XCTUnwrap(seed["questions"] as? [String], "no questions asked")
        XCTAssertEqual(ids.count, 3)
        let card = openCard(app, title: "Saints dataset")
        // The card's badge counts its open questions.
        XCTAssertTrue(card.label.contains("3 open questions"), "the card's row says \(card.label)")
        screenshot("Q022-board-badge")
        card.tap()
        waitFor(app.staticTexts["Should v1 cover only the ~250 celebrated saints, or the full Martyrology?"], 20)
        XCTAssertTrue(any(app, "label CONTAINS %@", "Questions · 3 open").exists, "the section counts them")
        XCTAssertTrue(app.buttons["The ~250 celebrated saints, recommended"].exists, "the recommendation is marked")
        XCTAssertTrue(app.staticTexts["It sets the dataset's size and the licensing work."].exists, "why it matters")
        screenshot("Q022-card-questions")

        if app.staticTexts["This device can’t answer questions."].firstMatch.exists {
            // The demo's owner token: no answer controls, said under each question.
            XCTAssertFalse(part(app, "reply", ids[0]).exists, "no reply field")
            XCTAssertFalse(part(app, "option", ids[0], "celebrated").isEnabled, "options can't be sent")
        } else {
            // Pick the recommended option, add a note, send: the answer shows in its place.
            part(app, "option", ids[0], "celebrated").tap()
            let reply = part(app, "reply", ids[0])
            reply.tap()
            reply.typeText("Start with the celebrated ones.")
            part(app, "send", ids[0]).tap()
            waitFor(part(app, "answer", ids[0]), 15)
            XCTAssertTrue(any(app, "label CONTAINS %@", "Answered by you").exists)
            // A text-only question needs words before Send; dismissed with a reason.
            let send = part(app, "send", ids[2])
            app.scroll(to: send)
            XCTAssertFalse(send.isEnabled, "nothing to send yet")
            part(app, "dismiss", ids[2]).tap()
            let reason = waitFor(app.descendants(matching: .any)["question-dismiss-reason"])
            reason.typeText("We won't contact them before v1.")
            app.buttons["question-dismiss-confirm"].tap()
            waitFor(any(app, "label CONTAINS %@", "Dismissed: “We won't contact them before v1.”"), 15)
            screenshot("Q022-card-answered")
        }

        // The project's Questions, from its ⋯ menu: the open ones, then Answered.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        more(app, "Questions", opens: "Questions")
        waitFor(app.staticTexts["Italy plus the universal calendar only?"], 15)
        screenshot("Q022-project-questions")
        app.buttons["Answered"].tap()
        let answered = app.staticTexts["Should v1 cover only the ~250 celebrated saints, or the full Martyrology?"]
        if app.staticTexts["This device can’t answer questions."].firstMatch.exists || !answered.waitForExistence(timeout: 10) {
            waitFor(any(app, "label CONTAINS %@", "No answered questions yet"), 10)
        }
        // A question's card opens from the list, in this stack.
        let item = try XCTUnwrap(seed["item_id"] as? String)
        app.buttons["Open"].tap()
        waitFor(app.staticTexts["Italy plus the universal calendar only?"], 15)
        waitFor(app.buttons.matching(NSPredicate(format: "label == %@", item)).firstMatch, 15).tap()
        waitFor(app.navigationBars[item], 15)
    }

    func testNeedsYouAnswersAQuestionInPlace() throws {
        try require("questions_v1")
        let (app, seed) = try openLab(seed: "/questions")
        let ids = try XCTUnwrap(seed["questions"] as? [String])
        app.needsYou()
        // The Lab's card is further down, its rows folded under "N more": open them on the way.
        let option = part(app, "option", ids[1], "yes")
        let unfold = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show ' AND label CONTAINS 'more for Flotilla Lab'")).firstMatch
        for _ in 0..<20 where !(option.exists && option.isHittable) {
            if unfold.exists && unfold.isHittable { unfold.tap() } else { app.swipeUp() }
            _ = option.waitForExistence(timeout: 1)
        }
        waitFor(option, 20)
        screenshot("Q022-needs-you-question")
        XCTAssertTrue(any(app, "label == %@", "Italy plus the universal calendar only?").exists, "the question in the row")
        guard !app.staticTexts["This device can’t answer questions."].firstMatch.exists else { return }
        option.tap()
        part(app, "send", ids[1]).tap()
        let row = option
        // Answered, the row leaves Needs you.
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: row)
        waitForExpectations(timeout: 20)
    }

    func testArtifactsAreGroupedAndTidyUpKeepsAttachesAndRemoves() throws {
        try require("artifacts_v2")
        let (app, seed) = try openLab(seed: "/artifacts")
        let item = try XCTUnwrap(seed["item_id"] as? String)
        more(app, "Artifacts", opens: "Artifacts")
        // Shared, with the card that uses a file as a chip.
        waitFor(app.buttons["artifact-refs/saints-calendar.md"], 15)
        XCTAssertTrue(app.buttons["On card \(item)"].exists, "the file's card is a chip")
        screenshot("Q022-artifacts-shared")
        app.buttons["Uploads"].tap()
        waitFor(app.buttons["artifact-uploads/sketch.md"], 15)
        app.buttons["Checks"].tap()
        waitFor(app.buttons["artifact-checks/0a1b2c3d4e5f-lint.log"], 15)
        app.buttons["Shared"].tap()

        // Tidy up: the three loose files; keep one, attach one, remove one.
        waitFor(app.buttons["artifacts-tidy-up"], 15).tap()
        waitFor(app.navigationBars["Tidy up"])
        let kept = app.descendants(matching: .any)["tidy-refs/old-sources.md"]
        let attached = app.descendants(matching: .any)["tidy-refs/scratch-notes.md"]
        let removed = app.descendants(matching: .any)["tidy-refs/draft-table.md"]
        waitFor(kept, 15)
        XCTAssertTrue(attached.exists && removed.exists)
        screenshot("Q022-tidy-up")
        if app.staticTexts["This device can’t change the project’s files."].exists {
            // The demo's owner token: the answers are there but off.
            XCTAssertFalse(kept.buttons["tidy-keep"].isEnabled)
            XCTAssertFalse(removed.buttons["tidy-remove"].isEnabled)
        } else {
            let gone = NSPredicate(format: "exists == false")
            kept.buttons["tidy-keep"].tap()
            expectation(for: gone, evaluatedWith: kept)
            waitForExpectations(timeout: 15)

            attached.buttons["tidy-attach"].tap()
            waitFor(app.buttons["attach-card-\(item)"], 15).tap()
            expectation(for: gone, evaluatedWith: attached)
            waitForExpectations(timeout: 15)

            removed.buttons["tidy-remove"].tap()
            waitFor(app.buttons["tidy-remove-confirm"]).tap()
            expectation(for: gone, evaluatedWith: removed)
            waitForExpectations(timeout: 15)
        }

        // The card: its attached artifacts in one Documents list, each once.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        waitFor(app.buttons["On card \(item)"], 15).tap()
        waitFor(any(app, "label BEGINSWITH 'Documents'"), 20)
        XCTAssertEqual(app.buttons.matching(identifier: "item-document-refs/saints-calendar.md").count, 1)
        screenshot("Q022-card-documents")
    }
}
