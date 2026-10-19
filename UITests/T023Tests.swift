import XCTest

/// 0.23 on the demo world, the team on demand: the running counter and its
/// queue on a project's Team, Asleep and Waiting for a slot on the bots,
/// Wake now from the list, opening an asleep bot's chat waking it, Always on
/// and On demand in the bot's More pane, the computer's limits, and assigning
/// a card by role. They need a daemon with `team_on_demand_v1` (DEMO_DAEMON
/// built from flotilla's release-0.23.0) and skip on an older one.
///
/// The demo's POST /team puts Designer and QA Tester to sleep, takes every
/// running slot and has Tech Writer wait for one; POST /team/reset frees them.
final class T023Tests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
        if UIDevice.current.userInterfaceIdiom == .pad { throw XCTSkip("iPhone layout") }
        try requireLiveDaemon()
        let caps = (try DemoControl.post("/lab"))["caps"] as? [String] ?? []
        guard caps.contains("team_on_demand_v1") else { throw XCTSkip("The demo daemon predates 0.23 (no team_on_demand_v1)") }
    }

    override func tearDownWithError() throws {
        // Closed first: an app left on an asleep bot's chat would wake it again after the next seed.
        XCUIApplication().terminate()
        // Every later test sees the demo's bots running, as before 0.23.
        try DemoControl.post("/team/reset")
    }

    private func any(_ app: XCUIApplication, _ format: String, _ args: CVarArg...) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: format, argumentArray: args)).firstMatch
    }

    /// The seeded team, then Aurora Notes' Team.
    private func openTeam() throws -> (XCUIApplication, running: Int) {
        let seed = try DemoControl.post("/team")
        let running = try XCTUnwrap(seed["running"] as? Int)
        let app = try DemoApp.launch(["-openProject", "Aurora Notes", "-openSegment", "team"])
        allowSystemAlerts()
        waitFor(app.navigationBars["Aurora Notes"], 20)
        return (app, running)
    }

    func testTheCounterTheQueueAndRestingBots() throws {
        let (app, running) = try openTeam()
        let counter = waitFor(app.descendants(matching: .any)["team-running"], 20)
        XCTAssertTrue(counter.label.contains("\(running) of \(running) running · 1 waiting"), "the counter says \(counter.label)")
        let waiting = waitFor(app.descendants(matching: .any)["team-wake-Tech Writer"])
        XCTAssertTrue(waiting.label.contains("Message"), "why it waits: \(waiting.label)")
        XCTAssertTrue(waiting.label.contains("#1"), "its place: \(waiting.label)")
        XCTAssertTrue(app.botRow("Designer").label.contains("Asleep"), app.botRow("Designer").label)
        XCTAssertTrue(app.botRow("QA Tester").label.contains("Asleep"), app.botRow("QA Tester").label)
        XCTAssertTrue(app.botRow("Tech Writer").label.contains("Waiting for a slot"), app.botRow("Tech Writer").label)
        XCTAssertFalse(app.botRow("Designer").label.contains("Stopped"), "asleep is not stopped")
        screenshot("T023-team")
    }

    func testWakeNowFromTheListQueuesFirstWhenEverySlotIsTaken() throws {
        let (app, running) = try openTeam()
        waitFor(app.descendants(matching: .any)["team-running"], 20)
        let row = app.botRow("QA Tester")
        row.swipeRight()
        waitFor(app.buttons["Wake now"]).tap()
        // Every slot is taken: it waits, ahead of the Architect's message to Tech Writer.
        waitFor(any(app, "label BEGINSWITH %@", "QA Tester, ").firstMatch, 10)
        XCTAssertTrue(app.botRow("QA Tester").label.contains("Waiting for a slot"))
        // The counter and queue sit above the rows: back to the top.
        let counter = app.descendants(matching: .any)["team-running"]
        app.scroll(to: counter)
        waitFor(any(app, "label CONTAINS %@", "\(running) of \(running) running · 2 waiting"), 20)
        let woken = waitFor(app.descendants(matching: .any)["team-wake-QA Tester"])
        XCTAssertTrue(woken.label.contains("You woke it"), woken.label)
        XCTAssertTrue(woken.label.contains("#1"), woken.label)
        screenshot("T023-woken")
    }

    func testOpeningAnAsleepBotsChatWakesIt() throws {
        let (app, _) = try openTeam()
        let row = app.botRow("Designer")
        waitFor(row, 20).tap()
        let banner = waitFor(app.descendants(matching: .any)["bot-rest"], 15)
        XCTAssertTrue(banner.label.contains("Asleep") || any(app, "label BEGINSWITH 'Asleep.'").exists, "the banner says it sleeps")
        XCTAssertTrue(app.buttons["bot-wake"].exists, "Wake now in the banner")
        screenshot("T023-asleep-bot")
        // Reports don't wake it; its chat does, and with every slot taken it goes first in line.
        app.pane("Chat").tap()
        waitFor(any(app, "label CONTAINS %@", "Waiting for a slot · next in line"), 20)
        XCTAssertFalse(app.buttons["bot-wake"].exists, "already first: no Wake now")
        screenshot("T023-chat-woke")
    }

    func testAlwaysOnAndOnDemandInTheBotsMorePane() throws {
        let (app, _) = try openTeam()
        app.botRow("Designer").tap()
        app.pane("More").tap()
        // The segmented picker: its two segments are buttons.
        let onDemand = app.buttons["On demand"]
        app.scroll(to: onDemand)
        XCTAssertTrue(waitFor(onDemand).isSelected, "Designer is on demand")
        waitFor(app.buttons["bot-wake-now"])
        screenshot("T023-presence")
        app.buttons["Always on"].tap()
        waitFor(any(app, "label == %@", "Designer keeps running from now on."), 15)
        XCTAssertTrue(app.buttons["Always on"].isSelected)

        // The lead is always on, and says why.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.botRow("Architect").tap()
        app.pane("More").tap()
        let always = app.buttons["Always on"]
        app.scroll(to: always)
        XCTAssertTrue(waitFor(always).isSelected)
        XCTAssertFalse(app.buttons["On demand"].isEnabled, "a lead can't be on demand")
        XCTAssertTrue(any(app, "label BEGINSWITH %@", "The project's lead is always on").exists, "the reason shows")
        XCTAssertFalse(app.buttons["bot-sleep"].exists, "no Sleep now for the lead")
    }

    func testTheRunningCapInTheComputersSettings() throws {
        let seed = try DemoControl.post("/team")
        let running = try XCTUnwrap(seed["running"] as? Int)
        let app = try DemoApp.launch()
        allowSystemAlerts()
        app.tab("Settings")
        waitFor(app.buttons["Computers"]).tap()
        app.buttons.containing(NSPredicate(format: "label CONTAINS 'Demo Mac'")).firstMatch.tap()
        let counter = waitFor(app.descendants(matching: .any)["team-running"], 20)
        XCTAssertTrue(counter.label.contains("\(running) of \(running) running"), counter.label)
        let cap = app.steppers["team-max-running"]
        app.scroll(to: cap)
        XCTAssertTrue(cap.label.contains("Bots running at once: \(running)"), cap.label)
        // Decrement, then Increment.
        cap.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(cap.label.contains("Bots running at once: \(running + 1)"), cap.label)
        screenshot("T023-limits")
        let save = app.buttons["team-limits-save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        // The freed slot goes to Tech Writer: nobody waits any more.
        app.scroll(to: counter)
        waitFor(any(app, "label CONTAINS %@", "of \(running + 1) running"), 20)
        XCTAssertFalse(any(app, "label CONTAINS %@", "waiting").exists && counter.label.contains("waiting"), counter.label)
        app.scroll(to: save)
        XCTAssertFalse(save.isEnabled, "saved: nothing left to save")
    }

    func testAssigningACardToARole() throws {
        let app = try DemoApp.launch(["-openProject", "Flotilla Lab", "-openSegment", "board"])
        allowSystemAlerts()
        waitFor(app.navigationBars["Flotilla Lab"], 20)
        sleep(3) // board_watch creates the Lab board
        let seed = try DemoControl.post("/roles")
        XCTAssertEqual(seed["product"] as? String, "DevOps")
        let card = any(app, "label CONTAINS %@", "Shape the import flow")
        for chip in ["Inbox", "To do", "Ready", "Backlog"] where !card.exists {
            let button = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", chip)).firstMatch
            if button.exists { button.tap() }
            _ = card.waitForExistence(timeout: 4)
        }
        waitFor(card, 20).press(forDuration: 1.2)
        waitFor(app.buttons["Assign to…"]).tap()
        waitFor(app.buttons["Assign to role"]).tap()
        XCTAssertTrue(waitFor(app.buttons["Product · DevOps"]).exists, "who holds Product")
        screenshot("T023-assign-role")
        // Nobody holds Architect: refused, in the owner's words.
        waitFor(app.buttons["Architect · nobody yet"]).tap()
        let alert = waitFor(app.alerts["Couldn’t assign the card."], 15)
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@",
                                                               "Nobody in this project holds the Architect role yet.")).firstMatch.exists)
        screenshot("T023-role-unheld")
        alert.buttons["OK"].tap()
        // Product goes to DevOps, who holds it.
        waitFor(card).press(forDuration: 1.2)
        waitFor(app.buttons["Reassign…"].exists ? app.buttons["Reassign…"] : app.buttons["Assign to…"]).tap()
        waitFor(app.buttons["Assign to role"]).tap()
        waitFor(app.buttons["Product · DevOps"]).tap()
        waitFor(any(app, "label CONTAINS %@ AND label CONTAINS %@", "Shape the import flow", "DevOps"), 20)
    }
}
