import XCTest

/// The app pointed at the demo world (`demo/make_demo.py`), through the Debug-only
/// launch arguments in `Computers.debugComputers()`. `scripts/ui-tests.sh` starts the
/// demo and passes its token as `TEST_RUNNER_GRAV_TOKEN`; without it the token is read
/// from the demo folder, so the tests also run from Xcode while the demo is serving.
enum DemoApp {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static var token: String? {
        if let token = environment["GRAV_TOKEN"], !token.isEmpty { return token }
        let path = (environment["GRAV_DEMO_DIR"] ?? "/tmp/flotilla-demo") + "/gravity/secrets/client.token"
        return (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var decisionId: String? { environment["DEMO_DECISION_ID"].flatMap { $0.isEmpty ? nil : $0 } }
    static var botId: String? { environment["DEMO_BOT_ID"].flatMap { $0.isEmpty ? nil : $0 } }

    /// The app with no computer: no demo arguments, and an empty saved list
    /// (the argument domain hides what an earlier pairing saved).
    static func launchFirstRun(_ extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.appearance = .light
        let app = XCUIApplication()
        app.launchArguments = ["-computers", "<>", "-selectedComputer", ""] + extra
        app.launch()
        return app
    }

    /// `port`: another port for the same computer (a closed one shows what the app cached).
    static func launch(_ extra: [String] = [], dark: Bool = false, port: String? = nil) throws -> XCUIApplication {
        let token = try XCTUnwrap(token, "No demo token: run scripts/ui-tests.sh, or start `python3 demo/make_demo.py --serve --peer-port 49791`")
        let app = XCUIApplication()
        app.launchArguments = ["-gravHost", "127.0.0.1", "-gravPort", port ?? environment["GRAV_PORT"] ?? "49790",
                               "-lensPort", environment["LENS_PORT"] ?? "49788", "-gravToken", token] + extra
        // A freshly erased simulator can ignore the first appearance change, which
        // once let "dark" checks measure light mode: the screen must show it.
        // Light is the erased simulator's own state; only a dark request is checked
        // (an iPad's split view can read as dark to this rough measure).
        for _ in 0..<3 {
            XCUIDevice.shared.appearance = dark ? .dark : .light
            app.launch()
            if !dark { return app }
            sleep(2)
            if isDark(app) { return app }
            app.terminate()
            sleep(1)
        }
        XCTFail("The simulator would not switch to \(dark ? "dark" : "light") mode")
        return app
    }

    /// The screen's most common colour is dark.
    static func isDark(_ app: XCUIApplication) -> Bool {
        Contrast(of: app).background.luminance < 0.2
    }
}

extension XCTestCase {
    /// The notifications prompt the app asks for on first launch.
    func allowSystemAlerts() {
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Allow", "Don’t Allow"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
    }

    /// Kept in the result bundle, and written as `<name>.png` to `SCREENSHOT_DIR` when set.
    func screenshot(_ name: String, of element: XCUIScreenshotProviding = XCUIScreen.main) {
        let shot = element.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = DemoApp.environment["SCREENSHOT_DIR"], !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    /// Waits for `element`; when it never comes, the screen and its element tree go in the report.
    @discardableResult
    func waitFor(_ element: XCUIElement, _ timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        if !element.waitForExistence(timeout: timeout) {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "missing element"
            shot.lifetime = .keepAlways
            add(shot)
            let tree = XCTAttachment(string: XCUIApplication().debugDescription)
            tree.name = "element tree"
            tree.lifetime = .keepAlways
            add(tree)
            XCTFail("Missing: \(element)", file: file, line: line)
        }
        return element
    }
}

extension XCUIApplication {
    /// Taps a tab; from a pushed screen, whose tab bar can be hidden, goes back first.
    func tab(_ name: String) {
        var tries = 0
        while !(tabBars.buttons[name].exists && tabBars.buttons[name].isHittable), tries < 4 {
            // Only a real back button: the first bar button can be an action (Needs you's Decisions).
            let back = navigationBars.buttons["BackButton"].firstMatch
            if back.exists && back.isHittable {
                // The edge swipe goes back too, and can't fail on a button that just went away.
                coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
                    .press(forDuration: 0.05, thenDragTo: coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
            } else {
                // A sheet (Needs you's Decisions) covers the bar: swipe it away first.
                swipeDown(velocity: .fast)
            }
            tries += 1
        }
        tabBars.buttons[name].tap()
    }

    // MARK: H-134 navigation: Projects · Needs you · Chat · Settings

    /// A card on Projects: "Rank 1, Aurora Notes, …" or "Nothing needs you, calm, …".
    func projectCard(_ name: String) -> XCUIElement {
        buttons.matching(NSPredicate(format: "label CONTAINS %@", ", \(name), ")).firstMatch
    }

    /// The project's screen, from its card on Projects.
    func openProject(_ name: String) {
        tab("Projects")
        let card = projectCard(name)
        _ = card.waitForExistence(timeout: 10)
        scroll(to: card)
        card.tap()
        _ = navigationBars[name].waitForExistence(timeout: 10)
    }

    /// A button by its exact label that is on the screen itself, not in the tab bar
    /// (a bot's Chat pane and the Chat tab share the word).
    func pane(_ name: String) -> XCUIElement {
        // The tab bar can be hidden on a pushed screen and still be in the tree.
        let tab = tabBars.buttons[name]
        let tabFrame = tab.exists ? tab.frame : nil
        let matches = buttons.matching(NSPredicate(format: "label == %@", name))
        // H-160 AC6 adds hidden ⌘1–5 buttons named like the segments, below them: take the topmost.
        return matches.allElementsBoundByIndex.filter { $0.frame != tabFrame }.min { $0.frame.minY < $1.frame.minY }
            ?? matches.firstMatch
    }

    /// A bot's page, through its project's Team.
    func openBot(_ name: String, in project: String = "Aurora Notes") {
        openProject(project)
        pane("Team").tap()
        let row = botRow(name)
        _ = row.waitForExistence(timeout: 10)
        row.tap()
        _ = pane("Reports").waitForExistence(timeout: 10)
    }

    /// Needs you → Decisions: decisions and the permission cards.
    func openDecisions() {
        tab("Needs you")
        let decisions = navigationBars.buttons["Decisions"]
        _ = decisions.waitForExistence(timeout: 10)
        decisions.tap()
    }

    /// A row on Needs you, by the start of its title.
    func needsRow(_ title: String) -> XCUIElement {
        let row = buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        scroll(to: row)
        return row
    }

    /// A bot's row in a project's Team (or any bot list), scrolled into view.
    func botRow(_ name: String) -> XCUIElement {
        let row = buttons.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "\(name), ", "Unread, \(name), ")).firstMatch
        scroll(to: row)
        return row
    }

    /// Any element whose label is `label`: combined rows are not always StaticText.
    func labelled(_ label: String) -> XCUIElement {
        descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// Scrolls the current list until `element` is hittable: down first, then back up.
    func scroll(to element: XCUIElement, max: Int = 10) {
        var tries = 0
        while !(element.exists && element.isHittable), tries < max {
            swipeUp()
            tries += 1
        }
        tries = 0
        while !(element.exists && element.isHittable), tries < max {
            swipeDown()
            tries += 1
        }
    }

    /// Every label and value on screen, from the element tree (fast, unlike querying each element).
    var visibleWords: [String] {
        let tree = debugDescription
        let pattern = try! NSRegularExpression(pattern: "(?:label|value|identifier): '([^']*)'")
        return pattern.matches(in: tree, range: NSRange(tree.startIndex..., in: tree)).compactMap {
            Range($0.range(at: 1), in: tree).map { String(tree[$0]) }
        }
    }
}

/// The demo's control endpoint (make_demo.py --control-port, which scripts/ui-tests.sh
/// starts): each test asks for the demo state it needs instead of relying on what
/// earlier tests left behind.
enum DemoControl {
    static var port: String? { DemoApp.environment["DEMO_CONTROL_PORT"].flatMap { $0.isEmpty ? nil : $0 } }

    @discardableResult
    static func post(_ path: String) throws -> [String: Any] {
        let port = try XCTUnwrap(port, "No DEMO_CONTROL_PORT: run scripts/ui-tests.sh")
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        var result: Result<[String: Any], Error> = .failure(URLError(.timedOut))
        // The endpoint comes up just after the demo says it serves: a few tries.
        for _ in 0..<5 {
            let done = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    result = .failure(error)
                } else if (response as? HTTPURLResponse)?.statusCode != 200 {
                    result = .failure(URLError(.badServerResponse))
                } else {
                    result = .success((try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any] ?? [:])
                }
                done.signal()
            }.resume()
            done.wait()
            if case .success = result { break }
            sleep(1)
        }
        return try result.get()
    }

    /// The demo's 3 permission prompts are pending (re-asked when an earlier test used them up).
    static func ensurePermissionPrompts() throws {
        let reply = try post("/permissions")
        XCTAssertEqual(reply["pending"] as? Int, 3, "The demo could not raise its 3 permission prompts")
    }

    /// `bot` waits on a permission prompt in its own terminal (approval_pending).
    static func approval(bot: String) throws {
        try post("/approval?bot=\(bot.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)")
    }
}
