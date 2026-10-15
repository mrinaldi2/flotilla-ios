import XCTest

/// H-248 (UX-048/UX-049): "▲ Waiting for you" on the release screen, the Progress
/// "Now:" line, and the Projects-card pill. The release is STUBBED (Debug -releaseStub
/// with owner_blockers) because the demo daemon has no 0.17.5 release service; the
/// Projects card comes from -homeFixture. The demo world is real (the decision id is
/// the demo's own, so Answer opens a real decision).
/// Copy that iOS Dev is still adjusting (the Run row title, the "Now:" wording) is
/// captured, not asserted word for word.
final class QA014WaitingTests: XCTestCase {
    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: Stubs

    private func json(_ object: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]), as: UTF8.self)
    }

    private func blocker(_ kind: String, _ id: String, _ title: String, item: String?, computer: String? = nil,
                         at hour: Int) -> [String: Any] {
        ["kind": kind, "id": id, "title": title, "item_id": item ?? NSNull(), "bot": NSNull(),
         "computer": computer ?? NSNull(), "created_at": String(format: "2026-10-08T%02d:00:00Z", hour)]
    }

    /// A release in `status`; `blockers` nil = an older service (no owner_blockers key).
    private func release(_ status: String, blockers: [[String: Any]]?, extra: [String: Any] = [:]) -> String {
        var r: [String: Any] = ["id": "rel-qa", "name": "0.17.5", "display_version": "0.17.5", "status": status,
                                "version": 3, "work_item_id": "H-247",
                                "items": [["item_id": "H-247", "verdict": "pending"]]]
        if let blockers { r["owner_blockers"] = blockers }
        r.merge(extra) { _, new in new }
        return json(["release": r])
    }

    private func open(_ release: String, _ more: [String] = []) throws -> XCUIApplication {
        let app = try DemoApp.launch(["-releaseStub", release, "-noNotificationPrompt", "YES"] + more)
        allowSystemAlerts()
        return app
    }

    private func any(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func shot(_ name: String) { screenshot("QA-014-\(name)-STUB-\(device)") }

    private var decisionId: String { DemoApp.environment["DEMO_DECISION_ID"] ?? "d-qa" }

    /// A plan for Progress: `open` items not ready, then ready ones.
    private func plan(open: Int, ready: Int) -> [[String: Any]] {
        let columns = ["Doing", "Review", "Doing", "Verify"]
        return (0..<open).map { ["item_id": "H-24\($0 + 1)", "ready": false, "column_name": columns[$0 % columns.count]] }
            + (0..<ready).map { ["item_id": "H-23\($0 + 1)", "ready": true, "column_name": "Verify"] }
    }

    // MARK: 1–4, iPhone and iPad

    /// 1: one Run card: the "Run it on mac, in the Flotilla app." row with no button.
    func test1RunCardRowHasNoButton() throws {
        let app = try open(release("approved", blockers: [blocker("run", "a-1", "Clear the stale build cache", item: "H-242", computer: "mac", at: 8)]))
        XCTAssertTrue(any(app, "Waiting for you").waitForExistence(timeout: 20), "No Waiting for you section")
        XCTAssertTrue(any(app, "Run it on mac, in the Flotilla app.").exists, "The Run row doesn't say where to run it")
        for label in ["Answer", "Review", "Review…"] {
            XCTAssertFalse(app.buttons[label].exists, "The Run row has a \(label) button")
        }
        shot("1-run-card")
    }

    /// 2: a decision and a question: Answer opens the decision; the question's Answer
    /// opens its card with the reply sheet (the demo has no such card: captured as is).
    func test2DecisionAndQuestion() throws {
        let stub = release("approved", blockers: [
            blocker("question", "c-9", "Ship the notes as they are?", item: "H-240", at: 9),
            blocker("decision", decisionId, "Which accent colour for the App Store screenshots?", item: "H-241", at: 10)])
        let app = try open(stub)
        XCTAssertTrue(any(app, "Waiting for you").waitForExistence(timeout: 20), "No Waiting for you section")
        let decide = any(app, "Decide:")
        let asks = any(app, "asks:")
        XCTAssertTrue(decide.exists && asks.exists, "Not both rows")
        if decide.exists && asks.exists { XCTAssertLessThan(decide.frame.minY, asks.frame.minY, "The question came before the decision") }
        shot("2-decision-and-question")
        decide.tap()
        XCTAssertTrue(app.navigationBars["Decision"].waitForExistence(timeout: 10), "Answer did not open the decision")
        shot("2a-decision-opened")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(asks.waitForExistence(timeout: 10))
        asks.tap()
        sleep(4)
        shot("2b-question-answer")
        let reply = any(app, "Reply to")
        XCTContext.runActivity(named: "Reply sheet shown: \(reply.exists)") { _ in }
        print("QA-014 question Answer: reply sheet \(reply.exists ? "shown" : "not shown (no such card in the demo)")")
    }

    /// 3: a ruling first, then 4 more: the order and "+n more".
    func test3RulingFirstThenMore() throws {
        let stub = release("awaiting_owner", blockers: [
            blocker("question", "c-1", "Ship the notes as they are?", item: "H-240", at: 7),
            blocker("decision", decisionId, "Which accent colour for the App Store screenshots?", item: "H-241", at: 9),
            blocker("run", "a-1", "Clear the stale build cache", item: "H-242", computer: "mac", at: 8),
            blocker("ruling", "rel-qa", "0.17.5", item: "H-247", at: 11),
            blocker("decision", "d-3", "Hold 0.17.5 for the fix?", item: "H-244", at: 12)])
        let app = try open(stub)
        XCTAssertTrue(any(app, "Waiting for you · 5").waitForExistence(timeout: 20), "No '· 5' section")
        let ruling = any(app, "Test 0.17.5 and rule on it")
        let more = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '+'")).firstMatch
        XCTAssertTrue(ruling.exists, "No ruling row")
        XCTAssertTrue(more.exists, "No '+n more'")
        if ruling.exists, any(app, "Run it on").exists { XCTAssertLessThan(ruling.frame.minY, any(app, "Run it on").frame.minY, "The ruling isn't first") }
        XCTContext.runActivity(named: "more: \(more.label)") { _ in }
        shot("3-ruling-first-plus-more")
        more.tap()
        sleep(1)
        XCTAssertTrue(any(app, "asks:").waitForExistence(timeout: 5), "'+n more' did not show the rest")
        shot("3b-expanded")
    }

    /// 4: nothing waiting (owner_blockers: []): no section.
    func test4NothingWaitingNoSection() throws {
        let app = try open(release("approved", blockers: []))
        XCTAssertTrue(any(app, "0.17.5").waitForExistence(timeout: 20))
        sleep(3)
        XCTAssertFalse(any(app, "Waiting for you").exists, "A section with nothing waiting")
        shot("4-nothing-waiting")
    }

    // MARK: 5, 7: the Progress section (iPhone)

    /// 5: the "Now:" lines that a stub can reach.
    func test5NowLines() throws {
        if device == "iPad" { throw XCTSkip("iPhone captures") }
        let cases: [(String, String, [[String: Any]], [String: Any])] = [
            ("5a-now-waiting-for-you", "planned",
             [blocker("run", "a-1", "Clear the stale build cache", item: "H-244", computer: "mac", at: 8)],
             ["plan": plan(open: 1, ready: 2)]),
            ("5b-now-items-in-progress", "planned", [], ["plan": plan(open: 3, ready: 1)]),
            ("5c-now-building", "assembling", [],
             ["plan": plan(open: 0, ready: 3), "how_to_test": [["platform": "desktop-mac"], ["platform": "desktop-win"]]]),
            ("5d-now-testing", "built", [],
             ["plan": plan(open: 0, ready: 3), "readiness": ["items_ready": 3, "items_total": 3, "builds": ["desktop-mac", "desktop-win"],
                                                              "tests_required": ["mac", "win-pc"], "tests_passed": ["mac"]]]),
            ("5e-now-nothing-blocking", "built", [],
             ["plan": plan(open: 0, ready: 3), "readiness": ["items_ready": 3, "items_total": 3, "builds": ["desktop-mac"],
                                                              "tests_required": ["mac"], "tests_passed": ["mac"]]]),
        ]
        for (name, status, blockers, extra) in cases {
            let app = try open(release(status, blockers: blockers, extra: extra))
            let now = any(app, "Now:")
            if !now.waitForExistence(timeout: 20) { app.scroll(to: now) }
            XCTAssertTrue(now.exists, "\(name): no 'Now:' line")
            app.scroll(to: now)
            XCTContext.runActivity(named: "\(name): \(now.label)") { _ in }
            print("QA-014 \(name): \(now.label)")
            shot(name)
            app.terminate()
        }
    }

    /// 7: an older service (no owner_blockers): no section; under "Now:" a row
    /// "Open Needs you to see what waits for you." that goes to Needs you (d778e8a).
    func test7OlderServiceLinksToNeedsYou() throws {
        if device == "iPad" { throw XCTSkip("iPhone capture") }
        let stub = #"{"release":{"id":"rel-qa","name":"0.17.5","display_version":"0.17.5","status":"approved","version":3}}"#
        let app = try open(stub)
        let link = any(app, "Open Needs you to see what waits for you.")
        if !link.waitForExistence(timeout: 20) { app.scroll(to: link) }
        XCTAssertTrue(link.exists, "No Needs you row")
        XCTAssertFalse(any(app, "Waiting for you").exists, "A section on an older service")
        let now = any(app, "Now:")
        if link.exists, now.exists { XCTAssertLessThan(now.frame.minY, link.frame.minY, "The row isn't under 'Now:'") }
        shot("7-older-service")
        link.tap()
        XCTAssertTrue(app.navigationBars["Needs you"].waitForExistence(timeout: 10), "The row did not open Needs you")
        shot("7b-needs-you")
    }

    // MARK: 6: the Projects card pill (iPhone)

    /// 6: "◐ 0.17.5 waits for you" on the Projects card, from the golden overview with
    /// owner_blocker_count set (-homeFixture). The Releases-list pill has no hook.
    func test6ProjectsCardPill() throws {
        if device == "iPad" { throw XCTSkip("iPhone capture") }
        let fixtures = try XCTUnwrap(DemoApp.environment["FIXTURES"], "No FIXTURES: run scripts/ui-tests.sh")
        let out = try XCTUnwrap(DemoApp.environment["DEMO_OUT"], "No DEMO_OUT: run scripts/ui-tests.sh")
        let data = try Data(contentsOf: URL(fileURLWithPath: fixtures + "/home/overview.json"))
        var overview = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var rows = try XCTUnwrap(overview["rows"] as? [[String: Any]])
        var first = rows[0]
        var brief = try XCTUnwrap(first["current_release"] as? [String: Any])
        brief["version"] = "0.17.5"
        brief["state"] = "approved"
        brief["awaiting_owner"] = false
        brief["owner_blocker_count"] = 2
        first["current_release"] = brief
        rows[0] = first
        overview["rows"] = rows
        let path = out + "/qa014-overview.json"
        try JSONSerialization.data(withJSONObject: overview).write(to: URL(fileURLWithPath: path))
        let app = try DemoApp.launch(["-homeFixture", path, "-noNotificationPrompt", "YES"])
        allowSystemAlerts()
        let pill = any(app, "◐ 0.17.5 waits for you")
        XCTAssertTrue(pill.waitForExistence(timeout: 20), "No '◐ 0.17.5 waits for you' on the Projects card")
        screenshot("QA-014-6-projects-card-pill-FIXTURE-iPhone")
    }
}
