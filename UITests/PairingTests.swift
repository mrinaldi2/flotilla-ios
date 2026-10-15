import XCTest

/// H-010 and H-011: pairing from a pasted link, verified before it is saved, and a
/// flotilla:// link from outside the app that fills Connect without adding anything.
final class PairingTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func link(host: String = "127.0.0.1", port: String? = nil, token: String) -> String {
        let port = port ?? DemoApp.environment["GRAV_PORT"] ?? "49790"
        let token = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? token
        return "flotilla://pair?host=\(host)&port=\(port)&token=\(token)&name=Demo%20Mac&kind=mac"
    }

    /// iOS asks once before the app reads the clipboard.
    private func allowPaste(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for alerts in [app.alerts, springboard.alerts] {
            let allow = alerts.buttons["Allow Paste"]
            if allow.waitForExistence(timeout: 3) { allow.tap(); return }
        }
    }

    /// The real paste. Neither the runner's clipboard writes nor `simctl pbcopy` reach
    /// the app on the simulator (it reads nothing, with no paste prompt), so the link is
    /// copied inside the app: typed into the Address field, ⌘A, ⌘C, cleared;
    /// then Paste pairing link.
    private func launchAndPaste(_ text: String) -> XCUIApplication {
        let app = DemoApp.launchFirstRun()
        waitFor(app.navigationBars["Connect to Flotilla"])
        app.buttons["Enter manually"].tap()
        let field = waitFor(app.textFields["Address"])
        field.tap()
        field.typeText(text)
        // Select All and Copy with the simulator's hardware keyboard (no edit menu shows).
        field.typeKey("a", modifierFlags: .command)
        field.typeKey("c", modifierFlags: .command)
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        app.buttons["Enter manually"].tap() // folds the form away again
        waitFor(app.buttons["Paste pairing link"]).tap()
        allowPaste(app)
        return app
    }

    /// The app's Debug -pairLink: the same path as a paste or scan, without the clipboard.
    private func launchWithLink(_ text: String) -> XCUIApplication {
        XCUIApplication().terminate()
        return DemoApp.launchFirstRun(["-pairLink", text])
    }

    func testPasteLinkConnectingErrorsThenSuccess() throws {
        let token = try XCTUnwrap(DemoApp.token)

        // Pasted, with a wrong token: rejected, said next to the token field, nothing saved.
        var app = launchAndPaste(link(token: "not-the-token"))
        waitFor(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Token rejected'")).firstMatch)
        XCTAssertTrue(app.secureTextFields["Token"].exists, "The token field is not shown with the error")
        assertOnceBelow(app, "Token rejected", field: app.secureTextFields["Token"])
        XCTAssertFalse(app.tabBars.firstMatch.exists, "A rejected computer opened the app")
        screenshot("QA-004-pairing-bad-token")

        // Not a link: a warning, nothing tried.
        app = launchWithLink("hello there")
        waitFor(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'That isn’t a pairing link'")).firstMatch)
        screenshot("QA-004-pairing-not-a-link")

        // A service that never answers: Connecting… for the whole wait, then the address error.
        app = launchWithLink(link(host: "10.255.255.1", port: "49777", token: token))
        waitFor(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Connecting to Demo Mac'")).firstMatch, 5)
        screenshot("QA-004-pairing-connecting")
        waitFor(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Couldn’t reach 10.255.255.1:49777'")).firstMatch, 25)
        XCTAssertFalse(app.tabBars.firstMatch.exists, "An unreachable computer opened the app")
        assertOnceBelow(app, "Couldn’t reach", field: app.textFields["Address"])
        screenshot("QA-004-pairing-unreachable")

        // The right link: connected, saved, and the app opens on Home.
        app = launchWithLink(link(token: token))
        waitFor(app.tabBars.buttons["Projects"], 20)
        // After pairing, a word on notifications before iOS asks.
        let explainer = app.staticTexts["Get told when a bot needs you"]
        if explainer.waitForExistence(timeout: 5) {
            screenshot("QA-004-pairing-explainer")
            app.buttons["Not now"].tap()
        }
        waitFor(app.projectCard("Aurora Notes"), 20) // the paired computer's projects
        screenshot("QA-004-pairing-success")
    }

    func testOpenedLinkFillsConnectWithoutAdding() throws {
        let token = try XCTUnwrap(DemoApp.token)
        let app = DemoApp.launchFirstRun()
        waitFor(app.navigationBars["Connect to Flotilla"])
        open(link(token: token), in: app)
        waitFor(app.staticTexts["Opened from a pairing link. Check the computer and its address, then tap Connect."])
        XCTAssertEqual(app.textFields["Address"].value as? String, "127.0.0.1")
        XCTAssertEqual(app.textFields["Port"].value as? String, DemoApp.environment["GRAV_PORT"] ?? "49790")
        XCTAssertEqual(app.textFields["Name"].value as? String, "Demo Mac")
        screenshot("QA-004-deeplink-prefilled")
        // It waits for Connect: nothing is tried or added on its own.
        sleep(4)
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Connecting to'")).firstMatch.exists, "The link started connecting on its own")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "The link added the computer on its own")
        let connect = app.buttons["Connect"]
        app.scroll(to: connect)
        connect.tap()
        waitFor(app.tabBars.buttons["Projects"], 20)
    }

    func testOpenedLinkWithAComputerOpensAddSheet() throws {
        let token = try XCTUnwrap(DemoApp.token)
        let app = try DemoApp.launch()
        allowSystemAlerts()
        waitFor(app.tabBars.buttons["Projects"])
        open(link(token: token).replacingOccurrences(of: "Demo%20Mac", with: "Second%20Mac"), in: app)
        waitFor(app.navigationBars["Add a computer"])
        waitFor(app.staticTexts["Opened from a pairing link. Check the computer and its address, then tap Connect."])
        sleep(3)
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Connecting to'")).firstMatch.exists, "The link started connecting on its own")
        screenshot("QA-004-deeplink-add-sheet")
        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.buttons["Computer: Second Mac"].exists)
    }

    /// H-025: a pairing error is said once, under the field to fix.
    private func assertOnceBelow(_ app: XCUIApplication, _ start: String, field: XCUIElement,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let errors = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", start))
        XCTAssertEqual(errors.count, 1, "\"\(start)…\" is shown \(errors.count) times", file: file, line: line)
        guard let error = errors.allElementsBoundByIndex.first, field.exists else {
            return XCTFail("No \"\(start)…\" error with its field", file: file, line: line)
        }
        XCTAssertGreaterThan(error.frame.minY, field.frame.minY, "The error is not under its field", file: file, line: line)
    }

    /// The system's "Open in “Flotilla”?" is confirmed when it shows.
    private func open(_ link: String, in app: XCUIApplication) {
        app.open(URL(string: link)!)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 3) { open.tap() }
    }
}
