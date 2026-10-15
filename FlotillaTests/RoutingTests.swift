import XCTest
@testable import Flotilla

/// Tapped notifications open what they announce, and pairing links that the
/// system opens the app with become a prefilled Connect.
final class RoutingTests: XCTestCase {
    func testUserInfoRoundTrips() {
        for kind in NotificationTarget.Kind.allCases {
            let target = NotificationTarget(computerId: "mac", kind: kind, id: "x1", botId: "b1")
            XCTAssertEqual(NotificationTarget(userInfo: target.userInfo), target, "\(kind)")
        }
        let info = NotificationTarget(computerId: "mac", kind: .decision, id: "d1").userInfo
        XCTAssertEqual(info, ["computer": "mac", "kind": "decision", "id": "d1"])
    }

    func testEachKindOpensItsPlace() {
        func open(_ kind: NotificationTarget.Kind, id: String, bot: String?) -> NotificationTarget.Destination? {
            NotificationTarget(computerId: "mac", kind: kind, id: id, botId: bot).destination
        }
        XCTAssertEqual(open(.decision, id: "d1", bot: nil), .decision(id: "d1"))
        XCTAssertEqual(open(.permission, id: "p1", bot: "b1"), .bot(id: "b1", pane: nil))
        XCTAssertEqual(open(.waiting, id: "b1", bot: "b1"), .bot(id: "b1", pane: .chat))
        XCTAssertEqual(open(.task, id: "t1", bot: "b1"), .bot(id: "b1", pane: .work))
        XCTAssertEqual(open(.approval, id: "b1", bot: "b1"), .bot(id: "b1", pane: nil))
    }

    func testFallbacksWithoutABot() {
        XCTAssertEqual(NotificationTarget(computerId: "mac", kind: .permission, id: "p1").destination,
                       .permissionCard(id: "p1"), "a prompt whose bot is unknown opens its card in Decisions")
        XCTAssertNil(NotificationTarget(computerId: "mac", kind: .task, id: "t1").destination,
                     "a task without its bot has nowhere to go")
    }

    func testLegacyPermissionNotification() {
        let target = NotificationTarget(userInfo: ["computer": "mac", "permission": "p9"])
        XCTAssertEqual(target, NotificationTarget(computerId: "mac", kind: .permission, id: "p9"))
    }

    func testNotificationsThatLeadNowhere() {
        XCTAssertNil(NotificationTarget(userInfo: [:]))
        XCTAssertNil(NotificationTarget(userInfo: ["computer": "mac"]), "a plain notice")
        XCTAssertNil(NotificationTarget(userInfo: ["computer": "mac", "kind": "party", "id": "1"]), "unknown kind")
        XCTAssertNil(NotificationTarget(userInfo: ["kind": "decision", "id": "d1"]), "no computer")
        XCTAssertNil(NotificationTarget(userInfo: ["computer": "mac", "kind": "decision", "id": ""]), "empty id")
    }

    func testPairingURLsOpenConnect() {
        let url = URL(string: "thehermes://pair?host=mac&port=49777&token=abc&name=Studio")!
        XCTAssertEqual(IncomingURL.pairing(url), PairingLink(host: "mac", port: 49777, token: "abc", name: "Studio"))
        let legacy = URL(string: "gravity://pair?host=mac&token=abc")!
        XCTAssertEqual(IncomingURL.pairing(legacy)?.port, PairingLink.defaultPort)
    }

    func testOtherURLsAreIgnored() {
        XCTAssertNil(IncomingURL.pairing(URL(string: "https://example.com/pair?host=mac&token=abc")!))
        XCTAssertNil(IncomingURL.pairing(URL(string: "thehermes://open?host=mac&token=abc")!))
        XCTAssertNil(IncomingURL.pairing(URL(string: "thehermes://pair?host=mac")!))
    }
}
