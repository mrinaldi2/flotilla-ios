import XCTest

/// QA-007: H-160 AC4, the phone release review (UX-023 screen 2, UX-040), against the
/// scratch daemon on a copy of this Mac's board. Each test rules on its own package,
/// seeded in the copy awaiting the owner (seed_release.py: clones of iOS 0.5.0 with
/// H-108, H-118 and H-134), and reads back what the copy recorded through
/// scratch_control.py. Skips without SCRATCH_PORT/SCRATCH_TOKEN/SCRATCH_CONTROL_PORT.
final class H160ReleaseReviewTests: XCTestCase {
    private var env: [String: String] { DemoApp.environment }

    override func setUpWithError() throws {
        continueAfterFailure = true
        if UIDevice.current.userInterfaceIdiom == .pad { throw XCTSkip("iPhone layout") }
        for key in ["SCRATCH_PORT", "SCRATCH_TOKEN", "SCRATCH_CONTROL_PORT"] where (env[key] ?? "").isEmpty {
            throw XCTSkip("No scratch daemon (\(key))")
        }
    }

    // MARK: Helpers

    private func launch(_ auth: String = "pass") -> XCUIApplication {
        XCUIDevice.shared.appearance = .light
        let app = XCUIApplication()
        app.launchArguments = ["-gravHost", "127.0.0.1", "-gravPort", env["SCRATCH_PORT"]!,
                               "-gravToken", env["SCRATCH_TOKEN"]!, "-noNotificationPrompt", "YES",
                               "-ownerAuthStub", auth, "-openProject", "The Hermes", "-openSegment", "releases"]
        app.launch()
        return app
    }

    /// Open the package's review: the project loads from cache first, so re-tap Releases until it lists it.
    @discardableResult
    private func review(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        waitFor(app.navigationBars["The Hermes"], 30)
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(name),")).firstMatch
        let deadline = Date().addingTimeInterval(45)
        repeat {
            app.pane("Releases").tap()
            if row.waitForExistence(timeout: 4) { break }
            app.pane("Overview").tap()
            sleep(1)
        } while Date() < deadline
        app.scroll(to: row)
        waitFor(row).tap()
        waitFor(app.navigationBars[name], 20)
        let approve = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Approve'")).firstMatch
        _ = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Leave out'")).firstMatch.waitForExistence(timeout: 20)
        app.scroll(to: approve)
        XCTAssertTrue(approve.waitForExistence(timeout: 20), "\(name): no review (Approve) on a package awaiting the owner")
        return approve
    }

    private func text(_ app: XCUIApplication, _ contains: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", contains)).firstMatch
    }

    private func control(_ path: String) throws -> [String: Any] {
        let port = try XCTUnwrap(env["SCRATCH_CONTROL_PORT"])
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        var result: [String: Any] = [:]
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            result = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any] ?? [:]
            done.signal()
        }.resume()
        done.wait()
        return result
    }

    private func state(_ name: String) throws -> [String: Any] {
        let s = try control("/state?name=\(name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)")
        let data = try JSONSerialization.data(withJSONObject: s, options: [.sortedKeys])
        XCTContext.runActivity(named: "copy: \(name)") { $0.add(XCTAttachment(data: data, uniformTypeIdentifier: "public.json")) }
        return s
    }

    private func verdicts(_ s: [String: Any]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: ((s["items"] as? [[String: Any]]) ?? []).map {
            ($0["item_id"] as? String ?? "", "\($0["verdict"] as? String ?? "")\(($0["owner_note"] as? String).map { ": \($0)" } ?? "")")
        })
    }

    private func decisionState(_ s: [String: Any]) -> String { (s["decision"] as? [String: Any])?["state"] as? String ?? "" }

    private func leaveOut(_ app: XCUIApplication, _ id: String, rework note: String?) {
        let button = app.buttons["Leave out \(id)"]
        app.scroll(to: button)
        waitFor(button).tap()
        waitFor(app.navigationBars["Leave out \(id)?"])
        if let note {
            app.buttons["Rework: back to Doing, with a note"].tap()
            let field = app.textFields["What needs rework"].exists ? app.textFields["What needs rework"] : app.textViews["What needs rework"]
            XCTAssertFalse(app.navigationBars.buttons["Leave out"].isEnabled, "Rework without a note can be confirmed")
            waitFor(field).tap()
            field.typeText(note)
        } else {
            let field = app.textFields["Note (optional)"].exists ? app.textFields["Note (optional)"] : app.textViews["Note (optional)"]
            if field.exists { field.tap(); field.typeText("QA-007 next time") }
        }
        screenshot("QA-007-h160-ac4-leave-out-\(id)")
        app.navigationBars.buttons["Leave out"].tap()
    }

    // MARK: AC4

    /// Leave out (Hold and Rework), Include, Approve 1 of 3 → Undo within 5 s → nothing sent;
    /// approve again, switch tabs while the app-wide bar runs, outcome line, and the copy's ruling.
    func testLeaveOutApproveNofMUndoThenApproveAcrossTabs() throws {
        let name = "iOS 0.5.0-qc1"
        let app = launch()
        let approve = review(app, name)
        XCTAssertEqual(approve.label, "Approve \(name)")

        leaveOut(app, "H-118", rework: nil)
        XCTAssertTrue(text(app, "Left out · waits for the next package").waitForExistence(timeout: 5), "Hold left-out line")
        leaveOut(app, "H-108", rework: "QA-007 needs rework")
        XCTAssertTrue(text(app, "Left out · back to Doing: “QA-007 needs rework”").waitForExistence(timeout: 5), "Rework left-out line")
        XCTAssertTrue(text(app, "2 items left out · DevOps repackages the rest").exists, "left-out footer")
        app.scroll(to: app.buttons["Approve 1 of 3 items"])
        XCTAssertTrue(app.buttons["Approve 1 of 3 items"].exists, "Approve N of M")
        // Include brings it back; leave it out again.
        app.scroll(to: app.buttons["Include H-118"])
        app.buttons["Include H-118"].tap()
        app.scroll(to: app.buttons["Approve 2 of 3 items"])
        XCTAssertTrue(app.buttons["Approve 2 of 3 items"].waitForExistence(timeout: 3), "Include")
        leaveOut(app, "H-118", rework: nil)
        screenshot("QA-007-h160-ac4-left-out")

        // Approve → Undo within 5 s: nothing is sent.
        app.scroll(to: app.buttons["Approve 1 of 3 items"])
        app.buttons["Approve 1 of 3 items"].tap()
        let bar = text(app, "Approving 1 of 3 items of \(name)")
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "No 'Approving 1 of 3 items of …' bar")
        screenshot("QA-007-h160-ac4-approving-undo")
        app.buttons["Undo"].firstMatch.tap()
        XCTAssertTrue(text(app, "Undone. Nothing was sent.").waitForExistence(timeout: 5), "No 'Undone' outcome")
        screenshot("QA-007-h160-ac4-undone")
        sleep(7)
        var s = try state(name)
        XCTAssertEqual(s["status"] as? String, "awaiting_owner", "Undo still sent the ruling")
        XCTAssertEqual(decisionState(s), "open")

        // Approve again, and leave for another tab while the bar runs: it follows (UX-040).
        app.scroll(to: app.buttons["Approve 1 of 3 items"])
        if !app.buttons["Approve 1 of 3 items"].exists {
            // Finding: Undo's outcome is ok, and the screen clears leftOut on any ok outcome.
            XCTFail("left-out choices lost after Undo")
            screenshot("QA-008-h160-ac4-after-undo-choices-lost")
            leaveOut(app, "H-118", rework: nil)
            leaveOut(app, "H-108", rework: "QA-007 needs rework")
            app.scroll(to: app.buttons["Approve 1 of 3 items"])
        }
        app.buttons["Approve 1 of 3 items"].tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        app.tabBars.buttons["Chat"].tap()
        XCTAssertTrue(text(app, "Approving 1 of 3 items of \(name)").waitForExistence(timeout: 2), "The bar did not follow to Chat")
        XCTAssertTrue(app.buttons["Undo"].exists, "No Undo on Chat")
        screenshot("QA-007-h160-ac4-bar-on-needs-you")
        let outcome = text(app, "1 of 3 items of \(name) approved. DevOps repackages them next.")
        XCTAssertTrue(outcome.waitForExistence(timeout: 15), "No outcome line after approving")
        screenshot("QA-007-h160-ac4-approved-n-of-m")

        s = try state(name)
        XCTAssertEqual(s["status"] as? String, "repackaging")
        XCTAssertEqual(decisionState(s), "settled")
        XCTAssertEqual(verdicts(s), ["H-134": "ship", "H-118": "hold: QA-007 next time", "H-108": "rework: QA-007 needs rework"])
    }

    func testApproveAll() throws {
        let name = "iOS 0.5.0-qc2"
        let app = launch()
        let approve = review(app, name)
        XCTAssertTrue(text(app, "DevOps rolls \(name) out to each computer").exists, "approve footer")
        screenshot("QA-007-h160-ac4-review")
        approve.tap()
        XCTAssertTrue(text(app, "Approving \(name)").waitForExistence(timeout: 5), "No 'Approving …' bar")
        XCTAssertTrue(text(app, "\(name) approved. DevOps rolls it out next.").waitForExistence(timeout: 15), "No approved outcome")
        screenshot("QA-007-h160-ac4-approved")
        let s = try state(name)
        XCTAssertEqual(s["status"] as? String, "approved")
        XCTAssertEqual(decisionState(s), "settled")
        XCTAssertEqual(verdicts(s), ["H-108": "ship", "H-118": "ship", "H-134": "ship"])
    }

    func testRejectWithAReason() throws {
        let name = "iOS 0.5.0-qc3"
        let app = launch()
        review(app, name)
        let reject = app.buttons["Reject…"]
        app.scroll(to: reject)
        reject.tap()
        waitFor(app.navigationBars["Reject \(name)?"])
        XCTAssertFalse(app.navigationBars.buttons["Reject"].isEnabled, "Reject without a reason can be sent")
        let field = app.textFields["Reason"].exists ? app.textFields["Reason"] : app.textViews["Reason"]
        field.tap()
        field.typeText("QA-007 reject reason")
        screenshot("QA-007-h160-ac4-reject-sheet")
        app.navigationBars.buttons["Reject"].tap()
        sleep(4)
        screenshot("QA-007-h160-ac4-rejected")
        let s = try state(name)
        XCTAssertEqual(s["status"] as? String, "rejected")
        XCTAssertEqual(decisionState(s), "settled")
        XCTAssertEqual(Set(verdicts(s).values), ["rework: QA-007 reject reason"], "reason copied to every item, back to Doing")
    }

    func testHoldWithANote() throws {
        let name = "iOS 0.5.0-qc4"
        let app = launch()
        review(app, name)
        let hold = app.buttons["Hold"]
        app.scroll(to: hold)
        hold.tap()
        waitFor(app.navigationBars["Hold \(name)?"])
        let field = app.textFields["Note (optional)"].exists ? app.textFields["Note (optional)"] : app.textViews["Note (optional)"]
        field.tap()
        field.typeText("QA-007 hold note")
        app.buttons["In 3 days"].tap()
        screenshot("QA-007-h160-ac4-hold-sheet")
        app.navigationBars.buttons["Hold"].tap()
        sleep(4)
        screenshot("QA-007-h160-ac4-held")
        let s = try state(name)
        XCTAssertEqual(s["status"] as? String, "held")
        XCTAssertEqual(s["held_note"] as? String, "QA-007 hold note")
        XCTAssertNotNil(s["remind_at"] as? String, "no reminder recorded")
    }

    /// Face ID refused: nothing sent. Then the package changes from another client mid-review:
    /// approving says it changed and sends nothing; the daemon's own error is attached.
    func testFaceIDRefusedThenVersionConflict() throws {
        let name = "iOS 0.5.0-qc5"
        var app = launch("fail")
        review(app, name).tap()
        XCTAssertTrue(text(app, "Not approved. Nothing was sent.").waitForExistence(timeout: 8), "Face ID refusal words")
        screenshot("QA-007-h160-ac4-faceid-refused")
        XCTAssertEqual(try state(name)["status"] as? String, "awaiting_owner")
        app.terminate()

        app = launch()
        let approve = review(app, name)
        let before = try state(name)["version"] as? Int ?? 0
        let bump = try control("/bump?name=\(name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)")
        XCTContext.runActivity(named: "other client: \(bump)") { _ in }
        XCTAssertGreaterThan(bump["after"] as? Int ?? 0, before, "the other client did not change the package")
        approve.tap()
        let changed = text(app, "\(name) changed while you were reviewing it. Nothing was sent. Check it again, then rule.")
        XCTAssertTrue(changed.waitForExistence(timeout: 15), "No 'changed while you were reviewing it' line")
        screenshot("QA-007-h160-ac4-version-conflict")
        let s = try state(name)
        XCTAssertEqual(s["status"] as? String, "awaiting_owner", "a ruling was recorded despite the conflict")
        XCTAssertEqual(Set(verdicts(s).values), ["pending"])
        XCTAssertEqual(decisionState(s), "open")
        // What the daemon itself answers to a stale expected_version.
        let stale = try control("/stale?name=\(name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)")
        let data = try JSONSerialization.data(withJSONObject: stale, options: [.sortedKeys])
        XCTContext.runActivity(named: "daemon reply to a stale version") { $0.add(XCTAttachment(data: data, uniformTypeIdentifier: "public.json")) }
        print("QA-007 stale reply: \(String(data: data, encoding: .utf8)!)")
    }
}
