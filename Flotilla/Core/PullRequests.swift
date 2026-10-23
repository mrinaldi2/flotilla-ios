import Foundation
import Observation

// Pull requests on the phone (H-261, `pull_requests`): a card's PRs, a
// project's list and one PR in full, with the owner's Approve, Request
// changes and Undo. Reads are binary `PrRequest`s; the owner's acts are JSON
// (`pr_review_submit`, `pr_merge_undo`), taken on the device credential. The
// words follow the desktop's (prText.ts), so both read the same.

typealias PullRequest = Flotilla_Pr_V1_PullRequest
typealias PRReview = Flotilla_Pr_V1_Review
typealias PRState = Flotilla_Pr_V1_PrState
typealias PRBlocker = Flotilla_Pr_V1_Blocker
typealias PRBlockerKind = Flotilla_Pr_V1_BlockerKind
typealias PRCheck = Flotilla_Pr_V1_CheckRun
typealias PRFinding = Flotilla_Pr_V1_Finding

/// What the phone asks a computer about its PRs.
@MainActor
protocol PullRequestService: AnyObject {
    /// Empty `states`: open and merging.
    func pullRequests(projectId: String, states: [PRState]) async throws -> [PullRequest]
    func pullRequest(projectId: String, number: UInt32) async throws -> PullRequest
    /// The owner's verdict on `sha`, the head the owner saw.
    func submitReview(projectId: String, number: UInt32, sha: String, approve: Bool, summary: String) async throws
    /// Inside the 10 s merging window only.
    func undoMerge(projectId: String, number: UInt32) async throws
}

extension AppStore: PullRequestService {
    /// The daemon serves pull requests to clients (PR-8).
    var hasPullRequests: Bool { capabilities.contains("pull_requests") }

    private func prCall(_ request: Flotilla_Pr_V1_PrRequest.OneOf_Request, name: String) async throws
        -> Flotilla_Pr_V1_PrResponse.OneOf_Response {
        var pr = Flotilla_Pr_V1_PrRequest()
        pr.request = request
        let envelope = try await client.request(.prRequest(pr), name: name)
        guard case .prResponse(let response)? = envelope.body, let answer = response.response else {
            throw DaemonError(code: "decode", message: "The Flotilla service did not answer \(name).")
        }
        return answer
    }

    func pullRequests(projectId: String, states: [PRState]) async throws -> [PullRequest] {
        var list = Flotilla_Pr_V1_PrListRequest()
        list.projectID = projectId
        list.states = states
        guard case .prList(let answer) = try await prCall(.prList(list), name: "pr_list") else {
            throw DaemonError(code: "decode", message: "The Flotilla service answered pr_list with something else.")
        }
        return answer.prs
    }

    func pullRequest(projectId: String, number: UInt32) async throws -> PullRequest {
        var get = Flotilla_Pr_V1_PrGetRequest()
        get.projectID = projectId
        get.number = number
        guard case .pr(let pr) = try await prCall(.prGet(get), name: "pr_get") else {
            throw DaemonError(code: "decode", message: "The Flotilla service answered pr_get with something else.")
        }
        return pr
    }

    func submitReview(projectId: String, number: UInt32, sha: String, approve: Bool, summary: String) async throws {
        var fields: JSONDict = ["project_id": projectId, "number": Int(number), "sha": sha,
                                "verdict": approve ? "approved" : "changes_requested"]
        if !summary.trimmed.isEmpty { fields["summary"] = summary.trimmed }
        _ = try await client.request("pr_review_submit", fields)
    }

    func undoMerge(projectId: String, number: UInt32) async throws {
        _ = try await client.request("pr_merge_undo", ["project_id": projectId, "number": Int(number)])
    }

    /// A `PrPush`: the screens showing that project's PRs read again.
    func prPushed(_ push: Flotilla_Pr_V1_PrPush) {
        let project: String
        switch push.push {
        case .prUpdated(let updated)?: project = updated.projectID
        case .checkUpdated(let updated)?: project = updated.projectID
        case .mergeQueueChanged(let changed)?: project = changed.projectID
        case .cleanupUpdated(let updated)?: project = updated.projectID
        case nil: return
        }
        prRevision[project, default: 0] += 1
    }
}

/// A tone for a PR's words: ok, warn, bad, you or dim, never colour alone.
enum PRTone: Equatable {
    case ok, warn, bad, you, dim

    var tone: Tone {
        switch self {
        case .ok: .ready
        case .warn: .needsYou
        case .bad: .failed
        case .you: .working
        case .dim: .quiet
        }
    }
}

/// A PR in the glossary's words, as the desktop says it.
enum PRWords {
    static let ownerRole = "owner"

    /// The branch it lands on: the project's (`develop`), `main` from an older service.
    static func base(_ pr: PullRequest) -> String { pr.base.isEmpty ? "main" : pr.base }

    /// "architect" → "Architect"; an unknown role keeps its name, capitalised.
    static func role(_ role: String) -> String {
        switch role {
        case "architect": "Architect"
        case "ux": "UX"
        case "ce": "CE"
        case "devops": "DevOps"
        case "qa": "QA"
        case ownerRole: "You"
        default: role.capitalizedFirst
        }
    }

    static func sha7(_ sha: String) -> String { String(sha.prefix(7)) }

    /// "you", "you, and CE", "you, CE, and checks".
    static func join(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + ", and " + names.last!
    }

    private static let reviewKinds: Set<PRBlockerKind> = [.reviewMissing, .changesRequested, .unresolvedMust]
    private static let checkKinds: Set<PRBlockerKind> = [.checkPending, .checkFailed]
    private static let branchKinds: Set<PRBlockerKind> = [.behindMain, .conflicts, .movedUnreported]

    private static func has(_ pr: PullRequest, _ kind: PRBlockerKind) -> Bool {
        pr.mergeable.blockers.contains { $0.kind == kind }
    }

    /// Who and what an open PR waits for: "you, and CE", "checks".
    static func waitingFor(_ pr: PullRequest) -> String {
        var names: [String] = []
        func add(_ name: String) { if !names.contains(name) { names.append(name) } }
        if has(pr, .ownerReview) { add("you") }
        for blocker in pr.mergeable.blockers {
            if reviewKinds.contains(blocker.kind) {
                add(blocker.subject == ownerRole ? "you" : role(blocker.subject))
            } else if checkKinds.contains(blocker.kind) {
                add("checks")
            }
        }
        return join(names)
    }

    /// What else holds it back, in the daemon's words: behind its base, conflicts, the card.
    static func otherBlockers(_ pr: PullRequest) -> [PRBlocker] {
        pr.mergeable.blockers.filter {
            $0.kind != .ownerReview && $0.kind != .notOpen && !reviewKinds.contains($0.kind) && !checkKinds.contains($0.kind)
        }
    }

    /// The owner's review is what it waits on now: the reviewers are done and the branch is current.
    static func waitsForYou(_ pr: PullRequest) -> Bool {
        pr.state == .open && has(pr, .ownerReview)
            && !pr.mergeable.blockers.contains { branchKinds.contains($0.kind) || (reviewKinds.contains($0.kind) && $0.subject != ownerRole) }
    }

    /// "Merges into develop when every review is in and checks pass."
    static func mergeRule(_ pr: PullRequest) -> String {
        "Merges into \(base(pr)) when every review is in and checks pass."
    }

    /// "✓ Merged into develop · 14:02", "Merging into develop…", "Closed without merging · 8 Oct, 12:20"; nil while open.
    static func doneLine(_ pr: PullRequest, now: Date = Date()) -> String? {
        switch pr.state {
        case .merged: return "✓ Merged into \(base(pr)) · \(clock(pr.hasMergedAt ? pr.mergedAt.date : nil, now: now))"
        case .merging:
            return pr.mergeWaiting == "no_devops"
                ? "Approved: nobody holds DevOps to merge it into \(base(pr))"
                : "Merging into \(base(pr))…"
        case .closed: return "Closed without merging · \(clock(pr.hasClosedAt ? pr.closedAt.date : nil, now: now))"
        default: return nil
        }
    }

    /// The one line a PR's row shows: how it ended, or what it waits for.
    static func stateLine(_ pr: PullRequest, now: Date = Date()) -> String {
        if let done = doneLine(pr, now: now) { return done }
        if pr.mergeable.ok { return "Everything is in: it merges into \(base(pr)) next" }
        if has(pr, .conflicts) { return "⚠ Has conflicts with \(base(pr)): waiting for \(pr.author.name.isEmpty ? "the author" : pr.author.name)" }
        if has(pr, .behindMain) { return "⇣ Needs update with \(base(pr))" }
        let waiting = waitingFor(pr)
        if !waiting.isEmpty { return "Waiting for: \(waiting)" }
        return otherBlockers(pr).first?.text ?? "Open"
    }

    static func stateTone(_ pr: PullRequest) -> PRTone {
        switch pr.state {
        case .merged: return .ok
        case .merging: return pr.mergeWaiting == "no_devops" ? .warn : .ok
        case .closed: return .dim
        default:
            if pr.mergeable.ok { return .ok }
            if has(pr, .conflicts) || has(pr, .checkFailed) || has(pr, .changesRequested) { return .warn }
            return waitsForYou(pr) ? .you : .dim
        }
    }

    /// "14:02" today, "8 Oct, 14:02" another day.
    static func clock(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        return Calendar.current.isDate(date, inSameDayAs: now) ? time : "\(date.formatted(.dateTime.day().month(.abbreviated))), \(time)"
    }

    // MARK: Reviews

    /// The role's latest review: reviews come oldest first, and a role reviews each new head.
    static func review(_ pr: PullRequest, role: String) -> PRReview? {
        pr.reviews.last { $0.role == role }
    }

    /// The roles a PR shows rows for: you first, then the required roles, then anyone else who reviewed.
    static func roles(_ pr: PullRequest) -> [String] {
        var roles = pr.requiredRoles
        if pr.ownerReviewRequired || pr.ownerFlagged { roles.append(ownerRole) }
        roles += pr.reviews.map(\.role)
        roles += pr.waivers.map(\.role)
        var seen = Set<String>()
        let unique = roles.filter { !$0.isEmpty && seen.insert($0).inserted }
        return unique.filter { $0 == ownerRole } + unique.filter { $0 != ownerRole }
    }

    struct ReviewState: Equatable {
        let glyph: String
        let text: String
        let tone: PRTone
    }

    /// "✓ Approved f0678fc", "⟳ Approved c79c8b5, an older commit", "✕ Asked for changes", "○ Waiting".
    static func reviewState(_ pr: PullRequest, role: String) -> ReviewState {
        let review = Self.review(pr, role: role)
        if review?.verdict == .approved, let review {
            return review.stale
                ? ReviewState(glyph: "⟳", text: "Approved \(sha7(review.sha)), an older commit", tone: .warn)
                : ReviewState(glyph: "✓", text: "Approved \(sha7(review.sha))", tone: .ok)
        }
        if review?.verdict == .changesRequested { return ReviewState(glyph: "✕", text: "Asked for changes", tone: .bad) }
        if role == ownerRole, waitsForYou(pr) { return ReviewState(glyph: "▲", text: "Waiting for your review", tone: .you) }
        return ReviewState(glyph: "○", text: "Waiting", tone: .dim)
    }

    /// A chip on a row: "✓ Architect", "⟳ CE approved an older commit", "▲ You".
    static func chip(_ pr: PullRequest, role: String) -> (text: String, tone: PRTone) {
        let who = self.role(role)
        let state = reviewState(pr, role: role)
        switch state.glyph {
        case "✓": return ("✓ \(who)", .ok)
        case "⟳": return ("⟳ \(who) approved an older commit", .warn)
        case "✕": return ("✕ \(who) asked for changes", .bad)
        case "▲": return ("▲ You", .you)
        default:
            if role != ownerRole { return ("○ \(who)", .dim) }
            return (has(pr, .behindMain) ? "○ You after the update" : "○ You after reviewers", .dim)
        }
    }

    /// Who wrote a review, and what they said: "Ada · “Looks right”", "You · iPhone".
    static func reviewMeta(_ pr: PullRequest, role: String) -> String {
        if let review = Self.review(pr, role: role) {
            let who: String
            switch review.reviewer.who {
            case .owner(let owner)?: who = owner.deviceName.isEmpty ? "You" : "You · \(owner.deviceName)"
            case .bot(let bot)?: who = bot.name.isEmpty ? self.role(role) : bot.name
            case nil: who = self.role(role)
            }
            return review.summary.isEmpty ? who : "\(who) · “\(review.summary)”"
        }
        if let waiver = pr.waivers.first(where: { $0.role == role }) {
            return "Not needed: \(waiver.reason) (\(waiver.by.name.isEmpty ? "the lead" : waiver.by.name))"
        }
        if role != ownerRole { return "Asked to review" }
        if let wait = pr.mergeable.blockers.first(where: { $0.subject == ownerRole })?.text, !wait.isEmpty { return wait }
        return pr.ownerFlagged ? "Flagged for you: \(pr.ownerFlagReason)" : "Your review"
    }

    /// The owner approved the head as it is now.
    static func youApproved(_ pr: PullRequest) -> Bool {
        guard let review = Self.review(pr, role: ownerRole) else { return false }
        return review.verdict == .approved && !review.stale
    }

    // MARK: Findings and checks

    /// Every finding of each role's latest review, with whose it is.
    static func findings(_ pr: PullRequest) -> [(role: String, finding: PRFinding)] {
        roles(pr).compactMap { role in Self.review(pr, role: role).map { (role, $0) } }
            .flatMap { role, review in review.findings.map { (role, $0) } }
    }

    /// "☑ Fixed in 3f2a1b0" or "☐ Open".
    static func findingState(_ finding: PRFinding) -> (text: String, open: Bool) {
        finding.resolvedIn.isEmpty ? ("☐ Open", true) : ("☑ Fixed in \(sha7(finding.resolvedIn))", false)
    }

    static func severity(_ finding: PRFinding) -> String {
        switch finding.severity {
        case .must: "Must"
        case .should: "Should"
        case .nit: "Nit"
        default: "Note"
        }
    }

    /// "✓ Passed", "✕ Failed", "◌ Running", "○ Queued", "No computer can run this".
    static func check(_ check: PRCheck) -> (text: String, tone: PRTone) {
        switch check.result {
        case .pass: return ("✓ Passed", .ok)
        case .fail: return ("✕ Failed", .bad)
        case .error: return ("✕ Couldn’t run", .bad)
        case .running: return ("◌ Running", .you)
        case .queued: return (check.unroutable ? "No computer can run this" : "○ Queued", check.unroutable ? .warn : .dim)
        default: return ("○ Waiting", .dim)
        }
    }

    // MARK: The list

    /// Open and merging first, then merged and closed; newest first within each.
    static func ordered(_ prs: [PullRequest]) -> [PullRequest] {
        func rank(_ pr: PullRequest) -> Int {
            switch pr.state {
            case .merging: 0
            case .open: 1
            case .merged: 2
            default: 3
            }
        }
        func when(_ pr: PullRequest) -> Date {
            switch pr.state {
            case .merged: pr.hasMergedAt ? pr.mergedAt.date : .distantPast
            case .closed: pr.hasClosedAt ? pr.closedAt.date : .distantPast
            default: pr.hasOpenedAt ? pr.openedAt.date : .distantPast
            }
        }
        return prs.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if when(a) != when(b) { return when(a) > when(b) }
            return a.number > b.number
        }
    }

    /// "#42 · Hitstop on heavy hits".
    static func title(_ pr: PullRequest) -> String {
        "#\(pr.number) · \(pr.title.isEmpty ? (pr.itemTitle.isEmpty ? pr.branch : pr.itemTitle) : pr.title)"
    }

    /// "Unity Dev · dev/hitstop → develop · +208 −3".
    static func meta(_ pr: PullRequest) -> String {
        var parts: [String] = []
        if !pr.author.name.isEmpty { parts.append(pr.author.name) }
        parts.append("\(pr.branch) → \(base(pr))")
        if pr.additions > 0 || pr.deletions > 0 { parts.append("+\(pr.additions) −\(pr.deletions)") }
        return parts.joined(separator: " · ")
    }

    static let allStates: [PRState] = [.open, .merging, .merged, .closed]
}

/// The owner's acts on one PR: Approve and Request changes on the head the
/// owner saw, and Undo while it merges.
@MainActor @Observable
final class PRReviewModel {
    let projectId: String
    let number: UInt32
    private(set) var pr: PullRequest?
    private(set) var busy = false
    private(set) var failure: String?
    private(set) var loadFailure: String?
    var note = ""

    @ObservationIgnored private let service: PullRequestService

    init(projectId: String, number: UInt32, service: PullRequestService) {
        self.projectId = projectId
        self.number = number
        self.service = service
    }

    func load() async {
        do {
            pr = try await service.pullRequest(projectId: projectId, number: number)
            loadFailure = nil
        } catch {
            loadFailure = error.localizedDescription
        }
    }

    /// The owner may give a verdict: the PR is open.
    var canReview: Bool { pr?.state == .open && !busy }
    /// Changes need a note for the author.
    var canRequestChanges: Bool { canReview && !note.trimmed.isEmpty }

    /// The merging window is still open.
    func canUndo(now: Date = Date()) -> Bool {
        guard let pr, pr.state == .merging, pr.mergeWaiting.isEmpty, !busy else { return false }
        return !pr.hasMergeAt || pr.mergeAt.date > now
    }

    /// Whole seconds left in the window.
    func secondsLeft(now: Date = Date()) -> Int {
        guard let pr, pr.hasMergeAt else { return 0 }
        return max(0, Int(pr.mergeAt.date.timeIntervalSince(now).rounded(.up)))
    }

    func approve() async { await review(approve: true) }

    func requestChanges() async {
        guard canRequestChanges else { return }
        await review(approve: false)
    }

    private func review(approve: Bool) async {
        guard let pr, canReview else { return }
        busy = true
        failure = nil
        defer { busy = false }
        do {
            try await service.submitReview(projectId: projectId, number: number, sha: pr.headSha, approve: approve,
                                           summary: note)
            note = ""
        } catch {
            failure = error.localizedDescription
        }
        await load()
    }

    func undo() async {
        guard canUndo() else { return }
        busy = true
        failure = nil
        defer { busy = false }
        do {
            try await service.undoMerge(projectId: projectId, number: number)
        } catch {
            failure = error.localizedDescription
        }
        await load()
    }
}
