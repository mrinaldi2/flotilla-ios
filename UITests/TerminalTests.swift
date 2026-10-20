import XCTest

/// A bot's terminal is a real terminal on the phone: colours and cursor
/// movement drawn as the desktop's xterm.js draws them, typing straight into
/// it with the terminal's keys above the keyboard, and the pty sized to the
/// screen. The demo's double runtime echoes what is typed into a bot's
/// terminal and prints `[resize CxR]` for each size it is given, so both are
/// checked against the daemon itself.
final class TerminalTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        if UIDevice.current.userInterfaceIdiom == .pad { throw XCTSkip("iPhone layout") }
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    /// `asPhone`: as the demo's paired phone, which may type (the owner token may not).
    private func openTerminal(_ bot: String = "iOS Dev", asPhone: Bool = true) throws -> (XCUIApplication, XCUIElement) {
        let app = try DemoApp.launch(asPhone: asPhone)
        allowSystemAlerts()
        app.openBot(bot)
        app.pane("Terminal").tap()
        let terminal = waitFor(app.descendants(matching: .any)["bot-terminal"], 20)
        // Attached, replayed and sized: the forced resize after an attach reaches the double.
        XCTAssertTrue(screen(of: terminal, contains: "[resize "), "nothing drawn: \(text(terminal))")
        return (app, terminal)
    }

    private func text(_ terminal: XCUIElement) -> String { terminal.value as? String ?? "" }

    /// The terminal shows `wanted` within `timeout` seconds, wherever its rows wrap.
    private func screen(of terminal: XCUIElement, contains wanted: String, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if text(terminal).replacingOccurrences(of: "\n", with: "").contains(wanted) { return true }
            usleep(250_000)
        } while Date() < deadline
        return false
    }

    func testColouredOutputIsDrawnLikeATerminal() throws {
        let (_, terminal) = try openTerminal()
        let lines = try XCTUnwrap(DemoControl.post("/colours?bot=iOS%20Dev")["lines"] as? [String])
        for line in lines {
            XCTAssertTrue(screen(of: terminal, contains: line), "\(line) is not on screen: \(text(terminal))")
        }
        let shown = text(terminal)
        XCTAssertFalse(shown.contains("[31m") || shown.contains("[0m"), "escape codes drawn as text: \(shown)")
        // Rewritten in place: a carriage return and an erase took the first text away.
        XCTAssertFalse(shown.contains("loading"), "the line was not rewritten in place: \(shown)")

        sleep(1)
        let pixels = Pixels(terminal.screenshot().image)
        XCTAssertGreaterThan(pixels.count { $0.r > 0.6 && $0.g < 0.4 && $0.b < 0.4 }, 30, "no red text")
        XCTAssertGreaterThan(pixels.count { $0.g > 0.6 && $0.r < 0.45 && $0.b < 0.5 }, 30, "no green text")
        XCTAssertGreaterThan(pixels.count { $0.r > 0.6 && $0.g > 0.6 && $0.b < 0.35 }, 30, "no yellow text")
        screenshot("TERM-colours")
    }

    func testTypingGoesStraightIntoTheBotsTerminal() throws {
        let (app, terminal) = try openTerminal()
        XCTAssertFalse(app.textViews["Message the bot's terminal"].exists, "a separate compose box")
        XCTAssertFalse(app.textFields["Message the bot's terminal"].exists, "a separate compose box")

        waitFor(app.buttons["terminal-type"]).tap()
        // The keys a terminal needs, above the keyboard.
        for key in ["esc", "ctrl", "tab", "left", "up", "down", "right"] {
            waitFor(app.buttons["terminal-key-\(key)"], 5)
        }
        app.typeText("echo from the phone")
        XCTAssertTrue(screen(of: terminal, contains: "echo from the phone"), "typing never reached the bot: \(text(terminal))")

        // ← from the key row moves the bot's cursor back over the last letter,
        // and what is typed next draws over it.
        app.typeText(" ab")
        app.buttons["terminal-key-left"].tap()
        app.typeText("X")
        XCTAssertTrue(screen(of: terminal, contains: "echo from the phone aX"), "the arrow key did not move the cursor: \(text(terminal))")
        screenshot("TERM-typing")

        app.buttons["terminal-key-hide"].tap()
        waitFor(app.buttons["terminal-type"], 5)
    }

    func testTheOwnerTokenIsToldItCannotType() throws {
        // The demo's owner token reads and runs the fleet but never types into a
        // bot: the daemon refuses, and the terminal says so instead of eating keys.
        let (app, _) = try openTerminal(asPhone: false)
        waitFor(app.buttons["terminal-type"]).tap()
        waitFor(app.buttons["terminal-key-esc"], 5)
        app.typeText("x")
        let note = waitFor(app.descendants(matching: .any)["terminal-note"], 10)
        XCTAssertTrue(note.label.contains("paired device"), "the daemon's refusal: \(note.label)")
        XCTAssertFalse(app.buttons["terminal-key-esc"].exists, "the keyboard stayed up after the refusal")
        XCTAssertFalse(app.buttons["terminal-type"].exists, "still offers typing")
        screenshot("TERM-owner-token")
    }

    func testThePtyFollowsTheScreenWhenTurned() throws {
        let (_, terminal) = try openTerminal()
        let portrait = try XCTUnwrap(lastSize(terminal), "no size sent: \(text(terminal))")
        XCUIDevice.shared.orientation = .landscapeLeft
        let deadline = Date().addingTimeInterval(10)
        var landscape = portrait
        while landscape.cols <= portrait.cols, Date() < deadline {
            usleep(300_000)
            landscape = lastSize(terminal) ?? portrait
        }
        XCTAssertGreaterThan(landscape.cols, portrait.cols, "turning the phone kept \(portrait.cols) columns")
        XCTAssertLessThan(landscape.rows, portrait.rows, "turning the phone kept \(portrait.rows) rows")
        screenshot("TERM-landscape")
    }

    /// The last `[resize CxR]` the double printed.
    private func lastSize(_ terminal: XCUIElement) -> (cols: Int, rows: Int)? {
        let shown = text(terminal)
        guard let match = shown.matches(of: /\[resize (\d+)x(\d+)\]/).last,
              let cols = Int(match.1), let rows = Int(match.2) else { return nil }
        return (cols, rows)
    }

    func testAnAsleepBotOffersWakeNowInsteadOfAnEmptyScreen() throws {
        try requireLiveDaemon()
        let caps = (try DemoControl.post("/lab"))["caps"] as? [String] ?? []
        guard caps.contains("team_on_demand_v1") else { throw XCTSkip("The demo daemon predates 0.23 (no team_on_demand_v1)") }
        // Designer asleep and every slot taken: opening its terminal wakes it,
        // and it waits for a slot, so it still has no terminal to show.
        try DemoControl.post("/team")
        defer {
            XCUIApplication().terminate()
            _ = try? DemoControl.post("/team/reset")
        }
        let app = try DemoApp.launch(["-openProject", "Aurora Notes", "-openSegment", "team"])
        allowSystemAlerts()
        waitFor(app.botRow("Designer"), 20).tap()
        waitFor(app.pane("Terminal")).tap()
        let asleep = waitFor(app.descendants(matching: .any)["terminal-asleep"], 10)
        XCTAssertTrue(asleep.exists)
        XCTAssertFalse(app.descendants(matching: .any)["bot-terminal"].exists, "an empty terminal for a bot that has none")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'has no terminal while it sleeps'")).firstMatch.exists,
                      "why there is no terminal")
        // What the banner says (asleep, or waiting for a slot) shows once: in the terminal's place.
        let banner = NSPredicate(format: "label BEGINSWITH 'Asleep. It wakes' OR label BEGINSWITH 'Waiting for a slot ·'")
        XCTAssertEqual(app.staticTexts.matching(banner).count, 1, "the rest banner shown twice, or not at all")
        screenshot("TERM-asleep")
    }
}

/// An image's pixels as 0…1 components.
private struct Pixels {
    struct RGB { let r: Double, g: Double, b: Double }
    private var data: [UInt8] = []

    init(_ image: UIImage) {
        guard let cg = image.cgImage else { return }
        let (width, height) = (cg.width, cg.height)
        data = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func count(where match: (RGB) -> Bool) -> Int {
        stride(from: 0, to: data.count, by: 4).reduce(0) { total, i in
            let pixel = RGB(r: Double(data[i]) / 255, g: Double(data[i + 1]) / 255, b: Double(data[i + 2]) / 255)
            return total + (match(pixel) ? 1 : 0)
        }
    }
}
