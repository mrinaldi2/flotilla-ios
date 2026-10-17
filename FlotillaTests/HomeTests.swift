import SwiftProtobuf
import XCTest
@testable import Flotilla

/// The projects home (H-128 rev 2): the golden fixtures decode as the
/// generated `hermes.home.v1` types, computers merge into one row per
/// project, and the order matches the server's.
@MainActor
final class HomeTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("contract/fixtures/home")

    private func json(_ name: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixtures.appendingPathComponent("\(name).json")))
    }

    // MARK: Fixtures

    func testOverviewFixtureDecodes() throws {
        let overview = try HomeJSON.decode(HomeOverview.self, json("overview"))
        let row = try XCTUnwrap(overview.rows.first)
        XCTAssertEqual(row.name, "gravity")
        XCTAssertEqual(row.members.map(\.computerName), ["mac", "imac"])
        XCTAssertEqual(row.currentRelease.state, "awaiting_owner")
        XCTAssertTrue(row.currentRelease.awaitingOwner)
        XCTAssertEqual(row.attention.byKind["bot_stopped"], 1)
        XCTAssertTrue(row.attention.hasOldestAt)
        XCTAssertEqual(row.columns.first?.category, "inbox")
        XCTAssertEqual(row.botsWaiting, 1)
    }

    /// The 0.20 Board glance additions (overview_bots, overview_top_attention,
    /// attention_bot_stopped, column kinds).
    func testOverviewFixtureCarriesTheBoardGlanceAdditions() throws {
        let row = try XCTUnwrap(try HomeJSON.decode(HomeOverview.self, json("overview")).rows.first)
        XCTAssertEqual(row.botList.first?.name, "Lead")
        XCTAssertTrue(row.botList.first?.lead ?? false)
        XCTAssertEqual(row.botList.first?.status, .working)
        XCTAssertTrue(row.botList.contains { $0.status == .offline })
        XCTAssertEqual(row.topAttention.kind, .botStopped)
        XCTAssertEqual(row.topAttention.botState, "crashed")
        XCTAssertEqual(row.members.last?.online, false)
        XCTAssertTrue(row.members.last?.hasLastSeenAt ?? false)
        XCTAssertEqual(row.columns.last?.kind, "cancelled")
        XCTAssertTrue(row.columns.last?.hidden ?? false)
    }

    func testAttentionRowsFixtureDecodesTargets() throws {
        let rows = try HomeJSON.decode(Flotilla_Home_V1_AttentionRows.self, json("attention_rows")).rows
        XCTAssertEqual(rows.first?.kind, .ownerAction)
        XCTAssertEqual(rows.first?.target, .actionID("oa-7"))
        XCTAssertEqual(rows.first?.daemonID, "d-imac")
        XCTAssertTrue(rows.contains { $0.target == .decisionID("dec-1") })
        XCTAssertTrue(rows.contains { if case .bot(let ref)? = $0.target { ref.botID == "b-dev" } else { false } })
        XCTAssertEqual(rows.first { $0.kind == .relayedRulings }?.relayedCount, 2)
    }

    func testPeerAttentionFixtureDecodes() throws {
        let attention = try HomeJSON.decode(Flotilla_Home_V1_ProjectAttention.self, json("project_attention"))
        XCTAssertEqual(attention.parts.first?.local.count, 1)
        XCTAssertEqual(attention.parts.first?.botsWaiting, 1)
    }

    func testUnknownFieldsAndEnumsFromANewerDaemonAreTolerated() throws {
        let data = #"{"rows":[{"id":"x","kind":"SOMETHING_NEW","title":"New","weight":2,"brand_new_field":1}]}"#
        let rows = try HomeJSON.decode(Flotilla_Home_V1_AttentionRows.self, JSONSerialization.jsonObject(with: Data(data.utf8))).rows
        XCTAssertEqual(rows.first?.title, "New")
    }

    func testAnUnreadableAnswerIsAnError() {
        XCTAssertThrowsError(try HomeJSON.decode(HomeOverview.self, nil))
        XCTAssertThrowsError(try HomeJSON.decode(HomeOverview.self, ["rows": "not a list"]))
    }

    // MARK: Merge and rank

    private func row(_ name: String, members: [(String, String)], score: UInt32 = 0, stale: [String] = [],
                     home: String = "", pinned: Bool = false, oldest: Date? = nil, active: Date? = nil) -> HomeRow {
        var row = HomeRow()
        row.projectID = members.first?.1 ?? name
        row.name = name
        row.members = members.map { daemon, project in
            var member = Flotilla_Home_V1_Member()
            member.daemonID = daemon
            member.projectID = project
            return member
        }
        row.attention.score = score
        row.attention.count = score
        if let oldest { row.attention.oldestAt = Google_Protobuf_Timestamp(date: oldest) }
        if let active { row.lastActivityAt = Google_Protobuf_Timestamp(date: active) }
        row.staleSources = stale
        row.boardHome = home
        row.pinned = pinned
        return row
    }

    func testTheSameProjectOnTwoComputersShowsOnce() {
        let mac = row("gravity", members: [("d-mac", "p1"), ("d-imac", "p9")], stale: ["d-imac"], home: "d-mac")
        let imac = row("gravity", members: [("d-imac", "p9"), ("d-mac", "p1")], home: "d-mac")
        let other = row("phd", members: [("d-mac", "p2")])
        let merged = HomeMerge.merge([("mac", "d-mac", mac), ("imac", "d-imac", imac), ("mac", "d-mac", other)])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.first { $0.row.name == "gravity" }?.computerId, "imac", "fewest stale sources wins")
    }

    func testTiesGoToTheBoardsHome() {
        let mac = row("gravity", members: [("d-mac", "p1"), ("d-imac", "p9")], home: "d-mac")
        let imac = row("gravity", members: [("d-imac", "p9"), ("d-mac", "p1")], home: "d-mac")
        let merged = HomeMerge.merge([("imac", "d-imac", imac), ("mac", "d-mac", mac)])
        XCTAssertEqual(merged.first?.computerId, "mac")
    }

    func testAPinOnAnyComputerPinsTheProject() {
        let mac = row("gravity", members: [("d-mac", "p1"), ("d-imac", "p9")], home: "d-mac")
        let imac = row("gravity", members: [("d-imac", "p9"), ("d-mac", "p1")], home: "d-mac", pinned: true)
        XCTAssertTrue(HomeMerge.merge([("mac", "d-mac", mac), ("imac", "d-imac", imac)]).first?.row.pinned == true)
    }

    func testRowsWithoutMembersStayApartPerComputer() {
        let a = row("same name", members: [])
        let b = row("same name", members: [])
        XCTAssertEqual(HomeMerge.merge([("mac", nil, a), ("imac", nil, b)]).count, 2)
    }

    func testRankingMatchesTheServer() {
        let now = Date()
        let rows: [(computerId: String, row: HomeRow)] = [
            ("m", row("quiet-old", members: [], active: now.addingTimeInterval(-9000))),
            ("m", row("quiet-new", members: [], active: now)),
            ("m", row("busy-young", members: [], score: 5, oldest: now)),
            ("m", row("busy-old", members: [], score: 5, oldest: now.addingTimeInterval(-3600))),
            ("m", row("pinned", members: [], pinned: true)),
            ("m", row("top", members: [], score: 9)),
        ]
        XCTAssertEqual(HomeMerge.ranked(rows).map(\.row.name), ["pinned", "top", "busy-old", "busy-young", "quiet-new", "quiet-old"])
    }

    // MARK: Words

    func testWhyItRanks() {
        var attention = Flotilla_Home_V1_AttentionSummary()
        XCTAssertEqual(AttentionWords.summary(attention), "Nothing needs you")
        attention.count = 4
        attention.byKind = ["decision": 2, "release_awaiting": 1, "owner_action": 1]
        XCTAssertEqual(AttentionWords.summary(attention), "1 release to test · 1 Run card · 2 decisions")
        attention.byKind = ["mystery": 4]
        XCTAssertEqual(AttentionWords.summary(attention), "4 need you")
    }

    func testReleaseWordsFollowTheGlossary() {
        var release = Flotilla_Home_V1_ReleaseBrief()
        release.version = "0.17.0"
        release.state = "awaiting_owner"
        XCTAssertEqual(ReleaseStatusWords.pill(release).0, "0.17.0 ready for you to test")
        release.state = "deployed"
        XCTAssertEqual(ReleaseStatusWords.pill(release).0, "0.17.0 live")
        release.state = "partially_deployed"
        XCTAssertEqual(ReleaseStatusWords.pill(release).0, "0.17.0 rolling out")
    }

    // MARK: Cache

    func testTheLastOverviewIsShownBeforeTheNetwork() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let overview = try HomeJSON.decode(HomeOverview.self, json("overview"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data: Data = try overview.serializedData()
        try data.write(to: folder.appendingPathComponent("computer-1.pb"))

        let feed = HomeFeed(cacheDirectory: folder)
        let computer = Computer(ComputerRecord(name: "Mac", kind: .mac, host: "127.0.0.1", port: 1), token: nil)
        feed.loadCache([computer])
        XCTAssertNil(feed.overviews[computer.id], "only that computer's cache is read")
        try data.write(to: folder.appendingPathComponent("\(computer.id).pb"))
        feed.loadCache([computer])
        XCTAssertEqual(feed.overviews[computer.id]?.rows.first?.name, "gravity")
        XCTAssertEqual(feed.cards([computer]).first?.row.name, "gravity")
    }
}
