import SwiftProtobuf
import XCTest
@testable import Flotilla

/// One project's screens (H-134 I2): the Overview reads `dashboard_get`, the
/// release list `list_releases`, and the board travels as typed envelopes.
@MainActor
final class ProjectTests: XCTestCase {
    private let dashboard: JSONDict = [
        "project_id": "p1", "as_of": "2026-10-06T10:00:00Z", "since": "2026-09-29T10:00:00Z", "home": NSNull(),
        "needs_you": [],
        "board": [
            "columns": [
                ["key": "ready", "name": "Ready", "category": "ready", "count": 4, "wip_limit": NSNull(), "wip_scope": "column"],
                ["key": "doing", "name": "Doing", "category": "doing", "count": 3, "wip_limit": 5, "wip_scope": "column"],
                ["key": "verify", "name": "Verify", "category": "verify", "count": 3, "wip_limit": 3, "wip_scope": "column"],
                ["key": "done", "name": "Done", "category": "done", "count": 40, "wip_limit": NSNull(), "wip_scope": "column"],
            ],
            "blocked": 1, "stale": 0, "done_this_week": 6, "rework_this_week": 1,
        ],
        "releases": [["id": "r1", "name": "desktop-0.17.0", "display_version": "0.17.0", "status": "awaiting_owner",
                      "items": [["item_id": "H-130", "verdict": "pending", "owner_note": NSNull()]],
                      "tests": [["machine": "mac", "tester": "b-t", "build_sha256": "ab", "result": "pass"]],
                      "readiness": ["items_total": 4, "items_ready": 3, "builds": ["mac"], "tests_required": ["mac"], "tests_passed": ["mac"]],
                      "can_rule": true, "rule_on": NSNull()]],
        "team": [["bot": ["id": "b1", "name": "Desktop Dev", "state": "working", "project_id": "p1"],
                  "items": [["id": "H-130", "title": "Projects home daemon"]], "open_tasks": 2]],
        "meetings": [["series": ["id": "s1", "type": "standup", "name": "Stand-up", "cron": "0 9 * * *", "tz": "Europe/Rome",
                                 "facilitator": "b-lead", "attendees": [], "enabled": true],
                      "next_at": "2026-10-07T07:00:00Z", "collecting": NSNull(),
                      "last_held": ["id": "MTG-1", "series_id": "s1", "type": "standup", "name": "Stand-up", "status": "held",
                                    "summary": "H-130 in review.", "closed_at": "2026-10-06T07:20:00Z", "outputs": [:],
                                    "contributed": 3, "attendee_count": 3, "skip_reason": NSNull(), "started_at": NSNull(),
                                    "facilitator": "b-lead"]]],
        "action_items": [["id": "a1", "meeting_id": "MTG-1", "series_id": "s1", "text": "Fix the flaky test", "owner": "b1",
                          "due_at": "2026-10-05T00:00:00Z", "status": "open", "item_id": NSNull(),
                          "meeting_name": "Stand-up", "overdue": true]],
    ]

    func testDashboardReadsEveryWidget() {
        let d = Dashboard(dashboard)
        XCTAssertTrue(d.hasBoard)
        XCTAssertEqual(d.strip.map(\.name), ["Doing", "Verify"], "the in-progress columns only")
        XCTAssertTrue(d.strip[1].full)
        XCTAssertFalse(d.strip[0].full)
        XCTAssertEqual(d.doneThisWeek, 6)
        XCTAssertNil(d.home)
        XCTAssertEqual(d.releases.first?.version, "0.17.0")
        XCTAssertEqual(d.team.first?.bot.name, "Desktop Dev")
        XCTAssertEqual(d.team.first?.doing.first?.id, "H-130")
        XCTAssertEqual(d.meetings.first?.name, "Stand-up")
        XCTAssertEqual(d.meetings.first?.lastSummary, "H-130 in review.")
        XCTAssertFalse(d.meetings.first?.collecting ?? true)
        XCTAssertEqual(d.actions.first?.overdue, true)
        XCTAssertEqual(d.actions.first?.meetingName, "Stand-up")
    }

    func testAProjectWithoutABoard() {
        let d = Dashboard(["board": NSNull(), "releases": [], "team": [], "meetings": [], "action_items": []])
        XCTAssertFalse(d.hasBoard)
        XCTAssertTrue(d.strip.isEmpty)
    }

    func testReleaseReadsItsReadinessAndWords() throws {
        let release = Release(try XCTUnwrap(dashboard.list("releases").first))
        XCTAssertEqual(release.itemsReady, 3)
        XCTAssertEqual(release.itemsTotal, 4)
        XCTAssertEqual(release.items.first?.verdict, "pending")
        XCTAssertEqual(release.tests.first?.result, "pass")
        XCTAssertTrue(release.canRule)
        XCTAssertEqual(release.statusWords.0, "0.17.0 ready for you to test")
    }

    func testABoardRequestRoundTripsAsAnEnvelope() throws {
        var get = Flotilla_Board_V1_BoardGet()
        get.projectID = "p1"
        var request = Flotilla_Board_V1_BoardRequest()
        request.request = .boardGet(get)
        var envelope = Flotilla_Wire_V1_Envelope()
        envelope.reqID = 7
        envelope.body = .boardRequest(request)
        let data: Data = try envelope.serializedData()
        let back = try Flotilla_Wire_V1_Envelope(serializedBytes: data)
        XCTAssertEqual(back.reqID, 7)
        guard case .boardRequest(let decoded)? = back.body, case .boardGet(let decodedGet)? = decoded.request else {
            return XCTFail("not a board_get")
        }
        XCTAssertEqual(decodedGet.projectID, "p1")
    }

    func testCapitalizedFirst() {
        XCTAssertEqual("ship".capitalizedFirst, "Ship")
        XCTAssertEqual("partially_deployed".capitalizedFirst, "Partially deployed")
    }
}
