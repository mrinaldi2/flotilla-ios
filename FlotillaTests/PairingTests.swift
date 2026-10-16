import XCTest
@testable import Flotilla

/// Pairing links from a scanned code or the clipboard, and what a failed
/// connection tells the person to fix.
final class PairingTests: XCTestCase {
    func testFlotillaLink() {
        let link = PairingLink.parse("flotilla://pair?host=mac-mini.tail1234.ts.net&port=49777&token=abc123")
        XCTAssertEqual(link, PairingLink(host: "mac-mini.tail1234.ts.net", port: 49777, token: "abc123"))
    }

    /// The codes and links desktop apps from before the rename show.
    func testLegacyTheHermesLink() {
        let link = PairingLink.parse("thehermes://pair?host=mac-mini.tail1234.ts.net&port=49777&token=abc123")
        XCTAssertEqual(link, PairingLink(host: "mac-mini.tail1234.ts.net", port: 49777, token: "abc123"))
    }

    func testLegacyGravityLink() {
        let link = PairingLink.parse("gravity://pair?host=100.64.0.7&port=49790&token=t0k")
        XCTAssertEqual(link, PairingLink(host: "100.64.0.7", port: 49790, token: "t0k"))
    }

    func testNameKindAndEncodedToken() {
        let link = PairingLink.parse("flotilla://pair?host=pc&port=1&token=a%2Bb%3D%3D&name=Studio%20PC&kind=windows")
        XCTAssertEqual(link?.token, "a+b==")
        XCTAssertEqual(link?.name, "Studio PC")
        XCTAssertEqual(link?.kind, .windows)
    }

    func testPortDefaultsAndIPv6Brackets() {
        let link = PairingLink.parse("flotilla://pair?host=%5Bfd7a:115c::1%5D&token=x")
        XCTAssertEqual(link?.host, "fd7a:115c::1")
        XCTAssertEqual(link?.port, PairingLink.defaultPort)
    }

    func testLinkInsidePastedText() {
        let text = "Pair your phone:\n  <FLOTILLA://pair?host=mac&port=49777&token=xyz>  (shown once)"
        XCTAssertEqual(PairingLink.parse(text), PairingLink(host: "mac", port: 49777, token: "xyz"))
        let legacy = "Pair your phone:\n  <THEHERMES://pair?host=mac&port=49777&token=xyz>  (shown once)"
        XCTAssertEqual(PairingLink.parse(legacy), PairingLink(host: "mac", port: 49777, token: "xyz"))
    }

    func testNotAPairingLink() {
        XCTAssertNil(PairingLink.parse("abc123"))
        XCTAssertNil(PairingLink.parse("https://example.com/pair?host=mac&token=x"))
        XCTAssertNil(PairingLink.parse("flotilla://open?host=mac&token=x"))
        XCTAssertNil(PairingLink.parse("thehermes://open?host=mac&token=x"))
        XCTAssertNil(PairingLink.parse("hermes://pair?host=mac&token=x"), "never a pairing scheme")
        XCTAssertNil(PairingLink.parse("flotilla://pair?host=mac"), "no token")
        XCTAssertNil(PairingLink.parse("flotilla://pair?token=x"), "no host")
        XCTAssertNil(PairingLink.parse("flotilla://pair?host=mac&port=99999&token=x"), "port out of range")
        XCTAssertNil(PairingLink.parse("flotilla://pair?host=mac&port=http&token=x"), "port not a number")
    }

    func testRejectedTokenPointsAtTheToken() {
        let failure = PairingFailure.from(.authFailed("unauthorized"), host: "mac", port: 49777, computer: "Studio")
        XCTAssertEqual(failure?.field, .token)
        XCTAssertEqual(failure?.message, "Token rejected — check it on Studio under Settings → Devices.")
    }

    func testNoAnswerPointsAtTheAddress() {
        let failure = PairingFailure.from(.disconnected("Could not connect to the server."), host: "mac", port: 49777, computer: "Studio")
        XCTAssertEqual(failure?.field, .address)
        XCTAssertTrue(failure?.message.hasPrefix("Couldn’t reach mac:49777 — ") == true)
    }

    func testVersionMismatchSaysUpdate() {
        let failure = PairingFailure.from(.versionMismatch("unsupported"), host: "mac", port: 49777, computer: "Studio")
        XCTAssertEqual(failure?.field, .version)
        XCTAssertTrue(failure?.message.hasPrefix("Update needed") == true)
    }

    func testNoFailureWhileConnectingOrConnected() {
        for status in [ConnectionStatus.idle, .connecting, .connected] {
            XCTAssertNil(PairingFailure.from(status, host: "mac", port: 1, computer: "Studio"))
        }
    }
}
