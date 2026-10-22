import XCTest

/// R1-I1: the display name is "Flotilla", and the main screens use the glossary's
/// words, with none of the retired ones.
final class GlossaryTests: XCTestCase {
    /// Words the glossary retired, as they would show on screen. Bare "Hermes" is
    /// not one: a daemon from before the rename signs its own notes with it.
    static let retired = ["Gravity", "gravityd", "GravitiOS", "The Hermes", "Hermes service", "hermesd", "Permission prompts", "Waiting on you",
                          "Answer and publish", "Hold for later", "Restart session", "Clear chat",
                          "Runtime", "Grants", "Delivery backlog", "Auth failed",
                          "Version mismatch", "Something went wrong", "Retry", "Between bots",
                          "Charter", "Standing instructions", "Note from Gravity", "Allow for this session",
                          "decisions waiting", "decision waiting"]
    /// Allowed although they contain a retired word: the About attribution.
    static let allowed = ["Based on Gravity by"]

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        try DemoControl.ensurePermissionPrompts() // "Allow for session" is on their cards
        app = try DemoApp.launch()
        allowSystemAlerts()
        waitFor(app.tabBars.buttons["Projects"])
    }

    func testDisplayName() {
        XCTAssertEqual(app.label, "Flotilla")
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let icon = springboard.icons["Flotilla"]
        XCTAssertTrue(icon.waitForExistence(timeout: 5), "No home-screen icon named Flotilla")
        screenshot("QA-004-display-name")
        app.activate()
    }

    func testMainScreensUseTheGlossary() {
        var seen: Set<String> = []
        func look(_ screen: String) {
            sleep(1)
            let words = app.visibleWords
            seen.formUnion(words)
            for word in words {
                let text = Self.allowed.reduce(word) { $0.replacingOccurrences(of: $1, with: "") }
                for old in Self.retired where text.range(of: "\\b\(old)\\b", options: .regularExpression) != nil {
                    XCTFail("\(screen): retired word \"\(old)\" in \"\(word)\"")
                }
            }
            screenshot("QA-004-glossary-\(screen)")
        }

        look("projects")
        app.tab("Projects")
        waitFor(app.projectCard("Aurora Notes"))
        app.openProject("Aurora Notes")
        look("project-overview")
        app.pane("Team").tap()
        look("project-team")
        waitFor(app.botRow("Architect")).tap()
        for pane in ["Reports", "Chat", "Terminal", "More"] {
            XCTAssertTrue(waitFor(app.pane(pane)).exists, "Pane \(pane)")
        }
        look("bot-reports")
        app.pane("More").tap()
        app.scroll(to: app.buttons["Clear conversation"])
        XCTAssertTrue(app.buttons["Restart bot"].exists)
        XCTAssertTrue(app.buttons["Clear conversation"].exists)
        look("bot-more")

        app.tab("Commands")
        look("commands")
        app.tab("Settings")
        look("settings")
        waitFor(app.buttons["Computers"]).tap()
        look("computers")
        app.buttons.containing(NSPredicate(format: "label CONTAINS 'Demo Mac'")).firstMatch.tap()
        sleep(2)
        look("computer")
        let service = app.labelled("Flotilla service")
        app.scroll(to: service)
        look("computer-service")

        // Needs you and Decisions last: the Decisions sheet is the end of the walk.
        app.needsYou()
        waitFor(app.needsRow("Resolve conflicts automatically or always ask?"))
        look("needs-you")
        app.openDecisions()
        waitFor(app.staticTexts["Permission requests"])
        look("decisions")
        app.needsYou()
        waitFor(app.needsRow("Resolve conflicts automatically or always ask?")).tap()
        waitFor(app.navigationBars["Decision"])
        app.scroll(to: app.buttons["Put on hold"])
        XCTAssertTrue(app.buttons["Publish ruling"].exists)
        XCTAssertTrue(app.buttons["Put on hold"].exists)
        look("decision-detail")

        XCTAssertTrue(seen.contains { $0.contains("Flotilla service") }, "\"Flotilla service\" not on the computer page")
        XCTAssertTrue(seen.contains("Allow for session"), "No Allow for session answer on a permission card")
        XCTAssertTrue(seen.contains { $0.hasPrefix("Needs you") || $0.contains("need you") || $0.contains("needs you") },
                      "\"Needs you\" not on the main screens")
    }
}
