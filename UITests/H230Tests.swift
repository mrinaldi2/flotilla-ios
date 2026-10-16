import XCTest

/// H-230 on iPad: a route that switches the sidebar to All projects (Needs you filter) opens its screen in
/// the detail column (it was lost when pushed as the column first showed). No daemon:
/// the release comes from the Debug -releaseStub, and a decision route needs none.
final class H230Tests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        if UIDevice.current.userInterfaceIdiom != .pad { throw XCTSkip("iPad layout") }
    }

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        // In my port range, nothing listens: the screens open without a computer.
        app.launchArguments = ["-gravHost", "127.0.0.1", "-gravPort", "41209", "-lensPort", "41208",
                               "-gravToken", "none", "-noNotificationPrompt", "YES"] + extra
        app.launch()
        return app
    }

    func testTheReleaseStubOpensTheReleaseOnIPad() {
        // Bare JSON works as a launch argument now.
        let app = launch(["-releaseStub", #"{"release":{"id":"rel-qa","name":"0.6.2","display_version":"0.6.2","status":"approved","version":3}}"#,
                          "-installStub", #"{"install":{"release_id":"rel-qa","version":"0.6.2","build":"13","state":"approved","installable":true,"page_url":"https://mac.tail.ts.net:8443/releases/0.6.2/index.html","install_url":"itms-services://?action=download-manifest&url=https://mac.tail.ts.net:8443/releases/0.6.2/manifest.plist","computer":"Studio Mac"}}"#])
        XCTAssertTrue(app.navigationBars["0.6.2"].waitForExistence(timeout: 20), "The release did not open in the detail column")
        XCTAssertTrue(app.buttons["Install on this iPad"].waitForExistence(timeout: 10), "No install section")
        screenshot("H-230-ipad-release-stub")
    }

    func testADecisionRouteOpensOnIPad() {
        // The product path: a tapped decision notification switches to Projects, filtered, and pushes the decision.
        let app = launch(["-route", "decision/dec-qa"])
        XCTAssertTrue(app.navigationBars["Decision"].waitForExistence(timeout: 20), "The decision did not open in the detail column")
    }
}
