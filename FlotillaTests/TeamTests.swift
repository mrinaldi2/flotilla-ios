import SwiftProtobuf
import XCTest
@testable import Flotilla

/// 0.23 step 6 on the phone, the team on demand: the contract's fixtures
/// decode, Asleep and Waiting for a slot read as rest and not as failures,
/// the running counter and queue read as the desktop's, who may wake, sleep
/// or switch a bot, assigning by role, and that every part waits for
/// `team_on_demand_v1`.
@MainActor
final class TeamTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("contract/fixtures")

    private func bot(_ id: String, state: String = "ready", presence: String? = "on_demand", project: String = "p1",
                     peer: String? = nil, temporary: Bool = false) -> Bot {
        var row: JSONDict = ["id": id, "project_id": project, "name": id.capitalized, "state": state, "temporary": temporary]
        if let presence { row["presence"] = presence }
        if let peer { row["peer"] = ["name": peer, "online": true] }
        return Bot(row)
    }

    private func project(lead: String? = "lead") -> Project {
        var row: JSONDict = ["id": "p1", "name": "Recipes"]
        if let lead { row["lead_bot_id"] = lead }
        return Project(row)
    }

    private let teamRow: JSONDict = [
        "running": 4, "max_running": 6, "idle_sleep_minutes": 10,
        "queue": [
            ["bot_id": "ada", "project_id": "p1", "reason": "owner", "urgent": false, "queued_at": "2026-10-19T10:00:00Z"],
            ["bot_id": "tess", "project_id": "p1", "reason": "card", "item_id": "R-12", "priority": "P0", "urgent": true,
             "queued_at": "2026-10-19T10:01:00Z"],
            ["bot_id": "dev", "project_id": "p2", "reason": "card", "item_id": "B-3", "priority": "P2", "urgent": false,
             "queued_at": "2026-10-19T10:02:00Z"],
        ],
    ]

    // MARK: The contract

    func testAssignByRoleFixtureDecodes() throws {
        let text = try String(contentsOf: Self.fixtures.appendingPathComponent("board/messages/request.item_assign.role.json"), encoding: .utf8)
        let envelope = try Flotilla_Wire_V1_Envelope(jsonString: text)
        guard case .boardRequest(let request)? = envelope.body, case .itemAssign(let assign)? = request.request else {
            return XCTFail("not an item_assign")
        }
        XCTAssertEqual(assign.id, "H-018")
        XCTAssertTrue(assign.hasRole)
        XCTAssertEqual(assign.role, .architect)
        XCTAssertFalse(assign.hasBot)
    }

    func testEnumsFixtureNamesTheNewRoles() throws {
        let enums = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixtures.appendingPathComponent("board/enums.json"))) as? [String: Any]
        let roles = try XCTUnwrap(enums?["Role"] as? [String])
        XCTAssertTrue(roles.contains("ROLE_PRODUCT"))
        XCTAssertTrue(roles.contains("ROLE_ARCHITECT"))
        XCTAssertEqual(RoleWords.label(.product), "Product")
        XCTAssertEqual(RoleWords.label(.architect), "Architect")
        XCTAssertEqual(RoleWords.assignable, [.product, .architect, .dev, .tester])
    }

    /// The Board glance's asleep bot counts as asleep, after idle, never as stopped.
    func testOverviewFixtureCountsTheAsleepBot() throws {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixtures.appendingPathComponent("home/overview.json")))
        let row = try XCTUnwrap(try HomeJSON.decode(HomeOverview.self, json).rows.first)
        let architect = try XCTUnwrap(row.botList.first { $0.name == "Architect" })
        XCTAssertEqual(architect.status, .asleep)
        let counts = FleetCounts(row.botList, total: Int(row.bots))
        XCTAssertEqual(counts.asleep, 1)
        XCTAssertTrue(counts.words.contains("1 asleep"), counts.words)
        XCTAssertFalse(GlanceFleet.shown(row.botList).contains { $0.name == "Architect" })
    }

    func testFleetWordsWithOnlyAsleepBots() {
        var asleep = HomeBotBrief()
        asleep.status = .asleep
        let counts = FleetCounts([asleep, asleep], total: 2)
        XCTAssertEqual(counts.words, "2 asleep")
        XCTAssertEqual(counts.sentence(bots: 2), "2 bots: 2 asleep.")
    }

    // MARK: Bots

    func testAsleepAndQueuedAreRestNotFailures() {
        XCTAssertEqual(BotState.asleep.label, "Asleep")
        XCTAssertEqual(BotState.queued.label, "Waiting for a slot")
        XCTAssertTrue(BotState.asleep.isAsleep)
        XCTAssertTrue(BotState.queued.isAsleep)
        XCTAssertFalse(BotState.stopped.isAsleep)
        XCTAssertEqual(BotState.asleep.tone, .quiet)
        XCTAssertEqual(BotState.queued.tone, .quiet)
        XCTAssertFalse(BotState.asleep.needsOwner)
        XCTAssertNil(StoppedBot.reason(HomeAttentionRow()))
    }

    func testPresenceIsReadAndAbsentBeforeTheTeamOnDemand() {
        XCTAssertEqual(bot("a", presence: "always_on").presence, .alwaysOn)
        XCTAssertEqual(bot("a", presence: "on_demand").presence, .onDemand)
        XCTAssertNil(bot("a", presence: nil).presence)
        XCTAssertEqual(bot("a", state: "queued").state, .queued)
        XCTAssertEqual(BotPresence.alwaysOn.label, "Always on")
        XCTAssertEqual(BotPresence.onDemand.label, "On demand")
    }

    func testWhoMaySwitchWakeAndSleep() {
        let project = project()
        XCTAssertEqual(TeamRules.presenceLocked(bot("lead", presence: "always_on"), project: project),
                       "The project's lead is always on: it plans and hands out the work.")
        XCTAssertEqual(TeamRules.presenceLocked(bot("ios", peer: "iMac"), project: project), "Ios runs on iMac: set it there.")
        XCTAssertNotNil(TeamRules.presenceLocked(bot("worker", temporary: true), project: project))
        XCTAssertNil(TeamRules.presenceLocked(bot("ada"), project: project))

        XCTAssertTrue(TeamRules.canWake(bot("ada", state: "asleep")))
        XCTAssertTrue(TeamRules.canWake(bot("ada", state: "queued")))
        XCTAssertFalse(TeamRules.canWake(bot("ada", state: "ready")))

        XCTAssertTrue(TeamRules.canSleep(bot("ada", state: "working"), project: project))
        XCTAssertFalse(TeamRules.canSleep(bot("ada", state: "asleep"), project: project))
        XCTAssertFalse(TeamRules.canSleep(bot("ada", state: "stopped"), project: project))
        XCTAssertFalse(TeamRules.canSleep(bot("ada", presence: "always_on"), project: project))
        XCTAssertFalse(TeamRules.canSleep(bot("ada", presence: nil), project: project))
        // The lead is always on, whatever its row says.
        XCTAssertFalse(TeamRules.canSleep(bot("lead"), project: project))
    }

    // MARK: The running counter and its queue

    func testTeamStatusReadsAsTheDesktop() {
        let team = TeamStatus(teamRow)
        XCTAssertEqual(team.words, "4 of 6 running · 3 waiting")
        XCTAssertEqual(TeamStatus(running: 4, maxRunning: 6, idleSleepMinutes: 10).words, "4 of 6 running")
        XCTAssertFalse(team.full)
        XCTAssertTrue(TeamStatus(running: 6, maxRunning: 6, idleSleepMinutes: 10).full)
        XCTAssertEqual(team.idleSleepMinutes, 10)
        XCTAssertEqual(team.queue(in: "p1").map(\.botId), ["ada", "tess"])
        XCTAssertEqual(team.place(of: "tess"), 2)
        XCTAssertEqual(team.place(of: "dev"), 3)
        XCTAssertNil(team.place(of: "lead"))
    }

    func testWhyEachWakeWaits() {
        let queue = TeamStatus(teamRow).queue
        XCTAssertEqual(queue[0].words, "You woke it")
        XCTAssertEqual(queue[1].words, "Card R-12 · P0")
        XCTAssertTrue(queue[1].urgent)
        XCTAssertEqual(queue[2].words, "Card B-3 · P2")
        XCTAssertNotNil(queue[0].queuedAt)
        XCTAssertEqual(TeamWake(["bot_id": "lead", "reason": "lead"]).words, "Lead")
        XCTAssertEqual(TeamWake(["bot_id": "x", "reason": "routine"]).words, "Routine")
    }

    func testTeamUpdatedAndQueuedStateArriveAsPushes() {
        let store = AppStore(defaults: ComputerDefaults(id: "test-team"))
        XCTAssertFalse(store.hasTeamOnDemand)
        store.capabilities = [Capability023.teamOnDemand]
        XCTAssertTrue(store.hasTeamOnDemand)
        store.bots = [bot("ada", state: "asleep")]
        store.pushReceived("team_updated", ["type": "team_updated", "team": teamRow])
        XCTAssertEqual(store.team?.words, "4 of 6 running · 3 waiting")
        store.pushReceived("bot_state", ["type": "bot_state", "bot_id": "ada", "state": "queued", "reason": ""])
        XCTAssertEqual(store.bot("ada")?.state, .queued)
        store.pushReceived("bot_updated", ["type": "bot_updated", "bot": ["id": "ada", "project_id": "p1", "name": "Ada",
                                                                          "state": "queued", "presence": "always_on"]])
        XCTAssertEqual(store.bot("ada")?.presence, .alwaysOn)
    }

    // MARK: Assigning by role

    private func refused(_ code: String, _ text: String) -> Flotilla_Board_V1_EditResult {
        var unmet = BoardUnmet()
        unmet.code = code
        unmet.text = text
        var refusal = Flotilla_Board_V1_MoveRefused()
        refusal.unmet = [unmet]
        var result = Flotilla_Board_V1_EditResult()
        result.refused = refusal
        return result
    }

    func testAnUnheldRoleSaysSoInTheOwnersWords() {
        let why = CardAssign.failure(refused("role.unheld", "No bot holds the architect role."), role: .architect)
        XCTAssertEqual(why, "Nobody in this project holds the Architect role yet. Give the role to a bot in Flotilla on your computer, or assign the card to a bot by name.")
        // Other refusals keep the daemon's words.
        XCTAssertEqual(CardAssign.failure(refused("assign.guard", "Only the lead may assign.")), "Only the lead may assign.")
    }

    func testTheRoleMenuNamesWhoHoldsEachRole() {
        var ada = ProjectRoleRow()
        ada.role = .architect
        ada.botID = "ada"
        let bots = [bot("ada")]
        XCTAssertEqual(RoleWords.menuLine(.architect, roles: [ada], bots: bots), "Architect · Ada")
        XCTAssertEqual(RoleWords.menuLine(.product, roles: [ada], bots: bots), "Product · nobody yet")
        XCTAssertEqual(RoleWords.menuLine(.tester, roles: nil, bots: bots), "Tester")
    }
}
