import XCTest

/// H-230 (UX-043/UX-047) captures on the demo world, with STUBBED install data:
/// the demo can't make a package with a published iOS build without owner powers
/// (board start, DevOps role, approval, a paired device), so the app's Debug-only
/// -installStub / -installOfferStub (a53c46b) stand in for the daemon's replies.
/// Everything else is real: the reachability probe, InstallLink.isSafe, the copy.
final class QA013InstallTests: XCTestCase {
    /// A made-up tailnet host: the HEAD probe fails, which is the unreachable state.
    static let page = "https://mac.tail.ts.net:8443/releases/0.6.2/index.html"
    static let link = "itms-services://?action=download-manifest&url=https://mac.tail.ts.net:8443/releases/0.6.2/manifest.plist"

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func any(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func offerStub() throws -> String {
        let project = try XCTUnwrap(DemoApp.environment["DEMO_PROJECT_ID"].flatMap { $0.isEmpty ? nil : $0 },
                                    "No DEMO_PROJECT_ID: run scripts/ui-tests.sh")
        let offer: [String: Any] = ["release_id": "r1", "project_id": project, "device_id": "d1", "device_name": "iPhone",
                                    "version": "0.6.2", "build": "13", "install_url": Self.link, "page_url": Self.page,
                                    "title": "Flotilla 0.6.2 (13) is ready to install",
                                    "body": "Approved on 8 Oct 2026. Tap to install."]
        let data = try JSONSerialization.data(withJSONObject: ["offers": [offer]], options: [.withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// UX-047 #7 (STUBBED offer): the banner on Needs you and on the project's Releases;
    /// Install from it with the site unreachable says so and opens nothing (#4); Not now hides it.
    func testOfferBannerOnNeedsYouAndReleases() throws {
        let app = try DemoApp.launch(["-installOfferStub", try offerStub().asArgumentString])
        allowSystemAlerts()
        app.tab("Needs you")
        let banner = any(app, "Flotilla 0.6.2 is ready to install")
        XCTAssertTrue(banner.waitForExistence(timeout: 40), "No offer banner on Needs you")
        screenshot("QA-013-07-STUB-offer-banner-needs-you")

        app.openProject("Aurora Notes")
        app.pane("Releases").tap()
        XCTAssertTrue(banner.waitForExistence(timeout: 15), "No offer banner on the project's Releases")
        screenshot("QA-013-07-STUB-offer-banner-releases")

        // #10: the Install button as VoiceOver reads it (the hint isn't exposed to XCUITest).
        let install = app.buttons["Install"].firstMatch
        XCTAssertTrue(install.exists, "No Install button on the banner")
        XCTContext.runActivity(named: "Install button label: \(install.label)") { _ in }

        // #4: the build site can't be reached from here: the Tailscale line, Try again, Safari not opened.
        install.tap()
        let unreachable = any(app, "Can't reach the build site from this iPhone. Turn on Tailscale, then try again.")
        let plain = any(app, "Can't reach the build site from this iPhone")
        XCTAssertTrue(unreachable.waitForExistence(timeout: 15) || plain.exists, "No unreachable line after Install")
        XCTAssertTrue(app.buttons["Try again"].firstMatch.exists, "No Try again")
        XCTAssertEqual(app.state, .runningForeground, "The app left the foreground: something was opened")
        screenshot("QA-013-04-STUB-unreachable-from-banner")

        // Not now: the banner goes.
        app.buttons["Not now"].firstMatch.tap()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 8), "Not now left the banner")
        screenshot("QA-013-07-STUB-not-now")
    }

    /// UX-047 #8: "Updated to Flotilla 0.6.1." once after an update (145df7e: it waits
    /// until the UI is drawn, then stays 4 s). The relaunch goes without the argument:
    /// the argument domain would override the stored value.
    func testUpdatedToastOnceAfterAnUpdate() throws {
        if UIDevice.current.userInterfaceIdiom == .pad { throw XCTSkip("iPhone capture") }
        let app = try DemoApp.launch(["-lastLaunchedVersion", "0.6.0 (11)".asArgumentString, "-noNotificationPrompt", "YES"])
        let toast = any(app, "Updated to Flotilla 0.6.1.")
        XCTAssertTrue(toast.waitForExistence(timeout: 10), "No 'Updated to Flotilla 0.6.1.' toast after an update")
        screenshot("QA-013-08-updated-toast")
        allowSystemAlerts()
        XCTAssertTrue(toast.waitForNonExistence(timeout: 10), "The toast stayed")
        app.terminate()

        let again = try DemoApp.launch(["-noNotificationPrompt", "YES"])
        allowSystemAlerts()
        XCTAssertFalse(any(again, "Updated to Flotilla").waitForExistence(timeout: 8), "The toast showed again")
        screenshot("QA-013-08-no-toast-on-relaunch")
    }
}
