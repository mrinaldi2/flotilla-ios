import XCTest

/// H-217 (iOS 0.6.1): short drops are ridden out; a real outage shows the banner after ~8 s;
/// screens reload after reconnect; leaving a screen while reconnecting doesn't freeze.
/// The app talks to the scratch daemon through scratch_control.py's proxy (SCRATCH_PROXY_PORT);
/// POST /cut?seconds=N drops every connection and refuses new ones for N s.
final class H217Tests: XCTestCase {
    private var env: [String: String] { DemoApp.environment }

    override func setUpWithError() throws {
        continueAfterFailure = true
        if UIDevice.current.userInterfaceIdiom == .pad { throw XCTSkip("iPhone layout") }
        for key in ["SCRATCH_TOKEN", "SCRATCH_CONTROL_PORT", "SCRATCH_PROXY_PORT"] where (env[key] ?? "").isEmpty {
            throw XCTSkip("No scratch proxy (\(key))")
        }
    }

    private func launch(_ extra: [String]) -> XCUIApplication {
        XCUIDevice.shared.appearance = .light
        let app = XCUIApplication()
        app.launchArguments = ["-gravHost", "127.0.0.1", "-gravPort", env["SCRATCH_PROXY_PORT"]!,
                               "-gravToken", env["SCRATCH_TOKEN"]!, "-noNotificationPrompt", "YES"] + extra
        app.launch()
        return app
    }

    @discardableResult
    private func control(_ path: String) -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(env["SCRATCH_CONTROL_PORT"]!)\(path)")!)
        request.httpMethod = "POST"
        var result: [String: Any] = [:]
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            result = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any] ?? [:]
            done.signal()
        }.resume()
        done.wait()
        return result
    }

    private func any(_ app: XCUIApplication, _ format: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: format)).firstMatch
    }

    private func notConnected(_ app: XCUIApplication) -> XCUIElement {
        any(app, "label BEGINSWITH 'Not connected'")
    }

    private func banner(_ app: XCUIApplication) -> XCUIElement {
        any(app, "label == 'Connecting…' OR label == 'Disconnected' OR label == 'Not connected'")
    }

    /// The Team pane (it carries the connection banner), loaded.
    private func team(_ app: XCUIApplication) -> XCUIElement {
        waitFor(app.navigationBars["The Hermes"], 30)
        let row = app.botRow("Architect")
        let deadline = Date().addingTimeInterval(45)
        while !row.exists, Date() < deadline { app.pane("Team").tap(); sleep(3) }
        XCTAssertTrue(row.exists, "Team did not load")
        return row
    }

    /// Watch `seconds`: when the banner first shows, and whether "Not connected" ever does.
    private func watch(_ app: XCUIApplication, _ seconds: TimeInterval) -> (banner: TimeInterval?, notConnected: Bool) {
        let start = Date()
        var first: TimeInterval?
        var error = false
        while Date().timeIntervalSince(start) < seconds {
            if first == nil, banner(app).exists { first = Date().timeIntervalSince(start) }
            if notConnected(app).exists { error = true }
            usleep(400_000)
        }
        return (first, error)
    }

    func testTwoSecondDropIsRiddenOut() {
        // On Decisions (it carries the banner; Projects, filtered, opens it), then on the project.
        let home = launch(["-openTab", "needs"])
        waitFor(home.navigationBars.buttons["Decisions"].firstMatch, 30).tap()
        sleep(4)
        control("/cut?seconds=2")
        let onDecisions = watch(home, 14)
        screenshot("QA-008-h217-decisions-after-2s-drop")
        XCTAssertNil(onDecisions.banner, "Decisions: a banner showed \(onDecisions.banner ?? 0) s into a 2 s drop")
        XCTAssertFalse(onDecisions.notConnected, "Decisions: 'Not connected' during a 2 s drop")
        home.terminate()

        let app = launch(["-openProject", "The Hermes", "-openSegment", "team"])
        _ = team(app)
        sleep(3)
        let cut = control("/cut?seconds=2")
        XCTContext.runActivity(named: "cut: \(cut)") { _ in }
        let seen = watch(app, 14)
        screenshot("QA-008-h217-after-2s-drop")
        XCTAssertNil(seen.banner, "A banner showed \(seen.banner ?? 0) s into a 2 s drop")
        XCTAssertFalse(seen.notConnected, "'Not connected' showed during a 2 s drop")
        // Still live: a screen loads after the drop.
        app.pane("Releases").tap()
        let release = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'iOS 0.5.0-q'")).firstMatch
        XCTAssertTrue(release.waitForExistence(timeout: 15), "Releases did not load after a 2 s drop")
        XCTAssertFalse(notConnected(app).exists, "'Not connected' after a 2 s drop")
    }

    /// The banner lives on Decisions, Activity and Reports (ConnectionBanner): watch it on Decisions.
    func testFifteenSecondOutageShowsBannerThenReloads() {
        let app = launch(["-openTab", "needs"])
        let decisions = app.navigationBars.buttons["Decisions"].firstMatch
        waitFor(decisions, 30).tap()
        sleep(4)
        control("/cut?seconds=15")
        let seen = watch(app, 13)
        screenshot("QA-008-h217-outage-banner")
        print("QA-008 H-217 banner after \(seen.banner.map { String(format: "%.1f", $0) } ?? "never") s")
        XCTAssertNotNil(seen.banner, "No banner during a 15 s outage")
        if let t = seen.banner { XCTAssertGreaterThanOrEqual(t, 6, "The banner came too early (\(t) s)") }
        // Back up: the banner leaves and the screen reloads.
        let gone = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                                   object: banner(app))], timeout: 40) == .completed
        screenshot("QA-008-h217-after-outage")
        XCTAssertTrue(gone, "The banner stayed after the outage ended")
        XCTAssertFalse(notConnected(app).exists, "'Not connected' stayed after reconnect")
    }

    /// Opened while down (fails), then reloads on its own after reconnect, without a pull.
    func testScreenOpenedDuringOutageReloadsAfterReconnect() {
        let app = launch(["-openProject", "The Hermes", "-openSegment", "team"])
        _ = team(app)
        sleep(2)
        control("/cut?seconds=12")
        sleep(1)
        app.pane("Releases").tap()
        sleep(3)
        screenshot("QA-008-h217-releases-during-outage")
        let release = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'iOS 0.5.0-q'")).firstMatch
        XCTAssertTrue(release.waitForExistence(timeout: 45), "Releases did not reload by itself after reconnect")
        screenshot("QA-008-h217-releases-reloaded")
    }

    /// Leave screens while reconnecting: navigation keeps responding.
    func testLeavingAScreenWhileReconnectingDoesNotFreeze() {
        let app = launch(["-openProject", "The Hermes", "-openSegment", "team"])
        let row = team(app)
        row.tap()
        _ = app.pane("Reports").waitForExistence(timeout: 10)
        control("/cut?seconds=15")
        sleep(2)
        // Leave the bot page, then the project, then switch tabs, all while down.
        let t0 = Date()
        app.navigationBars.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["The Hermes"].waitForExistence(timeout: 3), "Back from the bot page froze")
        app.navigationBars.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 3), "Back to Projects froze")
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.tabBars.buttons["Settings"].isSelected, "Tab switch froze")
        app.tabBars.buttons["Chat"].tap()
        XCTAssertTrue(app.tabBars.buttons["Chat"].waitForExistence(timeout: 3) && app.tabBars.buttons["Chat"].isSelected, "Tab switch froze")
        print("QA-008 H-217 navigation while down took \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        screenshot("QA-008-h217-navigated-while-down")
        // And it comes back.
        app.tabBars.buttons["Projects"].tap()
        sleep(16)
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertFalse(banner(app).waitForExistence(timeout: 1) && banner(app).label == "Disconnected", "Still disconnected after the outage")
    }
}
