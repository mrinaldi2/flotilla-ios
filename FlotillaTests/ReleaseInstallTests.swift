import SwiftUI
import XCTest
@testable import Flotilla

/// H-230 (UX-043 iOS part): install an approved iOS release on this device, the
/// waiting-offer banner, and the version this device reports.
@MainActor
final class ReleaseInstallTests: XCTestCase {
    private func info(state: String = "approved", installable: Bool = true, version: String = "0.6.1",
                      build: String = "12", installURL: String? = "itms-services://?action=download-manifest&url=https://mac.tail.ts.net:8443/releases/0.6.1/manifest.plist",
                      pageURL: String? = "https://mac.tail.ts.net:8443/releases/0.6.1/index.html",
                      forTesting: Bool = false, serving: Bool? = nil) -> ReleaseInstallInfo {
        var d: JSONDict = ["release_id": "r1", "version": version, "build": build, "state": state,
                           "installable": installable, "for_testing": forTesting, "computer": "Studio Mac"]
        if let installURL { d["install_url"] = installURL }
        if let pageURL { d["page_url"] = pageURL }
        if let serving { d["site"] = ["serving": serving] as JSONDict }
        return ReleaseInstallInfo(d)
    }

    private let older = (version: "0.6.0", build: "11")

    // MARK: §1, §4 states

    func testWhenTheInstallActionsShow() {
        XCTAssertEqual(InstallState.of(info(), installed: older), .ready(forTesting: false), "approved, published")
        XCTAssertEqual(InstallState.of(info(state: "deploying"), installed: older), .ready(forTesting: false))
        XCTAssertEqual(InstallState.of(info(state: "awaiting_owner", forTesting: true), installed: older), .ready(forTesting: true))
        XCTAssertEqual(InstallState.of(info(state: "deployed"), installed: older), .ready(forTesting: false), "a second device")
        XCTAssertEqual(InstallState.of(info(state: "built", installable: false, installURL: nil), installed: older), .notPublished)
        XCTAssertEqual(InstallState.of(info(state: "planned", installable: false), installed: older), .notPublished)
        for state in ["rejected", "held", "cancelled"] {
            XCTAssertEqual(InstallState.of(info(state: state, installable: false), installed: older), .hidden, state)
        }
        // Install info the daemon couldn't derive is empty (CE M1).
        XCTAssertEqual(InstallState.of(info(installURL: nil), installed: older), .notPublished)
        XCTAssertEqual(InstallState.of(info(serving: false), installed: older), .siteOff(computer: "Studio Mac"))
    }

    func testSameAndNewerVersions() {
        XCTAssertEqual(InstallState.of(info(), installed: ("0.6.1", "12")), .sameVersion)
        XCTAssertEqual(InstallState.of(info(), installed: ("0.6.2", "1")), .newerInstalled("0.6.2"))
        XCTAssertEqual(InstallState.of(info(), installed: ("0.6.1", "13")), .newerInstalled("0.6.1"), "a later build")
        XCTAssertEqual(InstallState.of(info(version: "0.10.0"), installed: ("0.9.0", "50")), .ready(forTesting: false),
                       "versions compare by number")
    }

    func testTheExactCopy() {
        XCTAssertEqual(InstallWords.button(device: "iPhone", forTesting: false), "Install on this iPhone")
        XCTAssertEqual(InstallWords.button(device: "iPad", forTesting: false), "Install on this iPad")
        XCTAssertEqual(InstallWords.button(device: "iPhone", forTesting: true), "Install on this iPhone to test")
        XCTAssertEqual(InstallWords.opensSafari, "Opens the install page in Safari. Flotilla closes while it updates.")
        XCTAssertEqual(InstallWords.hint("0.6.1"), "Opens Safari to install Flotilla 0.6.1.")
        XCTAssertEqual(InstallWords.siteOff(computer: "Studio Mac"),
                       "The build site on Studio Mac isn't serving. Ask DevOps to start it, then try again.")
        XCTAssertEqual(InstallWords.notPublished,
                       "This package has no iPhone or iPad build to install yet. DevOps publishes it after building.")
        XCTAssertEqual(InstallWords.sameVersion(device: "iPhone", version: "0.6.1", build: "12"),
                       "✓ This iPhone has Flotilla 0.6.1 (12).")
        XCTAssertEqual(InstallWords.reinstall, "Reinstall")
        XCTAssertEqual(InstallWords.newer(device: "iPhone", version: "0.6.2"), "This iPhone has a newer version (0.6.2).")
        XCTAssertEqual(InstallWords.anyway("0.6.1"), "Install 0.6.1 anyway")
        XCTAssertEqual(InstallWords.unreachable(device: "iPhone"),
                       "Can't reach the build site from this iPhone. Turn on Tailscale, then try again.")
        XCTAssertEqual(InstallWords.profile,
                       "If iOS says it can't install, this device may not be in the build's profile. Ask DevOps.")
        XCTAssertEqual(InstallWords.banner("0.6.1"), "Flotilla 0.6.1 is ready to install")
        XCTAssertEqual(InstallWords.updated("0.6.1"), "Updated to Flotilla 0.6.1.")
    }

    // MARK: test 6: the button opens install_url

    func testInstallOpensTheDaemonsInstallURL() async {
        let package = info()
        var opened: [URL] = []
        var checked: [URL] = []
        let outcome = await InstallAction.install(package, reachable: { checked.append($0); return true }) { opened.append($0) }
        XCTAssertEqual(opened, [package.installURL!], "the itms-services link, as the daemon gave it")
        XCTAssertEqual(checked, [package.pageURL!], "the page is checked first")
        XCTAssertEqual(outcome, .opened(package.installURL!))
    }

    // MARK: test 8: unreachable → Tailscale copy, no Safari

    func testAnUnreachableSiteNeverOpensSafari() async {
        var opened: [URL] = []
        let outcome = await InstallAction.install(info(), reachable: { _ in false }) { opened.append($0) }
        XCTAssertEqual(outcome, .unreachable)
        XCTAssertTrue(opened.isEmpty)
    }

    func testNothingToOpenIsNotPublished() async {
        var opened: [URL] = []
        let outcome = await InstallAction.install(info(installURL: nil), reachable: { _ in true }) { opened.append($0) }
        XCTAssertEqual(outcome, .notPublished)
        XCTAssertTrue(opened.isEmpty)
    }

    // MARK: CE review: only a link that checks out is opened, only HTTPS is probed

    func testOnlyAnItmsServicesLinkToTheSameHTTPSHostIsOpened() async {
        let page = "https://mac.tail.ts.net:8443/releases/0.6.1/index.html"
        let bad = [
            "https://mac.tail.ts.net:8443/releases/0.6.1/manifest.plist",                                   // not itms-services
            "itms-services://?action=download-manifest&url=http://mac.tail.ts.net:8443/m.plist",            // manifest over http
            "itms-services://?action=download-manifest&url=https://evil.example.com/m.plist",               // another host
            "itms-services://?action=download-manifest",                                                    // no url=
        ]
        for link in bad {
            let package = info(installURL: link, pageURL: page)
            XCTAssertEqual(InstallState.of(package, installed: older), .notPublished, link)
            var opened: [URL] = []
            var probed: [URL] = []
            let outcome = await InstallAction.install(package, reachable: { probed.append($0); return true }) { opened.append($0) }
            XCTAssertEqual(outcome, .notPublished, link)
            XCTAssertTrue(opened.isEmpty, "nothing opened for \(link)")
            XCTAssertTrue(probed.isEmpty, "nothing probed for \(link)")
        }
        XCTAssertTrue(InstallLink.isSafe(info().installURL, page: info().pageURL), "the daemon's real shape")
        XCTAssertTrue(InstallLink.isSafe(URL(string: "itms-services://?action=download-manifest&url=https://MAC.tail.ts.net/m.plist"),
                                         page: URL(string: "https://mac.tail.ts.net/index.html")), "hosts compare without case")
        XCTAssertFalse(InstallLink.isSafe(info().installURL, page: nil), "no page to check against")
    }

    func testOnlyAnHTTPSPageIsProbed() async {
        // An http page fails the link check, so nothing is probed or opened.
        let package = info(pageURL: "http://mac.tail.ts.net:8443/releases/0.6.1/index.html")
        XCTAssertEqual(InstallState.of(package, installed: older), .notPublished)
        var probed: [URL] = []
        let outcome = await InstallAction.install(package, reachable: { probed.append($0); return true }) { _ in }
        XCTAssertEqual(outcome, .notPublished)
        XCTAssertTrue(probed.isEmpty)
        // And the probe itself never goes out over http.
        let reached = await InstallAction.reachable(URL(string: "http://127.0.0.1:41209/index.html")!)
        XCTAssertFalse(reached)
    }

    // MARK: test 9: the offer banner shows, and Not now hides it

    func testAnOfferPushShowsTheBannerAndNotNowHidesIt() async {
        let store = AppStore(defaults: ComputerDefaults(id: "test-install-offer"))
        XCTAssertNil(store.installOffer)
        store.pushReceived("install_offer", ["type": "install_offer", "device_id": "d1", "offer": [
            "release_id": "r1", "project_id": "p1", "version": "0.6.1", "build": "12",
            "install_url": "itms-services://?action=download-manifest&url=https://mac/m.plist",
            "page_url": "https://mac/index.html", "title": "The Hermes 0.6.1 (12) is ready to install",
        ] as JSONDict])
        XCTAssertEqual(store.installOffer?.releaseId, "r1")
        XCTAssertEqual(store.installOffer.map { InstallWords.banner($0.version) }, "Flotilla 0.6.1 is ready to install")
        await store.dismissInstallOffer()
        XCTAssertNil(store.installOffer, "Not now hides it")
    }

    func testTheBannersInstallOpensTheOffersLink() async {
        let offer = InstallOffer(["release_id": "r1", "version": "0.6.1", "build": "12",
                                  "install_url": "itms-services://?action=download-manifest&url=https://mac/m.plist",
                                  "page_url": "https://mac/index.html"])
        var opened: [URL] = []
        let outcome = await InstallAction.install(offer, reachable: { _ in true }) { opened.append($0) }
        XCTAssertEqual(opened.map(\.absoluteString), ["itms-services://?action=download-manifest&url=https://mac/m.plist"])
        XCTAssertEqual(outcome, .opened(opened[0]))
    }

    // MARK: Debug launch arguments for QA captures (no bypass of the link check)

    func testTheInstallStubStandsInForTheDaemonAndIsStillChecked() async throws {
        defer { UserDefaults.standard.removeObject(forKey: InstallStubs.installKey) }
        let store = AppStore(defaults: ComputerDefaults(id: "test-install-stub"))
        UserDefaults.standard.set("""
        {"install": {"release_id": "r1", "version": "0.6.1", "build": "12", "state": "approved", "installable": true,
          "page_url": "https://mac.tail.ts.net:8443/releases/0.6.1/index.html",
          "install_url": "itms-services://?action=download-manifest&url=https://mac.tail.ts.net:8443/releases/0.6.1/manifest.plist",
          "computer": "Studio Mac"}}
        """, forKey: InstallStubs.installKey)
        let good = try await store.releaseInstall("r1")
        XCTAssertEqual(good.map { InstallState.of($0, installed: older) }, .ready(forTesting: false))

        // A stubbed link that doesn't check out is still never offered.
        UserDefaults.standard.set("""
        {"install": {"release_id": "r1", "version": "0.6.1", "build": "12", "state": "approved", "installable": true,
          "page_url": "https://mac.tail.ts.net/index.html",
          "install_url": "itms-services://?action=download-manifest&url=https://evil.example.com/m.plist"}}
        """, forKey: InstallStubs.installKey)
        let bad = try await store.releaseInstall("r1")
        XCTAssertEqual(bad.map { InstallState.of($0, installed: older) }, .notPublished)
    }

    func testTheReleaseStubStandsInForThatReleaseOnly() async throws {
        defer { UserDefaults.standard.removeObject(forKey: InstallStubs.releaseKey) }
        let store = AppStore(defaults: ComputerDefaults(id: "test-release-stub"))
        UserDefaults.standard.set("""
        {"release": {"id": "rel-qa", "name": "0.6.2", "display_version": "0.6.2", "status": "approved", "version": 3,
          "items": [{"item_id": "H-230", "verdict": "approve"}]}}
        """, forKey: InstallStubs.releaseKey)
        XCTAssertEqual(InstallStubs.releaseId, "rel-qa", "opened at launch")
        let release = try await store.release("rel-qa")
        XCTAssertEqual(release.version, "0.6.2")
        XCTAssertEqual(release.status, "approved")
        XCTAssertEqual(release.items.map(\.itemId), ["H-230"])
        // Another id still asks the computer (not connected here: it throws).
        do { _ = try await store.release("other"); XCTFail("only the stubbed id is stubbed") } catch {}
    }

    func testTheOfferStubShowsTheBannerAsThePushWould() async {
        defer { UserDefaults.standard.removeObject(forKey: InstallStubs.offerKey) }
        let store = AppStore(defaults: ComputerDefaults(id: "test-offer-stub"))
        UserDefaults.standard.set("""
        {"offers": [{"release_id": "r1", "project_id": "p1", "version": "0.6.1", "build": "12",
          "install_url": "itms-services://?action=download-manifest&url=https://mac/m.plist", "page_url": "https://mac/index.html"}]}
        """, forKey: InstallStubs.offerKey)
        await store.refreshInstallOffer()
        XCTAssertEqual(store.installOffer?.version, "0.6.1")
        await store.dismissInstallOffer()
        XCTAssertNil(store.installOffer, "Not now still hides it")
    }

    // MARK: §5: the version report, and the one-time toast

    func testEveryHelloReportsThisAppsVersionAndBuild() {
        let hello = DaemonClient.hello(token: "t", requestId: "1", version: "0.6.2", build: "14")
        XCTAssertEqual(hello.str("type"), "hello")
        XCTAssertEqual(hello.str("app_version"), "0.6.2")
        XCTAssertEqual(hello.str("app_build"), "14")
        XCTAssertEqual(hello.str("token"), "t")
    }

    func testUpdatedToastOnceAfterANewVersionAndOnlyOnceSeen() {
        let defaults = UserDefaults(suiteName: "test-update-notice")!
        defaults.removePersistentDomain(forName: "test-update-notice")
        XCTAssertNil(UpdateNotice.pending(defaults, version: "0.6.1", build: "12"), "first launch: nothing")
        XCTAssertNil(UpdateNotice.pending(defaults, version: "0.6.1", build: "12"), "same version: nothing")
        XCTAssertEqual(UpdateNotice.pending(defaults, version: "0.6.2", build: "13"), "Updated to Flotilla 0.6.2.")
        // QA-013: shown too early (a blank cold launch) and never seen: still owed.
        XCTAssertEqual(UpdateNotice.pending(defaults, version: "0.6.2", build: "13"), "Updated to Flotilla 0.6.2.",
                       "not marked until it was on screen")
        UpdateNotice.markShown(defaults, version: "0.6.2", build: "13")
        XCTAssertNil(UpdateNotice.pending(defaults, version: "0.6.2", build: "13"), "once seen, done")
        XCTAssertEqual(UpdateNotice.visible, .seconds(4))
    }

    func testStubsTakeBareJSONFromTheLaunchArguments() {
        let bare = #"{"release": {"id": "rel-qa", "status": "approved"}}"#
        let args = ["Flotilla", "-gravHost", "127.0.0.1", "-releaseStub", bare]
        XCTAssertEqual(InstallStubs.reply(InstallStubs.releaseKey, arguments: args)?.dict("release")?.str("id"), "rel-qa")
        XCTAssertNil(InstallStubs.reply(InstallStubs.installKey, arguments: args), "only the flag asked for")
        // The quoted-plist form still works, through UserDefaults.
        let defaults = UserDefaults(suiteName: "test-stub-args")!
        defaults.set(#"{"install": {"release_id": "r9"}}"#, forKey: InstallStubs.installKey)
        XCTAssertEqual(InstallStubs.reply(InstallStubs.installKey, defaults, arguments: ["-installStub", #""{…}""#])?
            .dict("install")?.str("release_id"), "r9")
        defaults.removePersistentDomain(forName: "test-stub-args")
    }

    func testAnOutsideRouteLandsOnThatScreenAlone() {
        // H-230 iPad: the route's push is deferred a turn; where it lands is unchanged.
        let route = NeedsDestination.release(computerId: "mac", releaseId: "rel-qa")
        XCTAssertEqual(NeedsRoute.path(to: route), NavigationPath([route]))
        XCTAssertEqual(NeedsRoute.path(to: route).count, 1)
    }
}
