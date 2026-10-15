import XCTest

/// H-230 (UX-043/UX-047): the release screen's Install section in each state, with
/// STUBBED release and install data (Debug-only -releaseStub / -installStub, 333459a),
/// since the demo can't make a package with a published iOS build without owner powers.
/// The app's checks still run: InstallLink.isSafe, the HTTPS probe, the version compare.
/// This build is 0.6.1 (12). Runs on iPhone and iPad; captures are named by device.
final class QA013InstallStateTests: XCTestCase {
    static let page = "https://mac.tail.ts.net:8443/releases/0.6.2/index.html"
    static let link = "itms-services://?action=download-manifest&url=https://mac.tail.ts.net:8443/releases/0.6.2/manifest.plist"

    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]), as: UTF8.self)
    }

    private func release(_ status: String, name: String = "0.6.2") -> String {
        json(["release": ["id": "rel-qa", "name": name, "display_version": name, "status": status, "version": 3,
                          "changelog": "Install on this \(device) (H-230).",
                          "items": [["item_id": "H-230", "verdict": status == "approved" ? "approve" : "pending"]]]])
    }

    private func install(_ state: String, version: String = "0.6.2", build: String = "13", forTesting: Bool = false,
                         link: String = QA013InstallStateTests.link, site: Bool? = nil) -> String {
        var info: [String: Any] = ["release_id": "rel-qa", "version": version, "build": build, "state": state,
                                   "installable": true, "for_testing": forTesting, "page_url": Self.page,
                                   "install_url": link, "computer": "Studio Mac"]
        if let site { info["site"] = ["serving": site, "problem": site ? "" : "connection refused"] }
        return json(["install": info])
    }

    private func open(_ release: String, _ install: String) throws -> XCUIApplication {
        let app = try DemoApp.launch(["-releaseStub", release.asArgumentString, "-installStub", install.asArgumentString])
        allowSystemAlerts()
        return app
    }

    private func any(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func see(_ app: XCUIApplication, _ text: String, _ capture: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = any(app, text)
        if !element.waitForExistence(timeout: 20) { app.scroll(to: element) }
        XCTAssertTrue(element.exists, "\(capture): no “\(text)”", file: file, line: line)
        if element.exists { app.scroll(to: element) }
        screenshot("QA-013-\(capture)-STUB-\(device)")
    }

    /// #1 approved + published: the Install section. Then Install with the made-up
    /// tailnet host: #4, the Tailscale line, and nothing is opened.
    func testApprovedThenUnreachable() throws {
        let app = try open(release("approved"), install("approved"))
        see(app, "Install on this \(device)", "01-approved")
        XCTAssertTrue(any(app, "Opens the install page in Safari").exists, "No Safari footnote")
        XCTAssertTrue(any(app, "this device may not be in the build's profile").exists,
                      "No profile footnote")
        // #10: what VoiceOver reads for the button (XCUITest doesn't expose the hint;
        // ReleaseInstallTests.testTheExactCopy checks it).
        let button = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Install on this \(device)")).firstMatch
        XCTContext.runActivity(named: "VoiceOver label: \(button.label)") { _ in }
        print("QA-013 VoiceOver label: \(button.label)")
        button.tap()
        see(app, "Can't reach the build site from this \(device)", "04-unreachable")
        XCTAssertTrue(app.buttons["Try again"].exists, "No Try again")
        XCTAssertEqual(app.state, .runningForeground, "Something was opened")
    }

    /// #2 awaiting you: "… to test".
    func testAwaitingYouToTest() throws {
        let app = try open(release("awaiting_owner"), install("awaiting_owner", forTesting: true))
        see(app, "Install on this \(device) to test", "02-awaiting-to-test")
    }

    /// #3 site off: the button disabled and the not-serving line.
    func testSiteOff() throws {
        let app = try open(release("approved"), install("approved", site: false))
        see(app, "The build site on Studio Mac isn't serving", "03-site-off")
        let button = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Install on this \(device)")).firstMatch
        XCTAssertTrue(button.exists && !button.isEnabled, "The Install button isn't disabled with the site off")
    }

    /// #5 planned: no build yet (UX-047).
    func testPlannedHasNoBuild() throws {
        let app = try open(release("planned", name: "0.6.3"),
                           json(["install": ["release_id": "rel-qa", "version": "0.6.3", "state": "planned",
                                             "installable": false, "computer": "Studio Mac"]]))
        see(app, "This package has no iPhone or iPad build to install yet", "05-planned-no-build")
    }

    /// #6 the same version (0.6.1 (12)): ✓ and Reinstall; an older package on a newer
    /// device: "Install 0.6.1 anyway".
    func testSameVersionAndNewer() throws {
        let same = try open(release("deployed", name: "0.6.1"), install("deployed", version: "0.6.1", build: "12"))
        see(same, "✓ This \(device) has Flotilla 0.6.1 (12).", "06a-same-version")
        XCTAssertTrue(same.buttons["Reinstall"].exists, "No Reinstall")
        same.terminate()
        let older = try open(release("deployed", name: "0.6.1"), install("deployed", version: "0.6.1", build: "11"))
        see(older, "Install 0.6.1 anyway", "06b-newer-installed")
        XCTAssertTrue(any(older, "This \(device) has a newer version (0.6.1).").exists, "No newer-version line")
    }

    /// Extra: a link to another host is never offered (not published), and a rejected
    /// package has no install section.
    func testBadLinkAndRejected() throws {
        let bad = try open(release("approved"),
                           install("approved", link: "itms-services://?action=download-manifest&url=https://evil.example.com/manifest.plist"))
        see(bad, "This package has no iPhone or iPad build to install yet", "x1-bad-link")
        bad.terminate()
        let rejected = try open(release("rejected"), json(["install": ["release_id": "rel-qa", "version": "0.6.2", "build": "13",
                                                                        "state": "rejected", "installable": false]]))
        XCTAssertTrue(any(rejected, "Install on this").waitForNonExistence(timeout: 10))
        sleep(3)
        XCTAssertFalse(any(rejected, "Install on this").exists, "A rejected package shows Install")
        screenshot("QA-013-x2-rejected-no-section-STUB-\(device)")
    }
}

extension String {
    /// A launch-argument value the argument domain keeps as this exact string: a bare
    /// `{…}` is read as an old-style property list (JSON isn't one) and comes back nil,
    /// so the JSON goes in as a quoted plist string.
    var asArgumentString: String {
        "\"" + replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
