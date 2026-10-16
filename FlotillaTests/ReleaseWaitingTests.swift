import XCTest
@testable import Flotilla

/// H-248 (UX-048): "▲ Waiting for you" from the release's owner_blockers (frozen shape).
@MainActor
final class ReleaseWaitingTests: XCTestCase {
    private func blocker(_ kind: String, _ id: String, _ title: String, item: String? = nil, bot: String? = nil,
                         computer: String? = nil, at: String? = nil) -> JSONDict {
        ["kind": kind, "id": id, "title": title, "item_id": item ?? NSNull(), "bot": bot ?? NSNull(),
         "computer": computer ?? NSNull(), "created_at": at ?? NSNull()]
    }

    private var payload: JSONDict {
        ["id": "rel-1", "name": "0.17.5", "display_version": "0.17.5", "status": "awaiting_owner", "version": 3,
         "work_item_id": "H-247",
         "owner_blockers": [
            blocker("question", "c-9", "Ship the notes as they are?", item: "H-240", bot: "dev", at: "2026-10-08T09:00:00Z"),
            blocker("decision", "d-2", "Which accent colour?", item: "H-241", bot: "ux", at: "2026-10-08T10:00:00Z"),
            blocker("run", "a-1", "Clear the stale build cache", item: "H-242", bot: "devops", computer: "mac", at: "2026-10-08T08:00:00Z"),
            blocker("ruling", "d-rel", "0.17.5", item: "H-247", at: "2026-10-08T11:00:00Z"),
            blocker("permission", "p-4", "Bash", item: "H-243", bot: "dev", computer: "imac", at: "2026-10-08T09:30:00Z"),
            ["kind": "something_new", "id": "x", "title": "ignored"],
         ] as [Any]]
    }

    func testTheFrozenShapeInUXOrder() throws {
        let release = Release(payload)
        XCTAssertEqual(release.workItemId, "H-247")
        let blockers = try XCTUnwrap(release.ownerBlockers)
        // Ruling → run/decision/permission (oldest first) → question; an unknown kind is skipped.
        XCTAssertEqual(blockers.map(\.kind), [.ruling, .run, .permission, .decision, .question])
        XCTAssertEqual(blockers[1].computer, "mac")
        XCTAssertNil(blockers[0].botId, "a ruling has no bot")
    }

    func testAnOlderServicePointsToNeedsYou() {
        // QA-014: on any open release, not only while it's being built.
        var old = payload
        old["owner_blockers"] = nil
        for status in ["planned", "assembling", "built", "awaiting_owner", "approved", "deploying"] {
            old["status"] = status
            XCTAssertTrue(ReleaseNow.pointsToNeedsYou(Release(old)), status)
        }
        for status in ["deployed", "rejected", "cancelled", "rolled_back", "held"] {
            old["status"] = status
            XCTAssertFalse(ReleaseNow.pointsToNeedsYou(Release(old)), "\(status): settled")
        }
        XCTAssertFalse(ReleaseNow.pointsToNeedsYou(Release(payload)), "a newer service says what waits itself")
    }

    func testAnOlderServiceHasNoField() {
        var old = payload
        old["owner_blockers"] = nil
        XCTAssertNil(Release(old).ownerBlockers, "missing field = older service: no section")
        old["owner_blockers"] = [Any]()
        XCTAssertEqual(Release(old).ownerBlockers, [], "empty: no section either, but a newer service")
    }

    func testTheCopy() throws {
        let b = try XCTUnwrap(Release(payload).ownerBlockers)
        XCTAssertEqual(WaitingWords.title(b[0], bot: nil), "◐ Test 0.17.5 and rule on it")
        XCTAssertEqual(WaitingWords.title(b[3], bot: "UX Designer"), "◆ Decide: Which accent colour?")
        XCTAssertEqual(WaitingWords.title(b[4], bot: "Desktop Dev"), "? Desktop Dev asks: Ship the notes as they are?")
        XCTAssertEqual(WaitingWords.title(b[2], bot: "Desktop Dev"), "Desktop Dev wants to run Bash")
        XCTAssertEqual(WaitingWords.title(b[1], bot: "DevOps"), "▶ DevOps asks you to run a command on mac", "the reason isn't the title")
        // A Run card has no phone flow: the row says where to run it (decision on #233).
        let now = ISO8601DateFormatter().date(from: "2026-10-08T08:25:00Z")!
        XCTAssertEqual(WaitingWords.meta(b[1], bot: "DevOps", computer: "Studio Mac", now: now),
                       "on H-242 · 25m\nRun it on mac, in the Flotilla app.", "card · age, then where to run it")
        XCTAssertEqual(WaitingWords.age(now.addingTimeInterval(-3 * 3600), now: now), "3h")
        XCTAssertEqual(WaitingWords.age(now.addingTimeInterval(-2 * 86400), now: now), "2d")
        XCTAssertTrue(WaitingWords.meta(b[3], bot: "UX Designer", computer: "Studio Mac").hasPrefix("UX Designer · Studio Mac · "),
                      "who · where · time")
        XCTAssertEqual(WaitingWords.header(5), "▲ Waiting for you · 5")
        XCTAssertEqual(WaitingWords.more(2), "+2 more")
        XCTAssertEqual(WaitingWords.shown, 3)
        XCTAssertEqual(WaitingWords.olderService, "Open Needs you to see what waits for you.")
    }

    func testEachEntryOpensItsScreen() throws {
        let b = try XCTUnwrap(Release(payload).ownerBlockers)
        XCTAssertEqual(BlockerAction.of(b[0]), .reviewRuling)
        XCTAssertEqual(BlockerAction.of(b[0]).label, "Review…")
        XCTAssertEqual(BlockerAction.of(b[1]), .none, "Run: no button")
        XCTAssertNil(BlockerAction.of(b[1]).label)
        XCTAssertEqual(BlockerAction.of(b[2]), .reviewPermission(botId: "dev"))
        XCTAssertEqual(BlockerAction.of(b[2]).label, "Review")
        XCTAssertEqual(BlockerAction.of(b[3]), .openDecision("d-2"))
        XCTAssertEqual(BlockerAction.of(b[3]).label, "Answer")
        XCTAssertEqual(BlockerAction.of(b[4]), .reply(itemId: "H-240", commentId: "c-9"), "the card, Reply on that comment")
        XCTAssertEqual(BlockerAction.of(b[4]).label, "Answer")
    }

    // MARK: Progress "Now:" (UX-048 §3)

    private func release(_ extra: JSONDict) -> Release {
        var d: JSONDict = ["id": "r", "name": "0.17.5", "display_version": "0.17.5", "version": 1, "owner_blockers": [Any]()]
        for (k, v) in extra { d[k] = v }
        return Release(d)
    }

    func testNowNamesWhoItWaitsOn() {
        let waiting = release(["status": "approved", "owner_blockers": [
            blocker("run", "a-1", "Clear the cache", item: "H-244", computer: "mac", at: "2026-10-08T08:00:00Z")]])
        XCTAssertEqual(ReleaseNow.line(waiting), .init(text: "Now: waiting for you to run a command on mac (H-244).", waitsForYou: true))
        let first: (JSONDict) -> String = { ReleaseNow.line(self.release(["status": "approved", "owner_blockers": [$0]]), botName: { $0 == "dev" ? "Desktop Dev" : nil }).text }
        XCTAssertEqual(first(blocker("decision", "d", "Which accent colour?", item: "H-241")),
                       "Now: waiting for you to decide Which accent colour? (H-241).")
        XCTAssertEqual(first(blocker("question", "c", "Ship it?", item: "H-240", bot: "dev")),
                       "Now: waiting for you to answer Desktop Dev (H-240).")
        XCTAssertEqual(first(blocker("permission", "p", "Bash", item: "H-243", bot: "dev")),
                       "Now: waiting for you to review Bash (H-243).")
        XCTAssertEqual(first(blocker("ruling", "r", "0.17.5", item: "H-247")),
                       "Now: waiting for you to test 0.17.5 and rule on it.")

        let plan: [JSONDict] = [["item_id": "H-241", "column_name": "Doing", "ready": false],
                                ["item_id": "H-243", "column_name": "Review", "ready": false],
                                ["item_id": "H-245", "column_name": "Ready", "ready": false],
                                ["item_id": "H-246", "column_name": "Verify", "ready": true]]
        XCTAssertEqual(ReleaseNow.line(release(["status": "planned", "plan": plan])).text,
                       "Now: 3 items still in progress (H-241 in Doing, H-243 in Review, +1).")
        XCTAssertEqual(ReleaseNow.line(release(["status": "assembling", "how_to_test": [["platform": "desktop-mac"], ["platform": "desktop-win"]]])).text,
                       "Now: DevOps is building the Mac and Windows packages.")
        XCTAssertEqual(ReleaseNow.line(release(["status": "built",
                                                "readiness": ["tests_required": ["mac", "win-pc"], "tests_passed": ["mac"]] as JSONDict])).text,
                       "Now: testing on win-pc (1 of 2 computers).")
        XCTAssertEqual(ReleaseNow.line(release(["status": "deploying", "deploys_to": ["mac", "win-pc", "imac"],
                                                "deployments": [["machine": "mac", "action": "deploy", "result": "ok"],
                                                                ["machine": "imac", "action": "deploy", "result": "ok"],
                                                                ["machine": "win-pc", "action": "deploy", "result": "failed"]]])).text,
                       "Now: rolling out, 2 of 3 computers updated.")
        XCTAssertEqual(ReleaseNow.line(release(["status": "approved"])).text, "Now: nothing is blocking it.")
        XCTAssertEqual(WaitingWords.projectsPill("0.17.5"), "◐ 0.17.5 waits for you")
    }

    func testTheProjectsCardPillSaysItWaitsForYou() {
        var brief = Flotilla_Home_V1_ReleaseBrief()
        brief.version = "0.17.5"
        brief.state = "approved"
        XCTAssertEqual(ReleaseStatusWords.pill(brief).0, "0.17.5 approved", "nothing waits: its state")
        brief.ownerBlockerCount = 2
        let (text, tone) = ReleaseStatusWords.pill(brief)
        XCTAssertEqual(text, "◐ 0.17.5 waits for you")
        XCTAssertEqual(tone, .needsYou)
    }

    func testAReleaseUpdatedPushRereadsThatRelease() {
        let store = AppStore(defaults: ComputerDefaults(id: "test-release-updated"))
        store.pushReceived("release_updated", ["type": "release_updated", "project_id": "p1", "release_id": "rel-1"])
        let first = store.releaseUpdated
        XCTAssertEqual(first?.releaseId, "rel-1")
        store.pushReceived("release_updated", ["type": "release_updated", "project_id": "p1", "release_id": "rel-1"])
        XCTAssertNotEqual(store.releaseUpdated, first, "a second push for the same release still reloads")
    }

    func testTheReleaseStubCarriesOwnerBlockers() async throws {
        defer { UserDefaults.standard.removeObject(forKey: InstallStubs.releaseKey) }
        let store = AppStore(defaults: ComputerDefaults(id: "test-release-stub-blockers"))
        let data = try JSONSerialization.data(withJSONObject: ["release": payload])
        UserDefaults.standard.set(String(data: data, encoding: .utf8), forKey: InstallStubs.releaseKey)
        let release = try await store.release("rel-1")
        XCTAssertEqual(release.ownerBlockers?.count, 5)
    }
}
