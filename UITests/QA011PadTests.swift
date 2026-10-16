import XCTest

/// H-160 AC6 on iPad (UX-023 §2.7): ⌘1–5 pick a project segment, ⌘⇧N opens Needs you
/// (All projects with its Needs you filter on, since 0.20).
/// Pointer hover (H-207 AC1, the rows' hover effects) can't be driven by XCUITest on iOS.
/// Run on an iPad simulator: `SIMULATOR=Gravity-iOSQA-iPad scripts/ui-tests.sh -only-testing:UITests/QA011PadTests`.
final class QA011PadTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
        if UIDevice.current.userInterfaceIdiom != .pad { throw XCTSkip("iPad only") }
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    private func item(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
    }

    func testCommandNumberSegmentsAndCommandShiftN() throws {
        let app = try DemoApp.launch()
        allowSystemAlerts()
        waitFor(item(app, "Aurora Notes"), 20).tap()
        waitFor(app.buttons["Overview"].firstMatch, 10)
        // Each segment by what it shows in the demo: a segmented Picker doesn't expose
        // isSelected to XCUITest here, so the selection is read from the content.
        let segments: [(name: String, shows: String)] = [("Overview", "From the team"), ("Board", "Board on another computer"),
                                                        ("Team", "Architect"), ("Releases", "No releases yet"),
                                                        ("Meetings", "No meetings set up")]
        // From the last segment back to the first, so each shortcut changes the selection.
        for (index, segment) in segments.enumerated().reversed() {
            app.typeKey("\(index + 1)", modifierFlags: .command)
            XCTAssertTrue(item(app, segment.shows).waitForExistence(timeout: 8), "⌘\(index + 1) did not show \(segment.name)")
            screenshot("QA-011-cmd\(index + 1)-\(segment.name.lowercased())")
        }

        app.typeKey("n", modifierFlags: [.command, .shift])
        let shown = app.navigationBars["Projects"].firstMatch.waitForExistence(timeout: 5) && app.needsYouFilterIsOn
        XCTAssertTrue(shown, "⌘⇧N did not open Projects with the Needs you filter on")
        screenshot("QA-011-cmd-shift-n-needs-you")
        XCTAssertEqual(app.state, .runningForeground)
    }
}
