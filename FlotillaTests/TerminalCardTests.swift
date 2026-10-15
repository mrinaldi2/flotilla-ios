import XCTest
@testable import Flotilla

/// H-108: a terminal command asking to act as the owner is read-only here,
/// composed from its origin fields and listed above bot cards.
final class TerminalCardTests: XCTestCase {
    private func request(_ id: String, bot: String, origin: JSONDict?, at: String) -> PermissionRequest {
        var d: JSONDict = ["id": id, "bot_id": bot, "tool": "Terminal command", "summary": "hermesd publish",
                           "input": "", "created_at": at]
        if let origin { d["origin"] = origin }
        return PermissionRequest(d)
    }

    func testTheOriginLineLeavesOutWhatIsMissing() throws {
        let full = request("1", bot: "terminal", origin: ["command": "hermesd publish", "pid": 4121, "process": "claude",
                                                          "launched_from": "iTerm2", "cwd": "~/x", "bot": "DevOps"],
                           at: "2026-10-06T10:00:00Z")
        XCTAssertTrue(full.isTerminal)
        XCTAssertEqual(full.origin?.line, "From claude in iTerm2 · in ~/x · process 4121")
        XCTAssertEqual(full.origin?.bot, "DevOps")

        let sparse = request("2", bot: "terminal", origin: ["command": "hermesd install", "cwd": NSNull()], at: "2026-10-06T10:00:00Z")
        XCTAssertNil(sparse.origin?.line)
        XCTAssertEqual(sparse.origin?.command, "hermesd install")
    }

    func testAnOlderDaemonSendsOnlyTheSummary() {
        let old = request("3", bot: "terminal", origin: nil, at: "2026-10-06T10:00:00Z")
        XCTAssertTrue(old.isTerminal)
        XCTAssertNil(old.origin)
    }

    func testTerminalCommandsComeBeforeBotCards() {
        let bot = request("b", bot: "b1", origin: nil, at: "2026-10-06T09:00:00Z")
        let terminal = request("t", bot: "terminal", origin: nil, at: "2026-10-06T11:00:00Z")
        XCTAssertEqual(PermissionRequest.ordered([bot, terminal]).map(\.id), ["t", "b"])
        XCTAssertEqual(PermissionRequest.adding(terminal, to: [bot]).map(\.id), ["t", "b"])
        XCTAssertFalse(bot.isTerminal)
    }
}
