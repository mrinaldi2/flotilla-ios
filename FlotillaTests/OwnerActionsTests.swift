import XCTest
@testable import Flotilla

/// A computer that keeps owner actions: answers what the test set, records
/// what was run or rejected.
@MainActor
final class FakeOwnerActions: OwnerActionService {
    var actions: [String: OwnerAction] = [:]
    var runError: Error?
    private(set) var runs: [(id: String, sha256: String)] = []
    private(set) var rejects: [(id: String, reason: String?)] = []

    func ownerAction(_ id: String) async throws -> OwnerAction {
        guard let action = actions[id] else { throw DaemonError(code: "not_found", message: "No such action") }
        return action
    }

    func ownerActions(projectId: String?) async throws -> [OwnerAction] { Array(actions.values) }

    func runOwnerAction(id: String, sha256: String) async throws -> OwnerAction {
        runs.append((id, sha256))
        if let runError { throw runError }
        return OwnerActionsTests.action(id: id, state: "running", sha: sha256)
    }

    func rejectOwnerAction(id: String, reason: String?) async throws -> OwnerAction {
        rejects.append((id, reason))
        return OwnerActionsTests.action(id: id, state: "rejected", sha: actions[id]?.sha256 ?? "")
    }
}

/// 0.24 step 6 on the phone, push requests and owner actions: a push
/// request's details decode, the words match PhonePush, the hello says the
/// phone renders them, Run asks Face ID and sends the hash the owner saw, a
/// run on a linked computer goes to its own copy, and Reject.
@MainActor
final class OwnerActionsTests: XCTestCase {
    static func pushRow(id: String = "oa-7", state: String = "proposed", sha: String = "abc123") -> JSONDict {
        [
            "id": id, "project_id": "p1", "proposed_by": "bot:tester", "item_id": "CASS-053",
            "target_machine": "d-mac", "shell": "zsh", "cwd": "/Users/me/wt", "kind": "push",
            "content": "git push origin automation-tester/tour-lock-stack:automation-tester/tour-lock-stack",
            "pinned_files": [], "reason": "Ready for review; self-test 20/20.", "timeout_s": 600, "sha256": sha,
            "flags": [], "origin": "local", "state": state,
            "created_at": "2026-10-22T16:16:00Z", "expires_at": "2026-10-23T16:16:00Z",
            "push": ["branch": "automation-tester/tour-lock-stack", "target": "automation-tester/tour-lock-stack",
                     "repo": "mrinaldi2/gravity_os", "commit": "a334dd34f00d", "files": 2, "additions": 208, "deletions": 3,
                     "item_id": "CASS-053"],
        ]
    }

    static func action(id: String = "oa-7", state: String = "proposed", sha: String = "abc123") -> OwnerAction {
        OwnerAction(pushRow(id: id, state: state, sha: sha))
    }

    func testAPushRequestDecodes() {
        let action = Self.action()
        XCTAssertTrue(action.isPush)
        XCTAssertTrue(action.isOpen)
        XCTAssertEqual(action.botId, "tester")
        XCTAssertEqual(action.card, "CASS-053")
        XCTAssertEqual(action.push?.files, 2)
        XCTAssertEqual(action.push?.repo, "mrinaldi2/gravity_os")
        XCTAssertEqual(action.sha256, "abc123")
    }

    func testACommandWithoutKindIsACommand() {
        var row = Self.pushRow()
        row["kind"] = nil
        row["push"] = nil
        let action = OwnerAction(row)
        XCTAssertEqual(action.kind, "command", "an older daemon's action is a command")
        XCTAssertFalse(action.isPush)
        XCTAssertEqual(OwnerActionWords.run(action), "Run")
    }

    func testTheWordsMatchPhonePush() {
        let action = Self.action()
        XCTAssertEqual(OwnerActionWords.run(action), "Push")
        XCTAssertEqual(OwnerActionWords.title(action, botName: "Automation Tester"), "Automation Tester asks you to push its branch")
        XCTAssertEqual(OwnerActionWords.pushLine(action.push!), "a334dd34 · 2 files, +208 −3")
        XCTAssertEqual(OwnerActionWords.destination(action.push!), "mrinaldi2/gravity_os · automation-tester/tour-lock-stack")
        XCTAssertEqual(OwnerActionWords.expiry(action, now: WireDate.parse("2026-10-22T17:00:00Z")!), "expires in 23 h")
        XCTAssertEqual(OwnerActionWords.question(action), "Push automation-tester/tour-lock-stack?")
        XCTAssertEqual(OwnerActionWords.state(Self.action(state: "succeeded")), "Pushed")
        XCTAssertNil(OwnerActionWords.expiry(Self.action(state: "succeeded")))
    }

    /// A project whose base branch is `develop`: no text says main.
    func testAPushOnADevelopProjectNamesItsOwnBranches() {
        var row = Self.pushRow()
        row["content"] = "git push origin dev/hitstop:release-prep"
        row["push"] = ["branch": "dev/hitstop", "target": "release-prep", "repo": "mrinaldi2/phd", "commit": "9f1e2d3c4b5a",
                       "files": 1, "additions": 12, "deletions": 0]
        let action = OwnerAction(row)
        XCTAssertEqual(OwnerActionWords.destination(action.push!), "mrinaldi2/phd · dev/hitstop → release-prep")
        XCTAssertEqual(OwnerActionWords.promise(action),
                       "Runs exactly this command as you, from the bot’s worktree, once. A push to the project’s base branch is never offered here.")
        for text in [OwnerActionWords.promise(action), OwnerActionWords.destination(action.push!), OwnerActionWords.question(action),
                     OwnerActionWords.title(action, botName: "Unity Dev"), OwnerActionWords.pushLine(action.push!)] {
            XCTAssertFalse(text.contains("main"), "names main on a develop project: \(text)")
        }
    }

    func testTheHelloSaysThePhoneRendersOwnerActions() {
        XCTAssertTrue(DaemonClient.features.contains("owner_actions"), "only a client that renders them may run one")
    }

    private func model(_ service: FakeOwnerActions, runner: OwnerActionService? = nil, confirm: Bool = true) -> OwnerActionModel {
        OwnerActionModel(actionId: "oa-7", service: service, runner: { _ in runner }) { _ in
            if !confirm { throw OwnerAuth.Failure.cancelled(.runOwnerAction) }
        }
    }

    func testRunSendsTheHashTheOwnerSaw() async {
        let fake = FakeOwnerActions()
        fake.actions["oa-7"] = Self.action()
        let model = model(fake)
        await model.load()
        await model.run()
        XCTAssertEqual(fake.runs.first?.id, "oa-7")
        XCTAssertEqual(fake.runs.first?.sha256, "abc123")
        XCTAssertEqual(model.action?.state, "running")
        XCTAssertFalse(model.canAct, "once running, it can't be run twice")
    }

    func testWithoutFaceIDNothingIsSent() async {
        let fake = FakeOwnerActions()
        fake.actions["oa-7"] = Self.action()
        let model = model(fake, confirm: false)
        await model.load()
        await model.run()
        XCTAssertTrue(fake.runs.isEmpty)
        XCTAssertEqual(model.failure, "Not run. Nothing was sent.")
    }

    func testARefusalIsSaidAndTheActionReread() async {
        let fake = FakeOwnerActions()
        fake.actions["oa-7"] = Self.action()
        fake.runError = DaemonError(code: "conflict", message: "Already running")
        let model = model(fake)
        await model.load()
        await model.run()
        XCTAssertEqual(model.failure, "Already running")
        XCTAssertEqual(model.action?.state, "proposed")
    }

    func testOnALinkedComputerItsOwnCopyRuns() async {
        let here = FakeOwnerActions()
        here.actions["oa-7"] = Self.action(sha: "proposer-hash")
        let there = FakeOwnerActions()
        there.actions["oa-7"] = Self.action(sha: "target-hash")
        let model = model(here, runner: there)
        await model.load()
        await model.run()
        XCTAssertTrue(here.runs.isEmpty, "a run isn't forwarded")
        XCTAssertEqual(there.runs.first?.sha256, "target-hash")
    }

    func testRejectCarriesTheReason() async {
        let fake = FakeOwnerActions()
        fake.actions["oa-7"] = Self.action()
        let model = model(fake)
        await model.load()
        await model.reject(reason: "Not this branch")
        XCTAssertEqual(fake.rejects.first?.reason, "Not this branch")
        XCTAssertEqual(model.action?.state, "rejected")
    }

    func testAPushUpdatesTheOpenAction() async {
        let fake = FakeOwnerActions()
        fake.actions["oa-7"] = Self.action()
        let model = model(fake)
        await model.load()
        model.take(Self.action(id: "other", state: "succeeded"))
        XCTAssertEqual(model.action?.state, "proposed", "another action's push is ignored")
        model.take(Self.action(state: "succeeded"))
        XCTAssertEqual(model.action?.state, "succeeded")
    }

    func testPushesReachTheStore() {
        let store = AppStore(defaults: ComputerDefaults(id: "owner-actions-test"))
        store.pushReceived("owner_action_update", ["action": Self.pushRow(state: "running")])
        XCTAssertEqual(store.ownerActionUpdates["oa-7"]?.state, "running")
        store.pushReceived("owner_action_output", ["id": "oa-7", "chunk": "To github.com:"])
        store.pushReceived("owner_action_output", ["id": "oa-7", "chunk": " done"])
        XCTAssertEqual(store.ownerActionOutputs["oa-7"], "To github.com: done")
        store.pushReceived("commands_changed", ["bot_id": "b", "project_id": "p", "daemon_id": "d"])
        XCTAssertEqual(store.commandsRevision, 1)
        store.pushReceived("usage_updated", ["project_id": "p1"])
        XCTAssertEqual(store.usageRevision["p1"], 1)
    }

    func testOwnerActionRowsOpenTheirScreenOnlyWhereServed() {
        XCTAssertEqual(AskAction.label(rowOf(.ownerAction), opens: .ownerAction(computerId: "mac", actionId: "oa-7")), "Open")
        XCTAssertEqual(NeedsDestination.ownerAction(computerId: "mac", actionId: "oa-7").computerId, "mac")
        XCTAssertEqual(rowOf(.ownerAction).kindWord, "Run card")
    }

    private func rowOf(_ kind: HomeAttentionKind) -> HomeAttentionRow {
        var row = HomeAttentionRow()
        row.kind = kind
        row.title = "Run: Ready for review"
        row.actionID = "oa-7"
        return row
    }
}
