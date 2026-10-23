import SwiftProtobuf
import XCTest
@testable import Flotilla

/// A computer that keeps PRs: answers what the test set, records the owner's acts.
@MainActor
final class FakePullRequests: PullRequestService {
    var prs: [UInt32: PullRequest] = [:]
    var error: Error?
    private(set) var reviews: [(number: UInt32, sha: String, approve: Bool, summary: String)] = []
    private(set) var undos: [UInt32] = []
    private(set) var listed: [[PRState]] = []

    func pullRequests(projectId: String, states: [PRState]) async throws -> [PullRequest] {
        listed.append(states)
        return Array(prs.values)
    }

    func pullRequest(projectId: String, number: UInt32) async throws -> PullRequest {
        guard let pr = prs[number] else { throw DaemonError(code: "not_found", message: "No PR #\(number)") }
        return pr
    }

    func submitReview(projectId: String, number: UInt32, sha: String, approve: Bool, summary: String) async throws {
        if let error { throw error }
        reviews.append((number, sha, approve, summary))
        var pr = prs[number]!
        var review = PRReview()
        review.role = "owner"
        review.sha = sha
        review.verdict = approve ? .approved : .changesRequested
        pr.reviews.append(review)
        prs[number] = pr
    }

    func undoMerge(projectId: String, number: UInt32) async throws {
        if let error { throw error }
        undos.append(number)
        prs[number]?.state = .open
    }
}

/// Pull requests on the phone (H-261): the state lines name the PR's own
/// base (`develop`), each role shows its latest review (they come oldest
/// first), findings read fixed or open, the list's order, and the owner's
/// Approve, Request changes and Undo.
@MainActor
final class PullRequestsTests: XCTestCase {
    static func pr(_ number: UInt32 = 42, state: PRState = .open, base: String = "develop") -> PullRequest {
        var pr = PullRequest()
        pr.projectID = "phd"
        pr.number = number
        pr.itemID = "CASS-053"
        pr.itemTitle = "tour_lock.py stack check"
        pr.title = "Stack check before every tour"
        pr.branch = "automation-tester/tour-lock-stack"
        pr.base = base
        pr.headSha = "a334dd34f00d"
        pr.state = state
        pr.author.name = "Automation Tester"
        pr.additions = 208
        pr.deletions = 3
        return pr
    }

    static func blocker(_ kind: PRBlockerKind, _ subject: String = "", text: String = "") -> PRBlocker {
        var blocker = PRBlocker()
        blocker.kind = kind
        blocker.subject = subject
        blocker.text = text
        return blocker
    }

    static func review(_ role: String, _ verdict: Flotilla_Pr_V1_Verdict, sha: String, stale: Bool = false, by name: String = "") -> PRReview {
        var review = PRReview()
        review.role = role
        review.verdict = verdict
        review.sha = sha
        review.stale = stale
        if !name.isEmpty { review.reviewer.bot.name = name }
        return review
    }

    // MARK: State lines, on a project whose base is develop

    func testEveryLineNamesThePRsBase() {
        let now = Date()
        var merged = Self.pr(state: .merged)
        merged.mergedAt = Google_Protobuf_Timestamp(date: now)
        XCTAssertTrue(PRWords.stateLine(merged, now: now).hasPrefix("✓ Merged into develop · "))
        XCTAssertEqual(PRWords.stateLine(Self.pr(state: .merging), now: now), "Merging into develop…")
        var stuck = Self.pr(state: .merging)
        stuck.mergeWaiting = "no_devops"
        XCTAssertEqual(PRWords.stateLine(stuck), "Approved: nobody holds DevOps to merge it into develop")
        XCTAssertTrue(PRWords.stateLine(Self.pr(state: .closed)).hasPrefix("Closed without merging"))
        var ready = Self.pr()
        ready.mergeable.ok = true
        XCTAssertEqual(PRWords.stateLine(ready), "Everything is in: it merges into develop next")
        XCTAssertEqual(PRWords.mergeRule(ready), "Merges into develop when every review is in and checks pass.")
        var behind = Self.pr()
        behind.mergeable.blockers = [Self.blocker(.behindMain), Self.blocker(.ownerReview)]
        XCTAssertEqual(PRWords.stateLine(behind), "⇣ Needs update with develop")
        var conflicts = Self.pr()
        conflicts.mergeable.blockers = [Self.blocker(.conflicts)]
        XCTAssertEqual(PRWords.stateLine(conflicts), "⚠ Has conflicts with develop: waiting for Automation Tester")
        for pr in [merged, ready, behind, conflicts, Self.pr(state: .merging)] {
            XCTAssertFalse(PRWords.stateLine(pr, now: now).contains("main"), PRWords.stateLine(pr, now: now))
        }
    }

    func testAnOlderServiceWithoutABaseSaysMain() {
        var ready = Self.pr(base: "")
        ready.mergeable.ok = true
        XCTAssertEqual(PRWords.stateLine(ready), "Everything is in: it merges into main next")
        XCTAssertEqual(PRWords.base(ready), "main")
    }

    func testWaitingForNamesYouRolesAndChecks() {
        var pr = Self.pr()
        pr.mergeable.blockers = [Self.blocker(.ownerReview, "owner"), Self.blocker(.reviewMissing, "ce"),
                                 Self.blocker(.checkPending, "unit"), Self.blocker(.checkFailed, "lint")]
        XCTAssertEqual(PRWords.waitingFor(pr), "you, CE, and checks")
        XCTAssertEqual(PRWords.stateLine(pr), "Waiting for: you, CE, and checks")
        XCTAssertFalse(PRWords.waitsForYou(pr), "CE hasn't approved yet")
        pr.mergeable.blockers = [Self.blocker(.ownerReview, "owner")]
        XCTAssertEqual(PRWords.stateLine(pr), "Waiting for: you")
        XCTAssertTrue(PRWords.waitsForYou(pr))
        XCTAssertEqual(PRWords.stateTone(pr), .you)
    }

    // MARK: Reviews: the latest per role

    func testEachRoleShowsItsLatestReview() {
        var pr = Self.pr()
        pr.requiredRoles = ["architect", "ce"]
        // Oldest first: the Architect's stale approval on an older commit, then a fresh one on the head.
        pr.reviews = [Self.review("architect", .approved, sha: "c79c8b5aa", stale: true, by: "Ada"),
                      Self.review("ce", .changesRequested, sha: "c79c8b5aa", by: "Sec"),
                      Self.review("architect", .approved, sha: "a334dd34f00d", by: "Ada")]
        XCTAssertEqual(PRWords.review(pr, role: "architect")?.sha, "a334dd34f00d")
        XCTAssertEqual(PRWords.reviewState(pr, role: "architect"), .init(glyph: "✓", text: "Approved a334dd3", tone: .ok))
        XCTAssertEqual(PRWords.chip(pr, role: "architect").text, "✓ Architect", "not \"approved an older commit\"")
        XCTAssertEqual(PRWords.chip(pr, role: "ce").text, "✕ CE asked for changes")
        XCTAssertEqual(PRWords.roles(pr), ["architect", "ce"], "a role is listed once")

        // A stale approval that is the latest still reads as one.
        pr.reviews.append(Self.review("ce", .approved, sha: "c79c8b5aa", stale: true))
        XCTAssertEqual(PRWords.chip(pr, role: "ce").text, "⟳ CE approved an older commit")
        XCTAssertEqual(PRWords.reviewState(pr, role: "ce").text, "Approved c79c8b5, an older commit")
    }

    func testTheOwnerComesFirstAndReadsAsYou() {
        var pr = Self.pr()
        pr.requiredRoles = ["architect"]
        pr.ownerReviewRequired = true
        pr.mergeable.blockers = [Self.blocker(.ownerReview, "owner", text: "Your review, after Architect")]
        XCTAssertEqual(PRWords.roles(pr), ["owner", "architect"])
        XCTAssertEqual(PRWords.reviewState(pr, role: "owner").text, "Waiting for your review")
        XCTAssertEqual(PRWords.chip(pr, role: "owner").text, "▲ You")
        XCTAssertFalse(PRWords.youApproved(pr))
        var mine = Self.review("owner", .approved, sha: pr.headSha)
        mine.reviewer.owner.deviceName = "iPhone"
        pr.reviews = [mine]
        XCTAssertTrue(PRWords.youApproved(pr))
        XCTAssertEqual(PRWords.reviewMeta(pr, role: "owner"), "You · iPhone")
        XCTAssertEqual(PRWords.role("owner"), "You")
    }

    // MARK: Findings and checks

    func testFindingsReadFixedOrOpen() {
        var pr = Self.pr()
        pr.requiredRoles = ["architect"]
        var review = Self.review("architect", .approved, sha: pr.headSha)
        var fixed = PRFinding()
        fixed.severity = .must
        fixed.text = "Check MinIO before the tour"
        fixed.resolvedIn = "9f1e2d3c4b"
        var open = PRFinding()
        open.severity = .nit
        open.text = "Name the exit code"
        open.path = "Tools/tour_lock.py"
        open.line = 12
        review.findings = [fixed, open]
        pr.reviews = [review]
        let all = PRWords.findings(pr)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(PRWords.findingState(all[0].finding).text, "☑ Fixed in 9f1e2d3")
        XCTAssertEqual(PRWords.findingState(all[1].finding).text, "☐ Open")
        XCTAssertEqual(PRWords.severity(all[0].finding), "Must")
        var check = PRCheck()
        check.result = .queued
        check.unroutable = true
        XCTAssertEqual(PRWords.check(check).text, "No computer can run this")
        check.result = .pass
        XCTAssertEqual(PRWords.check(check).text, "✓ Passed")
    }

    func testTheListPutsOpenAndMergingFirst() {
        let merged = Self.pr(1, state: .merged)
        let open = Self.pr(2)
        let closed = Self.pr(3, state: .closed)
        let merging = Self.pr(4, state: .merging)
        XCTAssertEqual(PRWords.ordered([merged, open, closed, merging]).map(\.number), [4, 2, 1, 3])
        XCTAssertEqual(PRWords.title(open), "#2 · Stack check before every tour")
        XCTAssertEqual(PRWords.meta(open), "Automation Tester · automation-tester/tour-lock-stack → develop · +208 −3")
    }

    // MARK: The owner's acts

    func testApproveIsOnTheHeadTheOwnerSaw() async {
        let fake = FakePullRequests()
        fake.prs[42] = Self.pr()
        let model = PRReviewModel(projectId: "phd", number: 42, service: fake)
        await model.load()
        XCTAssertTrue(model.canReview)
        await model.approve()
        XCTAssertEqual(fake.reviews.first?.sha, "a334dd34f00d")
        XCTAssertEqual(fake.reviews.first?.approve, true)
        XCTAssertTrue(PRWords.youApproved(model.pr!), "read again after the review")
    }

    func testRequestChangesNeedsANote() async {
        let fake = FakePullRequests()
        fake.prs[42] = Self.pr()
        let model = PRReviewModel(projectId: "phd", number: 42, service: fake)
        await model.load()
        XCTAssertFalse(model.canRequestChanges)
        await model.requestChanges()
        XCTAssertTrue(fake.reviews.isEmpty, "no note: nothing sent")
        model.note = " Check MinIO first. "
        await model.requestChanges()
        XCTAssertEqual(fake.reviews.first?.approve, false)
        XCTAssertEqual(fake.reviews.first?.summary, " Check MinIO first. ")
        XCTAssertEqual(model.note, "", "cleared once sent")
    }

    func testARefusalIsSaid() async {
        let fake = FakePullRequests()
        fake.prs[42] = Self.pr()
        fake.error = DaemonError(code: "forbidden", message: "Approve on mac or your phone")
        let model = PRReviewModel(projectId: "phd", number: 42, service: fake)
        await model.load()
        await model.approve()
        XCTAssertEqual(model.failure, "Approve on mac or your phone")
    }

    func testUndoOnlyInsideTheWindow() async {
        let fake = FakePullRequests()
        var merging = Self.pr(state: .merging)
        merging.mergeAt = Google_Protobuf_Timestamp(date: Date().addingTimeInterval(8))
        fake.prs[42] = merging
        let model = PRReviewModel(projectId: "phd", number: 42, service: fake)
        await model.load()
        XCTAssertTrue(model.canUndo())
        XCTAssertEqual(model.secondsLeft(), 8)
        XCTAssertFalse(model.canUndo(now: Date().addingTimeInterval(20)), "after the window it is handed to DevOps")
        XCTAssertFalse(model.canReview, "no verdict while merging")
        await model.undo()
        XCTAssertEqual(fake.undos, [42])
        XCTAssertEqual(model.pr?.state, .open)

        var handed = Self.pr(state: .merging)
        handed.mergeWaiting = "no_devops"
        fake.prs[43] = handed
        let stuck = PRReviewModel(projectId: "phd", number: 43, service: fake)
        await stuck.load()
        XCTAssertFalse(stuck.canUndo(), "past the window, waiting for DevOps")
    }

    // MARK: Wiring

    func testAPRReviewRowOpensThePR() {
        XCTAssertEqual(NeedsDestination.pullRequest(computerId: "mac", projectId: "phd", number: 42).computerId, "mac")
        var row = HomeAttentionRow()
        row.kind = .prReview
        row.prNumber = 42
        XCTAssertEqual(AskAction.label(row, opens: .pullRequest(computerId: "mac", projectId: "phd", number: 42)), "Review")
        XCTAssertEqual(row.kindWord, "Pull request")
    }

    func testPushesReachTheStoreAndTheCapabilityGates() {
        let store = AppStore(defaults: ComputerDefaults(id: "pr-test"))
        XCTAssertFalse(store.hasPullRequests)
        store.capabilities = ["pull_requests"]
        XCTAssertTrue(store.hasPullRequests)
        var push = Flotilla_Pr_V1_PrPush()
        push.prUpdated.projectID = "phd"
        push.prUpdated.number = 42
        var envelope = Flotilla_Wire_V1_Envelope()
        envelope.body = .prPush(push)
        store.envelopePushed(envelope)
        XCTAssertEqual(store.prRevision["phd"], 1)
    }
}
