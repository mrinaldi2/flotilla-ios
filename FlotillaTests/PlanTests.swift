import SwiftProtobuf
import XCTest
@testable import Flotilla

/// A home that serves the plan, for the plan's view models: answers from
/// what the test set, records what was asked.
@MainActor
final class FakePlan: PlanService {
    var tree = PlanTree()
    var details: [String: PlanNodeDetail] = [:]
    var result = PlanResult()
    var docs: [String: Flotilla_Board_V1_PlanDocContent] = [:]
    private(set) var rules: [Flotilla_Board_V1_PlanRule] = []
    private(set) var creates: [Flotilla_Board_V1_PlanCreate] = []
    private(set) var reads: [Flotilla_Board_V1_PlanDocRead] = []
    private(set) var handlers: [UUID: (PlanChange) -> Void] = [:]

    func planTree(projectId: String) async throws -> PlanTree { tree }

    func planNode(_ id: String) async throws -> PlanNodeDetail {
        guard let detail = details[id] else { throw DaemonError(code: "not_found", message: "\(id) isn't in the plan.") }
        return detail
    }

    func planCreate(_ create: Flotilla_Board_V1_PlanCreate) async throws -> PlanResult {
        creates.append(create)
        return result
    }

    func planRule(_ rule: Flotilla_Board_V1_PlanRule) async throws -> PlanResult {
        rules.append(rule)
        return result
    }

    func planDocRead(_ read: Flotilla_Board_V1_PlanDocRead) async throws -> Flotilla_Board_V1_PlanDocContent {
        reads.append(read)
        return docs["\(read.offset)"] ?? Flotilla_Board_V1_PlanDocContent()
    }

    var enableError: Error?
    private(set) var enables: [Bool] = []
    private(set) var updates: [Flotilla_Board_V1_PlanUpdate] = []
    private(set) var drops: [Flotilla_Board_V1_PlanDrop] = []

    func planEnable(projectId: String, enabled: Bool) async throws -> PlanTree {
        enables.append(enabled)
        if let enableError { throw enableError }
        tree.enabled = enabled
        return tree
    }

    func planUpdate(_ update: Flotilla_Board_V1_PlanUpdate) async throws -> PlanResult {
        updates.append(update)
        return result
    }

    func planDrop(_ drop: Flotilla_Board_V1_PlanDrop) async throws -> PlanResult {
        drops.append(drop)
        return result
    }

    func followPlan(projectId: String, _ handler: @escaping (PlanChange) -> Void) async -> UUID {
        let token = UUID()
        handlers[token] = handler
        return token
    }

    func unfollowPlan(projectId: String, _ token: UUID) { handlers[token] = nil }
    func push(_ change: PlanChange) { for handler in handlers.values { handler(change) } }
}

/// flotilla#43 step 6 on the phone: the 0.21 contract's plan fixtures
/// decode, the tree reads as the canvas draws it, gates are ruled as the
/// contract says, and every part waits for its capability.
@MainActor
final class PlanTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("contract/fixtures")

    private func envelope(_ name: String) throws -> Flotilla_Wire_V1_Envelope {
        try Flotilla_Wire_V1_Envelope(jsonString: String(contentsOf: Self.fixtures.appendingPathComponent("board/messages/\(name)"),
                                                         encoding: .utf8))
    }

    private func response(_ name: String) throws -> Flotilla_Board_V1_BoardResponse.OneOf_Response {
        guard case .boardResponse(let response)? = try envelope(name).body, let answer = response.response else {
            throw DaemonError(code: "decode", message: "\(name) is not a board response")
        }
        return answer
    }

    private func request(_ name: String) throws -> Flotilla_Board_V1_BoardRequest.OneOf_Request {
        guard case .boardRequest(let request)? = try envelope(name).body, let asked = request.request else {
            throw DaemonError(code: "decode", message: "\(name) is not a board request")
        }
        return asked
    }

    private func tree() throws -> PlanTree {
        guard case .plan(let tree) = try response("response.plan.json") else { throw DaemonError(code: "decode", message: "not a plan") }
        return tree
    }

    private func node(_ id: String, kind: PlanKind = .epic, parent: String? = nil, stage: PlanStage = .running, rank: String = "a0",
                      version: UInt64 = 1) -> PlanNode {
        var node = PlanNode()
        node.id = id
        node.projectID = "p1"
        node.kind = kind
        if let parent { node.parentID = parent }
        node.title = id
        node.stage = stage
        node.rank = rank
        node.version = version
        return node
    }

    // MARK: Decoding the fixtures

    func testThePlanTreeFixtureDecodes() throws {
        let tree = try tree()
        XCTAssertTrue(tree.enabled)
        XCTAssertTrue(tree.hasRepo_p)
        XCTAssertEqual(tree.nodes.first?.kind, .goal)
        let epic = try XCTUnwrap(tree.nodes.first { $0.id == "PL-4" })
        XCTAssertEqual(epic.stage, .hld)
        XCTAssertEqual(epic.parentID, "PL-2")
        XCTAssertEqual(epic.research.state, .closed)
        XCTAssertEqual(epic.research.spikes, ["CR-12", "CR-14"])
        XCTAssertEqual(epic.gate.stage, .hld)
        XCTAssertEqual(epic.gate.children.map(\.title), ["Wind-up cue per attack tier", "Colour-blind telegraph palette"])
        XCTAssertEqual(epic.gate.round, 2)
        XCTAssertEqual(epic.version, 6)
        let prd = try XCTUnwrap(tree.nodes.first { $0.id == "PL-2" }?.docs.first)
        XCTAssertTrue(prd.changedSinceApproval)
        XCTAssertEqual(PlanWords.docState(prd), "Changed since approval")
    }

    func testANodeItsDetailAPushAndADocumentDecode() throws {
        let node = try PlanNode(jsonString: String(contentsOf: Self.fixtures.appendingPathComponent("board/plan_node.json"), encoding: .utf8))
        XCTAssertEqual(node.id, "PL-4")
        XCTAssertEqual(node.docs.map(\.kind), [.research, .design, .hld])
        XCTAssertEqual(node.docs[0].itemID, "CR-12")

        guard case .planNode(let detail) = try response("response.plan_node.json") else { return XCTFail("not a plan_node") }
        XCTAssertEqual(detail.node.id, "PL-4")

        guard case .boardPush(let push)? = try envelope("push.plan_change.json").body, case .planChange(let change)? = push.push else {
            return XCTFail("not a plan_change")
        }
        XCTAssertEqual(change.projectID, "p1")
        XCTAssertEqual(change.node.research.state, .skipped)
        XCTAssertEqual(change.actor, "bot:b-lead")

        guard case .planDoc(let doc) = try response("response.plan_doc.json") else { return XCTFail("not a plan_doc") }
        XCTAssertEqual(String(decoding: doc.data, as: UTF8.self), "# Combat readability\n")
        XCTAssertEqual(doc.total, 21)
        XCTAssertEqual(doc.mime, "text/markdown")
        XCTAssertTrue(doc.hasDiff)

        guard case .planned(let refused) = try response("response.planned.refused.json") else { return XCTFail("not planned") }
        XCTAssertEqual(PlanOutcome(refused), .refused(["Research is still open: CR-14 has no document yet. "
                                                       + "Attach the spike's research document, or ask the owner to skip research."]))
    }

    func testACardAndAnItemNameTheirPlanNode() throws {
        let card = try BoardCard(jsonString: String(contentsOf: Self.fixtures.appendingPathComponent("board/card.json"), encoding: .utf8))
        XCTAssertEqual(card.planNodeID, "PL-6")
        let item = try Flotilla_Board_V1_Item(jsonString: String(contentsOf: Self.fixtures.appendingPathComponent("board/item.json"),
                                                                 encoding: .utf8))
        XCTAssertEqual(item.planNodeID, "PL-6")
    }

    func testThePlanGateRowOfNeedsYouDecodes() throws {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixtures.appendingPathComponent("home/attention_rows.json")))
        let rows = try HomeJSON.decode(Flotilla_Home_V1_AttentionRows.self, json).rows
        let gate = try XCTUnwrap(rows.first { $0.kind == .planGate })
        XCTAssertEqual(gate.target, .planNodeID("PL-4"))
        XCTAssertEqual(gate.kindWord, "Plan")
        XCTAssertEqual(AskAction.label(gate, opens: .planNode(computerId: "mac", projectId: "p-gravity", nodeId: "PL-4")), "Review")
    }

    /// A plan push reaches the screens following its project, and only them.
    func testAPlanChangePushReachesItsProjectsFollowers() throws {
        let store = AppStore(defaults: ComputerDefaults(id: "test-plan-push"))
        var heard: [String] = []
        store.planListeners["p1"] = [UUID(): { heard.append($0.node.id) }]
        store.planListeners["p2"] = [UUID(): { _ in XCTFail("another project's screen") }]
        store.envelopePushed(try envelope("push.plan_change.json"))
        XCTAssertEqual(heard, ["PL-2"])
    }

    // MARK: The tree

    func testTheTreeListsParentsFirstSiblingsByRankAndKeepsOrphans() {
        let nodes = [node("E2", parent: "I1", rank: "b"), node("G1", kind: .goal), node("I1", kind: .initiative, parent: "G1"),
                     node("E1", parent: "I1", rank: "a"), node("F1", kind: .feature, parent: "E1"), node("X", parent: "gone")]
        let rows = PlanOutline.rows(nodes)
        XCTAssertEqual(rows.map(\.node.id), ["G1", "I1", "E1", "F1", "E2", "X"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 3, 2, 0])
        XCTAssertEqual(PlanOutline.children(of: "I1", in: nodes).map(\.id), ["E1", "E2"])
    }

    func testWhatWaitsForYouIsPinnedOldestFirstAndPillsSayYou() throws {
        var older = node("A", stage: .hld)
        older.gate.stage = .hld
        older.gate.submittedAt = Google_Protobuf_Timestamp(date: Date(timeIntervalSince1970: 100))
        var newer = node("B", kind: .initiative, stage: .proposed)
        newer.gate.stage = .proposed
        newer.gate.submittedAt = Google_Protobuf_Timestamp(date: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(PlanOutline.waiting([newer, node("C"), older]).map(\.id), ["A", "B"])
        XCTAssertEqual(PlanWords.pill(older).text, "You")
        XCTAssertEqual(PlanWords.pill(older).tone, .you)
        XCTAssertEqual(PlanWords.waits(older.gate), "HLD waits for you")
        XCTAssertEqual(PlanWords.waits(newer.gate), "Proposal waits for you")

        var feature = node("F", kind: .feature, stage: .build)
        feature.cardsTotal = 5
        feature.cardsDone = 3
        XCTAssertEqual(PlanWords.pill(feature).text, "Build 3/5")
        XCTAssertEqual(PlanWords.pill(node("L", kind: .feature, stage: .lld)).tone, .gate)
        XCTAssertEqual(PlanWords.pill(node("R", kind: .initiative, stage: .research)).tone, .research)
    }

    func testTheStageBarMarksDoneNowAndNext() {
        let states = PlanWords.stepStates(node("E", stage: .design))
        XCTAssertEqual(states.map(\.stage), [.research, .design, .hld, .running, .done])
        XCTAssertEqual(states.map(\.state), [.done, .now, .next, .next, .next])
        XCTAssertEqual(PlanWords.stepStates(node("I", kind: .initiative, stage: .proposed)).map(\.state), [.next, .next, .next, .next],
                       "a proposal has no stage yet")
        XCTAssertEqual(PlanWords.stepStates(node("I", kind: .initiative, stage: .done)).map(\.state), [.done, .done, .done, .done],
                       "a finished node has nothing now")
        XCTAssertEqual(Release.PlanItem.column("cr-done"), "Done", "an initiative board's column")
        XCTAssertEqual(Release.PlanItem.column("cr-research"), "Research")
        XCTAssertEqual(Release.PlanItem.column("my-custom"), "My-custom")
    }

    func testPlanChangesKeepTheTreeLiveAndIgnoreOlderCopies() async throws {
        let fake = FakePlan()
        fake.tree = try tree()
        let model = PlanModel(projectId: "p1", service: fake)
        await model.start()
        XCTAssertTrue(model.enabled)
        XCTAssertEqual(model.waiting.map(\.id), ["PL-4"])

        var ruled = try XCTUnwrap(model.node("PL-4"))
        ruled.clearGate()
        ruled.stage = .running
        ruled.version = 7
        var change = PlanChange()
        change.projectID = "p1"
        change.node = ruled
        fake.push(change)
        XCTAssertEqual(model.node("PL-4")?.stage, .running)
        XCTAssertTrue(model.waiting.isEmpty)

        var stale = ruled
        stale.stage = .hld
        stale.version = 6
        change.node = stale
        fake.push(change)
        XCTAssertEqual(model.node("PL-4")?.stage, .running, "an older copy is ignored")

        change.node = node("PL-9", kind: .feature, parent: "PL-4", stage: .lld)
        fake.push(change)
        XCTAssertNotNil(model.node("PL-9"), "a new node appears")
        model.stop()
        XCTAssertTrue(fake.handlers.isEmpty)
    }

    // MARK: Ruling

    func testApprovingSendsTheContractsRuleAfterFaceID() async throws {
        let fake = FakePlan()
        let epic = try XCTUnwrap(try tree().nodes.first { $0.id == "PL-4" })
        var done = epic
        done.clearGate()
        fake.result.outcome = .done(done)
        var asked: [String] = []
        let model = GateModel(node: epic, service: fake) { asked.append($0) }
        XCTAssertEqual(PlanWords.gateTitle(epic.gate), "Approve HLD")
        XCTAssertEqual(PlanWords.creates(epic.gate), "Creates 2 features")
        model.toggle(1)
        await model.approve()
        XCTAssertEqual(asked, ["Approve the HLD of Enemy attack telegraphing?"])
        guard case .planRule(let expected) = try request("request.plan_rule.json") else { return XCTFail("not a plan_rule") }
        XCTAssertEqual(fake.rules, [expected], "leave_out lists the unticked children")
        XCTAssertNotNil(model.ruled)
    }

    func testNoFaceIDNothingSentAndSendingBackNeedsANote() async throws {
        let fake = FakePlan()
        let epic = try XCTUnwrap(try tree().nodes.first { $0.id == "PL-4" })
        let model = GateModel(node: epic, service: fake) { _ in throw OwnerAuth.Failure.cancelled(.approvePlan) }
        await model.approve()
        XCTAssertTrue(fake.rules.isEmpty)
        XCTAssertEqual(model.failure, ["Not approved. Nothing was sent."])

        XCTAssertFalse(model.canSendBack, "a note first")
        await model.sendBack()
        XCTAssertTrue(fake.rules.isEmpty)
        model.note = " Add the risks of a missed cue. "
        model.toggle(0)
        fake.result.outcome = .done(epic)
        await model.sendBack()
        let rule = try XCTUnwrap(fake.rules.first)
        XCTAssertFalse(rule.approve)
        XCTAssertEqual(rule.note, "Add the risks of a missed cue.")
        XCTAssertEqual(rule.leaveOut, [], "only an approval leaves children out")
        XCTAssertEqual(rule.expectedVersion, 6)
    }

    func testAConflictSaysTheNodeChanged() async throws {
        let fake = FakePlan()
        let epic = try XCTUnwrap(try tree().nodes.first { $0.id == "PL-4" })
        var again = epic
        again.gate.round = 3
        again.version = 8
        fake.result.outcome = .conflict(again)
        let model = GateModel(node: epic, service: fake) { _ in }
        await model.approve()
        XCTAssertEqual(model.failure, ["The lead submitted it again meanwhile. Open it again to see this round."])
        XCTAssertNil(model.ruled)
    }

    func testNeedsYouWordsEachKindOfWaitingNode() {
        XCTAssertEqual([PlanAsk(.hld).yes, PlanAsk(.hld).no], ["Review", "Later"])
        XCTAssertEqual([PlanAsk(.prd).yes, PlanAsk(.design).no, PlanAsk(.lld).yes], ["Review", "Later", "Review"])
        XCTAssertEqual([PlanAsk(.proposed).yes, PlanAsk(.proposed).no], ["Accept", "Decline"])
        XCTAssertEqual([PlanAsk(.research).yes, PlanAsk(.research).no], ["Skip", "Keep research"])
        XCTAssertEqual(PlanAsk.kindWord(.hld), "HLD gate")
        XCTAssertEqual(PlanAsk.kindWord(.proposed), "Proposal")
        XCTAssertEqual(PlanAsk.kindWord(.research), "Research")
        XCTAssertEqual(PlanAsk.kindWord(nil), "Plan")
    }

    func testLaterTakesAGateOffThisPhonesList() {
        let feed = HomeFeed(cacheDirectory: nil)
        var row = HomeAttentionRow()
        row.id = "plan_gate:d-mac:PL-4"
        var home = HomeRow()
        home.projectID = "p1"
        home.topAttention = row
        let card = HomeCard(row: home, computerId: "mac", staleNames: [], staleSince: nil)
        XCTAssertEqual(feed.asks(for: card).map(\.id), ["plan_gate:d-mac:PL-4"])
        feed.putOff(row.id)
        XCTAssertTrue(feed.asks(for: card).isEmpty)
    }

    // MARK: Creating

    func testNewGoalAndNewInitiativeSendTheContractsCreate() async throws {
        let fake = FakePlan()
        fake.result.outcome = .done(node("PL-1", kind: .goal, stage: .define))
        let goal = PlanCreateModel(projectId: "p1", kind: .goal, service: fake)
        XCTAssertFalse(goal.canCreate)
        goal.title = "Improve the combat user experience "
        goal.summary = "Combat satisfaction from 3.1 to 4+/5."
        goal.due = "Playtest round 2"
        goal.lead = "b-lead"
        guard case .planCreate(let goalRequest) = try request("request.plan_create.goal.json") else { return XCTFail("not plan_create") }
        XCTAssertEqual(goal.request, goalRequest, "a goal takes no lead")
        let created = await goal.create()
        XCTAssertEqual(created?.id, "PL-1")

        let initiative = PlanCreateModel(projectId: "p1", kind: .initiative, service: fake)
        initiative.title = "Combat audio cues"
        initiative.summary = "Players with the camera turned away miss attacks."
        initiative.due = "never sent"
        XCTAssertFalse(initiative.canCreate, "an initiative needs its goal")
        initiative.goalId = "PL-1"
        initiative.lead = "b-lead"
        guard case .planCreate(let initiativeRequest) = try request("request.plan_create.json") else { return XCTFail("not plan_create") }
        XCTAssertEqual(initiative.request, initiativeRequest)

        initiative.lead = ""
        XCTAssertFalse(initiative.request.hasLead, "the project's lead when none is picked")
        fake.result.outcome = .refused({ var r = Flotilla_Board_V1_PlanRefused(); var u = BoardUnmet(); u.text = "No repository."; r.unmet = [u]; return r }())
        let refused = await initiative.create()
        XCTAssertNil(refused)
        XCTAssertEqual(initiative.failure, ["No repository."])
    }

    func testOnlyOpenGoalsTakeAnInitiative() {
        let nodes = [node("G1", kind: .goal, stage: .active), node("G2", kind: .goal, stage: .met), node("G3", kind: .goal, stage: .define),
                     node("I1", kind: .initiative, parent: "G1")]
        XCTAssertEqual(PlanOutline.openGoals(nodes).map(\.id), ["G1", "G3"])
    }

    // MARK: The owner's switch and controls

    func testPlanningTurnsOnOnlyWithARepositoryAndSaysARefusal() async throws {
        let fake = FakePlan()
        var tree = try tree()
        tree.enabled = false
        tree.hasRepo_p = false
        fake.tree = tree
        let model = PlanSwitchModel(projectId: "p1", service: fake)
        await model.load()
        XCTAssertEqual(model.title, "Turn planning on")
        XCTAssertFalse(model.canTurnOn, "no repository: the switch waits")
        await model.toggle()
        XCTAssertTrue(fake.enables.isEmpty, "nothing sent")

        fake.tree.hasRepo_p = true
        await model.load()
        fake.enableError = DaemonError(code: "plan.no_board", message: "This project is linked with another computer and has no board yet.")
        await model.toggle()
        XCTAssertEqual(fake.enables, [true])
        XCTAssertEqual(model.failure, "This project is linked with another computer and has no board yet.")
        XCTAssertFalse(model.enabled)

        fake.enableError = nil
        await model.toggle()
        XCTAssertTrue(model.enabled)
        XCTAssertNil(model.failure)
        XCTAssertEqual(model.title, "Turn planning off")
        fake.tree.hasRepo_p = false
        await model.load()
        await model.toggle()
        XCTAssertEqual(fake.enables, [true, true, false], "turning off never waits for the repository")
    }

    func testAGoalMovesByHandFromDefineToActiveToMet() async throws {
        XCTAssertEqual(PlanControls.goalStep(node("G", kind: .goal, stage: .define))?.title, "Make active")
        XCTAssertEqual(PlanControls.goalStep(node("G", kind: .goal, stage: .active))?.stage, .met)
        XCTAssertEqual(PlanControls.goalStep(node("G", kind: .goal, stage: .active))?.title, "Mark met")
        XCTAssertNil(PlanControls.goalStep(node("G", kind: .goal, stage: .met)))
        XCTAssertNil(PlanControls.goalStep(node("I", kind: .initiative, stage: .research)), "only goals move by hand")

        let fake = FakePlan()
        var goal = node("PL-1", kind: .goal, stage: .define, version: 2)
        var detail = PlanNodeDetail()
        detail.node = goal
        fake.details["PL-1"] = detail
        goal.stage = .active
        fake.result.outcome = .done(goal)
        let model = PlanNodeModel(projectId: "p1", nodeId: "PL-1", service: fake)
        await model.reload()
        let failure = await model.moveGoal(to: .active)
        XCTAssertEqual(failure, [])
        XCTAssertEqual(fake.updates.first?.id, "PL-1")
        XCTAssertEqual(fake.updates.first?.stage, .active)
        XCTAssertEqual(fake.updates.first?.expectedVersion, 2)
        XCTAssertFalse(fake.updates.first?.hasTitle ?? true, "the stage alone")
    }

    func testDropAsksFaceIDAndSaysWhatStaysAndWhatStops() async throws {
        let fake = FakePlan()
        var detail = PlanNodeDetail()
        detail.node = node("PL-2", kind: .initiative, stage: .running, version: 5)
        detail.node.title = "Combat readability"
        fake.details["PL-2"] = detail
        let model = PlanNodeModel(projectId: "p1", nodeId: "PL-2", service: fake)
        await model.reload()
        XCTAssertEqual(PlanControls.dropWarning(detail.node), "Combat readability stops. Everything under it that isn't finished "
                       + "stops with it. Its cards stay on the board. You can't undo this here.")
        XCTAssertTrue(PlanControls.canDrop(detail.node))
        XCTAssertFalse(PlanControls.canDrop(node("D", stage: .dropped)))
        XCTAssertFalse(PlanControls.canDrop(node("M", kind: .goal, stage: .met)))

        let cancelled = await model.drop(reason: "x") { _ in throw OwnerAuth.Failure.cancelled(.dropPlan) }
        XCTAssertEqual(cancelled, ["Not dropped. Nothing was sent."])
        XCTAssertTrue(fake.drops.isEmpty)

        fake.result.outcome = .done(detail.node)
        var asked: [String] = []
        let failure = await model.drop(reason: "  Folded into onboarding. ") { asked.append($0) }
        XCTAssertEqual(failure, [])
        XCTAssertEqual(asked, ["Drop Combat readability?"])
        XCTAssertEqual(fake.drops.first?.reason, "Folded into onboarding.")
        XCTAssertEqual(fake.drops.first?.expectedVersion, 5)
        _ = await model.drop(reason: " ") { _ in }
        XCTAssertFalse(fake.drops.last?.hasReason ?? true, "the reason is optional")

        var stage = Flotilla_Board_V1_PlanEvent()
        stage.kind = "stage"
        stage.note = "not this one"
        var dropped = Flotilla_Board_V1_PlanEvent()
        dropped.kind = "dropped"
        dropped.note = "Folded into onboarding."
        XCTAssertEqual(PlanControls.dropReason([stage, dropped]), "Folded into onboarding.")
        XCTAssertNil(PlanControls.dropReason([stage]))
        XCTAssertEqual(PlanNodeScreen.designStatus(node("E", stage: .dropped)), "dropped")
    }

    // MARK: Documents

    func testADocumentIsReadAtTheCommitItsFirstChunkCameFrom() async throws {
        // AppStore reads through its own requests; the chunking is the same with the fake's answers.
        let fake = FakePlan()
        var first = Flotilla_Board_V1_PlanDocContent()
        first.sha = "a8d3e55"
        first.data = Data("# Combat ".utf8)
        first.total = 21
        first.mime = "text/markdown"
        var second = Flotilla_Board_V1_PlanDocContent()
        second.sha = "a8d3e55"
        second.offset = 9
        second.data = Data("readability\n".utf8)
        second.total = 21
        fake.docs = ["0": first, "9": second]
        let file = try await PlanDocReader.read(projectId: "p1", path: "docs/prd.md", sha: nil, with: fake)
        XCTAssertEqual(file.text, "# Combat readability\n")
        XCTAssertEqual(file.mime, "text/markdown")
        XCTAssertFalse(fake.reads[0].hasSha, "the head first")
        XCTAssertEqual(fake.reads[1].sha, "a8d3e55", "then that commit")
    }

    func testTheGateShowsTheDocumentsOpening() {
        let doc = "# HLD\n\n<!-- hint -->\n\n## Context\n\nThe approved design asks for a HUD\nthat reads at a glance.\n\n## Approach\n\nMore."
        let excerpt = PlanExcerpt.of(doc)
        XCTAssertEqual(excerpt.heading, "Context")
        XCTAssertEqual(excerpt.text, "The approved design asks for a HUD that reads at a glance.")
        XCTAssertEqual(PlanExcerpt.of(String(repeating: "word ", count: 100), limit: 20).text, "word word word word…")
        XCTAssertEqual(PlanWords.docTitle("docs/x/research/prototype-results.md"), "Prototype results")
        XCTAssertEqual(PlanWords.docTitle("docs/x/hld.md"), "HLD")
    }

    // MARK: Cards: types, Research, Design links

    func testNewItemOffersTheFourTypesOnlyOnAHomeThatTakesThem() {
        let fake = FakeKanban()
        let current = QuickAddModel(projectId: "p1", boardId: "b", service: fake, itemTypesV2: true)
        XCTAssertEqual(current.types.map(\.1), ["Task", "Design", "Bug", "Spike"])
        XCTAssertEqual(current.type, .task)
        let older = QuickAddModel(projectId: "p1", boardId: "b", service: fake)
        XCTAssertEqual(older.types.map(\.1), ["Feature", "Bug", "Chore", "Spike", "Epic"], "an older home keeps its list")
        XCTAssertEqual(older.type, .feature)
    }

    func testEveryPartWaitsForItsCapability() {
        let store = AppStore(defaults: ComputerDefaults(id: "test-plan-capabilities"))
        XCTAssertFalse(store.hasPlan)
        XCTAssertFalse(store.hasItemTypesV2)
        XCTAssertFalse(store.hasResearchColumn)
        XCTAssertFalse(store.hasPlanAttention)
        store.capabilities = ["plan_v1", "item_types_v2", "column_research", "attention_plan"]
        XCTAssertTrue(store.hasPlan)
        XCTAssertTrue(store.hasItemTypesV2)
        XCTAssertTrue(store.hasResearchColumn)
        XCTAssertTrue(store.hasPlanAttention)
    }

    /// The Plan shows only when the home serves it and the owner turned planning on.
    func testThePlanShowsOnlyWhenPlanningIsOn() async throws {
        let fake = FakePlan()
        var off = try tree()
        off.enabled = false
        fake.tree = off
        let model = PlanModel(projectId: "p1", service: fake)
        await model.start()
        XCTAssertFalse(model.enabled)
        fake.tree = try tree()
        await model.reload()
        XCTAssertTrue(model.enabled)
    }

    func testBelongsToListsTheNodesWithABoardAndPicksTheirBoard() async throws {
        let plan = FakePlan()
        plan.tree = try tree()
        let model = QuickAddModel(projectId: "p1", boardId: "p1/main", service: FakeKanban(), itemTypesV2: true, plan: plan)
        await model.loadPlan()
        XCTAssertTrue(model.plans)
        XCTAssertFalse(model.homes.contains { $0.node.kind == .goal }, "a goal has no board")
        var proposed = node("I", kind: .initiative, stage: .proposed)
        proposed.boardID = "p1/audio"
        XCTAssertTrue(PlanOutline.homes(in: [proposed]).isEmpty, "not before it is accepted")
        proposed.stage = .research
        XCTAssertEqual(PlanOutline.homes(in: [proposed]).map(\.node.id), ["I"], "its research spikes, once accepted")
        XCTAssertTrue(model.homes.allSatisfy { $0.node.boardID == "p1/combat-readability" })
        model.belong(to: "PL-4")
        XCTAssertEqual(model.boardId, "p1/combat-readability")
        model.boardId = "p1/main"
        model.boardChanged()
        XCTAssertEqual(model.planNodeId, "", "another board: the node no longer applies")

        let none = QuickAddModel(projectId: "p1", boardId: "b", service: FakeKanban(), itemTypesV2: true, plan: nil)
        await none.loadPlan()
        XCTAssertFalse(none.plans, "no plan_v1: no Belongs to")
    }

    func testATaskOnTheInitiativeBoardIsCreatedAsTheContractSays() async throws {
        let fake = FakeKanban()
        var item = Flotilla_Board_V1_Item()
        item.id = "CR-28"
        fake.createResult.outcome = .done(item)
        let plan = FakePlan()
        var tree = try tree()
        var feature = node("PL-6", kind: .feature, parent: "PL-4", stage: .build)
        feature.boardID = "p1/combat-readability"
        tree.nodes.append(feature)
        plan.tree = tree
        let model = QuickAddModel(projectId: "p1", boardId: "p1/main", service: fake, itemTypesV2: true, plan: plan)
        await model.loadPlan()
        model.title = "Play-mode test for hitstop duration"
        model.belong(to: "PL-6")
        _ = await model.save()
        guard case .itemCreate(let expected) = try request("request.item_create.task.json") else { return XCTFail("not item_create") }
        XCTAssertEqual(fake.creates.first, expected)
    }

    func testCodeResearchReadsAsTheHomeReadsIt() {
        let description = "## What and why\nFaster.\n\n## Code research\n<!-- What you found in the code -->\n\n## Plan\nSteps."
        XCTAssertEqual(CodeResearch.section(in: description), "", "a hint alone isn't research")
        XCTAssertEqual(CodeResearch.removing(from: description), "## What and why\nFaster.\n\n## Plan\nSteps.")
        let filled = description.replacingOccurrences(of: "<!-- What you found in the code -->", with: "HitStop.swift scales by Time.timeScale.")
        XCTAssertEqual(CodeResearch.section(in: filled), "HitStop.swift scales by Time.timeScale.")
        XCTAssertNil(CodeResearch.section(in: "## What and why\nFaster."))
        XCTAssertTrue(CodeResearch.applies(to: .task))
        XCTAssertTrue(CodeResearch.applies(to: .bug))
        XCTAssertFalse(CodeResearch.applies(to: .spike))
        XCTAssertFalse(CodeResearch.applies(to: .design))
    }

    func testTheOverviewListsEachColumnOnceAcrossBoards() {
        let column: (String, String, Int, Int?) -> JSONDict = { key, name, count, limit in
            var row: JSONDict = ["key": key, "name": name, "category": name.lowercased(), "count": count]
            if let limit { row["wip_limit"] = limit }
            return row
        }
        let dashboard = Dashboard(["board": ["columns": [column("research", "Research", 0, nil), column("doing", "Doing", 1, 3),
                                                         column("cr-research", "Research", 1, nil), column("cr-doing", "Doing", 2, 3),
                                                         column("review", "Review", 1, 2)]]])
        XCTAssertEqual(dashboard.strip.map(\.name), ["Research", "Doing", "Review"])
        XCTAssertEqual(dashboard.strip.map(\.count), [1, 3, 1])
        XCTAssertEqual(dashboard.strip.map(\.wipLimit), [nil, nil, 2], "a limit is one board's")
    }

    func testEmptyTemplateSectionsAreLeftOut() {
        let fresh = "## What and why\n\n## Plan\n<!-- steps -->\n\n## Risk\n\n## Rollback\n\n"
        XCTAssertEqual(TemplateSections.droppingEmpty(fresh), "")
        let filled = "Intro line.\n\n## What and why\nFaster hits.\n\n## Plan\n\n## Risk\nNone."
        XCTAssertEqual(TemplateSections.droppingEmpty(filled), "Intro line.\n\n## What and why\nFaster hits.\n\n## Risk\nNone.")
    }

    func testAMoveHeldForResearchSaysCantStartYet() {
        var unmet = BoardUnmet()
        unmet.code = "start.research"
        unmet.text = "No code research is recorded yet."
        unmet.fix = "Write what you found in the code under “Code research”, or link a research document."
        var doing = Flotilla_Board_V1_ColumnCheck()
        doing.columnKey = "doing"
        doing.unmet = [unmet]
        var check = Flotilla_Board_V1_MoveCheck()
        check.columns = [doing]
        XCTAssertEqual(CodeResearch.blocks(check)?.text, "No code research is recorded yet.")
        let option = MoveOption(key: "doing", name: "Doing", visible: true, unmet: [unmet])
        XCTAssertEqual(option.verdict, "⏳ Can’t start yet")
        XCTAssertFalse(option.allowed)
        XCTAssertNil(CodeResearch.blocks(Flotilla_Board_V1_MoveCheck()))
    }

    func testTheResearchColumnIsAnActiveColumn() {
        var column = BoardColumnRow()
        column.category = .research
        XCTAssertEqual(column.effectiveKind, .active)
        XCTAssertEqual(Release.PlanItem.column("research"), "Research")
        XCTAssertEqual(CardPreview.words(.task), "Task")
        XCTAssertEqual(CardPreview.words(.design), "Design")
    }

    func testATaskShowsTheDesignsItBuilds() {
        var detail = BoardItemDetail()
        var design = Flotilla_Board_V1_ItemLink()
        design.kind = .design
        design.ref = "CR-20"
        var other = Flotilla_Board_V1_ItemLink()
        other.kind = .itemRelates
        other.ref = "CR-21"
        detail.links = [design, other, design]
        XCTAssertEqual(detail.designIds, ["CR-20"])

        var doc = ItemAttachment()
        doc.kind = "doc"
        doc.name = "design.md"
        var image = ItemAttachment()
        image.kind = "image"
        XCTAssertEqual(DesignWords.line([doc, image, image, image]), "design.md · 3 mockups")
        XCTAssertEqual(DesignWords.line([]), "No documents yet")
    }
}
