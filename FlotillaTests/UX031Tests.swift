import SwiftProtobuf
import XCTest
@testable import Flotilla

/// UX-031 copy: permission rows in the glossary's words, and a thread with an
/// open question previews that question.
final class UX031Tests: XCTestCase {
    func testAPermissionRowReadsWantsToRun() {
        let words = PermissionWords("Backend Dev asks: Bash: rm -rf build/ && npm ci")
        XCTAssertEqual(words.title, "Backend Dev wants to run Bash")
        XCTAssertEqual(words.command, "rm -rf build/ && npm ci")
    }

    func testAnMCPToolGetsItsReadableName() {
        let words = PermissionWords("iOS Dev asks: mcp__hermes-bus__send_message")
        XCTAssertEqual(words.title, "iOS Dev wants to run Send message")
        XCTAssertNil(words.command)
    }

    func testAnotherShapeStaysAsItIs() {
        XCTAssertEqual(PermissionWords("Designer wants to run Bash").title, "Designer wants to run Bash")
        XCTAssertNil(PermissionWords("Designer wants to run Bash").command)
    }

    func testALongCommandIsCutInTheMiddle() {
        let long = "xcodebuild -project Flotilla.xcodeproj -scheme Flotilla -destination generic build"
        let cut = PermissionWords.middleTruncated(long)
        XCTAssertEqual(cut.count, 44)
        XCTAssertTrue(cut.hasPrefix("xcodebuild"))
        XCTAssertTrue(cut.hasSuffix("generic build"))
        XCTAssertTrue(cut.contains("…"))
        XCTAssertEqual(PermissionWords.middleTruncated("npm ci"), "npm ci")
    }

    func testAQuestionStillOpenIsTheNewestAsking() {
        let entries = [
            ThreadEntry(id: "1", fromOwner: false, text: "Should the release notes mention the new board?", at: nil, asks: true, open: true),
            ThreadEntry(id: "2", fromOwner: false, text: "Done.", at: nil, asks: false, open: false),
        ]
        XCTAssertEqual(entries.openQuestion?.id, "1")
        XCTAssertNil([ThreadEntry(id: "1", fromOwner: false, text: "Old?", at: nil, asks: true, open: false)].openQuestion)
    }
}
