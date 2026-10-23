import Foundation
import Observation

// Questions for the owner (0.22.0, capability `questions_v1`): one record per
// question a bot asks, on a card and/or a plan node, answered once where the
// owner sees it (the card, the plan node, the project's list, Needs you).
// A question is a decision of kind `question`; these are the board's typed
// requests for it (`question_list`, `question_answer`, `question_dismiss`).

typealias Question = Flotilla_Board_V1_Question
typealias QuestionState = Flotilla_Board_V1_QuestionState
typealias QuestionChange = Flotilla_Board_V1_QuestionChange
typealias QuestionPage = Flotilla_Board_V1_QuestionPage
typealias QuestionResult = Flotilla_Board_V1_QuestionResult

/// The 0.22 capabilities, each gating its own part: an older daemon keeps
/// the phone as it was.
enum Capability022 {
    /// Questions on cards and plan nodes, their requests and pushes, `QUESTION` rows.
    static let questions = "questions_v1"
    /// `list_artifacts {group}` with `used_by` and `kept`, `artifact_keep`, `artifact_trash`.
    static let artifacts = "artifacts_v2"
}

extension AppStore {
    var hasQuestions: Bool { capabilities.contains(Capability022.questions) }
    var hasArtifactsV2: Bool { capabilities.contains(Capability022.artifacts) }
}

// MARK: Requests

/// The questions' requests, behind a protocol so the models run in tests without a daemon.
@MainActor
protocol QuestionService: AnyObject {
    func questionList(_ list: Flotilla_Board_V1_QuestionList) async throws -> QuestionPage
    func questionAnswer(_ answer: Flotilla_Board_V1_QuestionAnswer) async throws -> QuestionResult
    func questionDismiss(_ dismiss: Flotilla_Board_V1_QuestionDismiss) async throws -> QuestionResult
    /// `question_change` pushes for a project reach `handler` while it follows
    /// (the daemon sends them to connections that watch the project's board).
    func followQuestions(projectId: String, _ handler: @escaping (QuestionChange) -> Void) async -> UUID
    func unfollowQuestions(projectId: String, _ token: UUID)
}

extension AppStore: QuestionService {
    private func unexpectedQuestion(_ name: String) -> DaemonError {
        DaemonError(code: "decode", message: "The Flotilla service answered \(name) with something else.")
    }

    func questionList(_ list: Flotilla_Board_V1_QuestionList) async throws -> QuestionPage {
        guard case .questions(let page) = try await boardCall(.questionList(list), name: "question_list") else {
            throw unexpectedQuestion("question_list")
        }
        return page
    }

    func questionAnswer(_ answer: Flotilla_Board_V1_QuestionAnswer) async throws -> QuestionResult {
        guard case .questioned(let result) = try await boardCall(.questionAnswer(answer), name: "question_answer") else {
            throw unexpectedQuestion("question_answer")
        }
        return result
    }

    func questionDismiss(_ dismiss: Flotilla_Board_V1_QuestionDismiss) async throws -> QuestionResult {
        guard case .questioned(let result) = try await boardCall(.questionDismiss(dismiss), name: "question_dismiss") else {
            throw unexpectedQuestion("question_dismiss")
        }
        return result
    }

    func followQuestions(projectId: String, _ handler: @escaping (QuestionChange) -> Void) async -> UUID {
        let token = UUID()
        questionListeners[projectId, default: [:]][token] = handler
        // As for the plan: a quiet board listener keeps the project watched.
        boardListeners[projectId, default: [:]][token] = { _ in }
        _ = try? await watchBoard(projectId: projectId)
        return token
    }

    func unfollowQuestions(projectId: String, _ token: UUID) {
        questionListeners[projectId]?[token] = nil
        if questionListeners[projectId]?.isEmpty ?? false { questionListeners[projectId] = nil }
        stopListening(projectId: projectId, token)
    }

    /// A `question_change` push, to the screens following its project.
    func questionPushed(_ change: QuestionChange) {
        for handler in (questionListeners[change.projectID] ?? [:]).values { handler(change) }
    }

    /// One open question by its id (a Needs you row's `decision_id`), looked
    /// up as the desktop does: the project's open ones, on its card when it has one.
    func openQuestion(projectId: String, itemId: String?, id: String) async throws -> Question? {
        var list = Flotilla_Board_V1_QuestionList()
        list.projectID = projectId
        if let itemId, !itemId.isEmpty { list.itemID = itemId }
        list.state = .open
        list.limit = 200
        return try await questionList(list).questions.first { $0.id == id }
    }
}

// MARK: What an answer did

/// How an answer or a dismissal came out (`questioned`).
enum QuestionOutcome: Equatable {
    /// The question as it is after the change.
    case done(Question?)
    /// It changed since it was read: the question as it is now.
    case conflict(Question)
    /// Nothing was written: the daemon's code and words.
    case refused(code: String, text: String)

    init(_ result: QuestionResult, id: String) {
        switch result.outcome {
        case .done(let done)?: self = .done(done.questions.first { $0.id == id } ?? done.questions.first)
        case .conflict(let now)?: self = .conflict(now)
        case .refused(let refused)?: self = .refused(code: refused.code, text: refused.text)
        case nil: self = .refused(code: "", text: "The Flotilla service didn’t say what happened. Look again.")
        }
    }

    /// What the owner reads when it didn't go through; nil when it did.
    var failure: String? {
        switch self {
        case .done: nil
        case .conflict(let now):
            switch now.state {
            case .answered: "Already answered, maybe on another device."
            case .dismissed: "Already dismissed, maybe on another device."
            default: "The question changed meanwhile. Look at it again, then answer."
            }
        case .refused(let code, let text): QuestionWords.refusal(code: code, text: text)
        }
    }
}

// MARK: Words

enum QuestionWords {
    /// The codes the contract names, in the owner's words; others say the daemon's text.
    static func refusal(code: String, text: String) -> String {
        switch code {
        case "question.answered": "Already answered, maybe on another device."
        case "question.no_option": "That option isn’t offered any more. Look at the question again."
        case "question.empty": "Pick an option or write an answer."
        case "question.too_many": "Too many open questions. Answer some first."
        default: text.isEmpty ? "Not sent." : text
        }
    }

    /// "Lead asked · 2h ago".
    static func asked(_ q: Question) -> String {
        var parts = ["\(q.askedBy.name.isEmpty ? "A bot" : q.askedBy.name) asked"]
        if q.hasAskedAt { parts.append(q.askedAt.date.relative) }
        return parts.joined(separator: " · ")
    }

    /// Where it belongs: "ASL-4", "PL-2", "ASL-4 · PL-2".
    static func anchor(_ q: Question) -> String? {
        let parts = [q.hasItemID ? q.itemID : nil, q.hasPlanNodeID ? q.planNodeID : nil].compactMap { $0?.nilIfEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func option(_ q: Question, key: String) -> QuestionOptionRow? {
        q.options.first { $0.key == key }.map { QuestionOptionRow(option: $0, recommended: q.hasRecommendation && q.recommendation == key) }
    }

    /// The options, the bot's recommendation marked.
    static func options(_ q: Question) -> [QuestionOptionRow] {
        q.options.map { QuestionOptionRow(option: $0, recommended: q.hasRecommendation && q.recommendation == $0.key) }
    }

    /// "You picked “The ~250 celebrated saints”." and the text, for an answered one.
    static func answer(_ q: Question) -> (picked: String?, text: String?) {
        guard q.hasAnswer else { return (nil, nil) }
        let picked = q.answer.hasOption ? (option(q, key: q.answer.option)?.option.label ?? q.answer.option) : nil
        return (picked, q.answer.text.nilIfEmpty)
    }

    /// "Answered by you · 5m ago", or relayed by a bot.
    static func answeredLine(_ q: Question, botName: (String) -> String?) -> String {
        var who = "you"
        let by = q.answer.answeredBy
        if by.hasPrefix("owner-via-bot:") {
            let bot = String(by.dropFirst("owner-via-bot:".count))
            who = "you, through \(botName(bot) ?? "a bot")"
        }
        var parts = ["Answered by \(who)"]
        if q.answer.hasAnsweredAt { parts.append(q.answer.answeredAt.date.relative) }
        return parts.joined(separator: " · ")
    }

    /// "Added to ASL-4-research.md": where the answer was written back.
    static func writtenTo(_ q: Question) -> String? {
        q.hasWrittenTo && !q.writtenTo.isEmpty ? "Added to \((q.writtenTo as NSString).lastPathComponent)" : nil
    }

    /// The pill a blocking open question carries.
    static let holds = "Holds the gate"

    /// Under a node's questions: what the blocking ones hold.
    static func holdsLine(_ blocking: Int) -> String {
        blocking == 1
            ? "1 question holds this node: its research can’t close and its gate can’t be submitted until you answer it."
            : "\(blocking) questions hold this node: its research can’t close and its gate can’t be submitted until you answer them."
    }

    /// "2 open" / "1 holds the gate" for a section title or a node.
    static func count(open: Int, blocking: Int) -> String {
        var parts = ["\(open) open"]
        if blocking > 0 { parts.append(blocking == 1 ? "1 holds the gate" : "\(blocking) hold the gate") }
        return parts.joined(separator: " · ")
    }

    /// A card's badge: "? 2", read as "2 open questions".
    static func badge(_ open: UInt32) -> (text: String, label: String)? {
        guard open > 0 else { return nil }
        return ("? \(open)", open == 1 ? "1 open question" : "\(open) open questions")
    }
}

/// A card held on the owner (0.24.0, `ItemCard.owner_waiting`): a bot's open
/// questions to the owner about it, asked on the card or from its thread.
/// "▲ Waiting for you" in the accent colour, as the desktop.
enum CardWaiting {
    static let text = "▲ Waiting for you"

    /// Nil while nothing waits on the owner.
    static func line(_ waiting: UInt32) -> String? { waiting > 0 ? text : nil }

    static func label(_ waiting: UInt32) -> String {
        waiting == 1 ? "Waiting for you: a bot asked you about this card" : "Waiting for you: bots asked you \(waiting) things about this card"
    }
}

struct QuestionOptionRow: Identifiable, Equatable {
    let option: Flotilla_Board_V1_QuestionOption
    let recommended: Bool
    var id: String { option.key }
}

// MARK: Order

enum QuestionOrder {
    /// Open ones first, then newest first, as the contract lists them.
    static func sorted(_ questions: [Question]) -> [Question] {
        questions.sorted { a, b in
            let aOpen = a.state == .open, bOpen = b.state == .open
            if aOpen != bOpen { return aOpen }
            return a.askedAt.date > b.askedAt.date
        }
    }

    /// `fresh` folded in: a question is known by its id, and an older copy never replaces a newer one.
    static func merge(_ loaded: [Question], _ fresh: [Question]) -> [Question] {
        var out = loaded
        for question in fresh {
            if let index = out.firstIndex(where: { $0.id == question.id }) {
                if question.version >= out[index].version { out[index] = question }
            } else {
                out.append(question)
            }
        }
        return sorted(out)
    }
}

// MARK: The model

/// A list of questions on screen: a card's, a plan node's or the project's,
/// kept current by `question_change` pushes, answered and dismissed in place.
@MainActor @Observable
final class QuestionsModel {
    /// Which questions the list holds.
    enum Scope: Equatable {
        case project
        case item(String)
        /// A node's own and its cards'.
        case node(String)
    }

    let projectId: String
    var scope: Scope
    /// The project's list shows one state at a time; nil is every state, open first.
    var state: QuestionState?
    private(set) var questions: [Question] = []
    /// The next page's cursor, while there are more.
    private(set) var next: String?
    private(set) var loaded = false
    private(set) var loadFailure: String?
    /// Why the last answer or dismissal of a question didn't go through, by its id.
    private(set) var failures: [String: String] = [:]
    /// The questions being sent, by id.
    private(set) var sending: Set<String> = []

    @ObservationIgnored private let service: QuestionService
    @ObservationIgnored private var token: UUID?
    /// A node's card ids, so their questions' pushes reach a node's list too.
    @ObservationIgnored var nodeCards: Set<String> = []

    init(projectId: String, scope: Scope, state: QuestionState? = nil, service: QuestionService) {
        self.projectId = projectId
        self.scope = scope
        self.state = state
        self.service = service
    }

    var open: [Question] { questions.filter { $0.state == .open } }
    var blocking: [Question] { open.filter(\.blocking) }

    /// Starts following pushes, then reads the first page.
    func start() async {
        if token == nil {
            token = await service.followQuestions(projectId: projectId) { [weak self] change in self?.received(change) }
        }
        await load()
    }

    func stop() {
        if let token { service.unfollowQuestions(projectId: projectId, token) }
        token = nil
    }

    /// The card's or the node's detail already holds its questions: shown at once.
    func seed(_ questions: [Question]) {
        self.questions = QuestionOrder.merge(self.questions.filter { q in questions.contains { $0.id == q.id } }, questions)
        loaded = true
    }

    private func request(before: String?) -> Flotilla_Board_V1_QuestionList {
        var list = Flotilla_Board_V1_QuestionList()
        list.projectID = projectId
        switch scope {
        case .project: break
        case .item(let id): list.itemID = id
        case .node(let id): list.planNodeID = id
        }
        if let state { list.state = state }
        if let before { list.before = before }
        list.limit = 50
        return list
    }

    /// The first page, replacing what is shown.
    func load() async {
        do {
            let page = try await service.questionList(request(before: nil))
            questions = QuestionOrder.sorted(page.questions.filter(belongs))
            next = page.hasNext && !page.next.isEmpty ? page.next : nil
            loadFailure = nil
        } catch {
            loadFailure = error.localizedDescription
        }
        loaded = true
    }

    /// The next page (`before`).
    func loadMore() async throws {
        guard let next else { return }
        let page = try await service.questionList(request(before: next))
        questions = QuestionOrder.merge(questions, page.questions.filter(belongs))
        self.next = page.hasNext && !page.next.isEmpty ? page.next : nil
    }

    /// Whether a question is one this list holds.
    func belongs(_ q: Question) -> Bool {
        if let state, q.state != state { return false }
        switch scope {
        case .project: return true
        case .item(let id): return q.hasItemID && q.itemID == id
        case .node(let id): return (q.hasPlanNodeID && q.planNodeID == id) || (q.hasItemID && nodeCards.contains(q.itemID))
        }
    }

    /// A push: the question in or out of the list, as it now is.
    func received(_ change: QuestionChange) {
        guard change.projectID == projectId, change.hasQuestion else { return }
        take(change.question)
    }

    private func take(_ q: Question) {
        if belongs(q) {
            questions = QuestionOrder.merge(questions, [q])
        } else if let index = questions.firstIndex(where: { $0.id == q.id }), q.version >= questions[index].version {
            // Answered on a list of open ones: it leaves.
            questions.remove(at: index)
        }
    }

    /// Answers one question: an option, text or both. True when it went through.
    @discardableResult
    func answer(_ q: Question, option: String?, text: String) async -> Bool {
        let words = text.trimmed
        guard option != nil || !words.isEmpty else {
            failures[q.id] = QuestionWords.refusal(code: "question.empty", text: "")
            return false
        }
        var answer = Flotilla_Board_V1_QuestionAnswer()
        answer.id = q.id
        answer.expectedVersion = q.version
        if let option { answer.option = option }
        answer.text = words
        return await send(q) { try await self.service.questionAnswer(answer) }
    }

    /// Dismisses one question with the owner's reason.
    @discardableResult
    func dismiss(_ q: Question, reason: String) async -> Bool {
        var dismiss = Flotilla_Board_V1_QuestionDismiss()
        dismiss.id = q.id
        dismiss.expectedVersion = q.version
        dismiss.reason = reason.trimmed
        return await send(q) { try await self.service.questionDismiss(dismiss) }
    }

    private func send(_ q: Question, _ call: () async throws -> QuestionResult) async -> Bool {
        sending.insert(q.id)
        failures[q.id] = nil
        defer { sending.remove(q.id) }
        let outcome: QuestionOutcome
        do {
            outcome = QuestionOutcome(try await call(), id: q.id)
        } catch {
            failures[q.id] = error.localizedDescription
            return false
        }
        switch outcome {
        case .done(let now):
            if let now { take(now) }
            return true
        case .conflict(let now):
            take(now)
            failures[q.id] = outcome.failure
            return false
        case .refused:
            failures[q.id] = outcome.failure
            return false
        }
    }
}
