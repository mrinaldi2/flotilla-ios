import SwiftProtobuf
import XCTest
@testable import Flotilla

/// A home that serves questions: answers from what the test set, records what was asked.
@MainActor
final class FakeQuestions: QuestionService {
    var page = QuestionPage()
    var pages: [String: QuestionPage] = [:]
    var result = QuestionResult()
    var error: Error?
    private(set) var lists: [Flotilla_Board_V1_QuestionList] = []
    private(set) var answers: [Flotilla_Board_V1_QuestionAnswer] = []
    private(set) var dismissals: [Flotilla_Board_V1_QuestionDismiss] = []
    private(set) var handlers: [UUID: (QuestionChange) -> Void] = [:]

    func questionList(_ list: Flotilla_Board_V1_QuestionList) async throws -> QuestionPage {
        lists.append(list)
        if let error { throw error }
        return list.hasBefore ? (pages[list.before] ?? QuestionPage()) : page
    }

    func questionAnswer(_ answer: Flotilla_Board_V1_QuestionAnswer) async throws -> QuestionResult {
        answers.append(answer)
        if let error { throw error }
        return result
    }

    func questionDismiss(_ dismiss: Flotilla_Board_V1_QuestionDismiss) async throws -> QuestionResult {
        dismissals.append(dismiss)
        if let error { throw error }
        return result
    }

    func followQuestions(projectId: String, _ handler: @escaping (QuestionChange) -> Void) async -> UUID {
        let token = UUID()
        handlers[token] = handler
        return token
    }

    func unfollowQuestions(projectId: String, _ token: UUID) { handlers[token] = nil }

    func push(_ question: Question, project: String = "p1") {
        var change = QuestionChange()
        change.projectID = project
        change.question = question
        for handler in handlers.values { handler(change) }
    }
}

/// 0.22 step 5 on the phone: the questions contract's fixtures decode, the
/// model answers and dismisses as the contract says and says why when it
/// can't, pushes keep lists live, and every part waits for `questions_v1`.
@MainActor
final class QuestionsTests: XCTestCase {
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

    private func question(_ id: String, state: QuestionState = .open, item: String? = "ASL-4", node: String? = nil,
                          version: UInt64 = 1, asked: TimeInterval = 0, blocking: Bool = false) -> Question {
        var q = Question()
        q.id = id
        q.projectID = "p1"
        q.text = "Question \(id)?"
        q.state = state
        if let item { q.itemID = item }
        if let node { q.planNodeID = node }
        q.version = version
        q.blocking = blocking
        q.askedAt = Google_Protobuf_Timestamp(date: Date(timeIntervalSince1970: 1_800_000_000 + asked))
        var yes = Flotilla_Board_V1_QuestionOption()
        yes.key = "yes"
        yes.label = "Yes"
        var no = Flotilla_Board_V1_QuestionOption()
        no.key = "no"
        no.label = "No"
        q.options = [yes, no]
        q.recommendation = "yes"
        return q
    }

    private func done(_ q: Question) -> QuestionResult {
        var result = QuestionResult()
        var done = Flotilla_Board_V1_QuestionsDone()
        done.questions = [q]
        result.done = done
        return result
    }

    // MARK: The contract

    func testTheQuestionFixturesDecode() throws {
        guard case .questions(let page) = try response("response.questions.json") else { return XCTFail("not questions") }
        let q = try XCTUnwrap(page.questions.first)
        XCTAssertEqual(q.id, "d-7f3a")
        XCTAssertEqual(q.state, .open)
        XCTAssertTrue(q.blocking)
        XCTAssertEqual(q.itemID, "ASL-4")
        XCTAssertEqual(q.planNodeID, "PL-2")
        XCTAssertEqual(q.options.map(\.key), ["celebrated", "full"])
        XCTAssertEqual(QuestionWords.options(q).map(\.recommended), [true, false])
        XCTAssertEqual(page.next, "2026-10-18T08:20:51Z|d-7f3a")

        guard case .questioned(let conflict) = try response("response.questioned.conflict.json") else { return XCTFail("not questioned") }
        let outcome = QuestionOutcome(conflict, id: "d-7f3a")
        guard case .conflict(let now) = outcome else { return XCTFail("not a conflict") }
        XCTAssertEqual(now.state, .answered)
        XCTAssertEqual(QuestionWords.answer(now).picked, "The ~250 celebrated saints")
        XCTAssertEqual(QuestionWords.answer(now).text, "Start with the celebrated ones.")
        XCTAssertEqual(QuestionWords.writtenTo(now), "Added to ASL-4-sources-licensing-research.md")
        XCTAssertEqual(outcome.failure, "Already answered, maybe on another device.")

        guard case .questioned(let refused) = try response("response.questioned.refused.json") else { return XCTFail("not questioned") }
        XCTAssertEqual(QuestionOutcome(refused, id: "d-7f3a").failure, "Already answered, maybe on another device.")

        guard case .questioned(let ok) = try response("response.questioned.done.json") else { return XCTFail("not questioned") }
        guard case .done(let answered?) = QuestionOutcome(ok, id: "d-7f3a") else { return XCTFail("not done") }
        XCTAssertEqual(answered.state, .answered)
    }

    /// What the model sends is what the contract's request fixtures hold.
    func testAnsweringAndDismissingSendTheContractsRequests() async throws {
        guard case .questionAnswer(let expected) = try request("request.question_answer.json"),
              case .questionDismiss(let expectedDismiss) = try request("request.question_dismiss.json") else { return XCTFail("requests") }
        let fake = FakeQuestions()
        let model = QuestionsModel(projectId: "p1", scope: .item("ASL-4"), service: fake)
        var q = question("d-7f3a")
        q.version = 1
        var answered = q
        answered.state = .answered
        answered.version = 2
        fake.result = done(answered)
        model.seed([q])
        let ok = await model.answer(q, option: "celebrated", text: "  Start with the celebrated ones.\n")
        XCTAssertTrue(ok)
        XCTAssertEqual(fake.answers, [expected])
        XCTAssertEqual(model.questions.first?.state, .answered)
        XCTAssertNil(model.failures["d-7f3a"])

        var other = question("d-7f3b")
        other.version = 1
        var dismissed = other
        dismissed.state = .dismissed
        dismissed.dismissedReason = "Already settled in the PRD."
        dismissed.version = 2
        fake.result = done(dismissed)
        model.seed([q, other])
        let r1 = await model.dismiss(other, reason: "Already settled in the PRD.")
        XCTAssertTrue(r1)
        XCTAssertEqual(fake.dismissals, [expectedDismiss])
        XCTAssertEqual(model.questions.first { $0.id == "d-7f3b" }?.state, .dismissed)
    }

    func testANodesListAsksAsTheContractSays() async throws {
        guard case .questionList(let expected) = try request("request.question_list.json") else { return XCTFail("request") }
        let fake = FakeQuestions()
        let model = QuestionsModel(projectId: "p1", scope: .node("PL-2"), state: .open, service: fake)
        await model.load()
        XCTAssertEqual(fake.lists, [expected])
    }

    func testAnEmptyAnswerIsNotSent() async {
        let fake = FakeQuestions()
        let model = QuestionsModel(projectId: "p1", scope: .item("ASL-4"), service: fake)
        let q = question("q1")
        model.seed([q])
        let sent = await model.answer(q, option: nil, text: "   ")
        XCTAssertFalse(sent)
        XCTAssertTrue(fake.answers.isEmpty)
        XCTAssertEqual(model.failures["q1"], "Pick an option or write an answer.")
    }

    func testAConflictShowsTheQuestionAsItIsNowAndSaysWhy() async {
        let fake = FakeQuestions()
        let model = QuestionsModel(projectId: "p1", scope: .item("ASL-4"), service: fake)
        let q = question("q1")
        model.seed([q])
        var now = q
        now.version = 3
        now.text = "Reworded?"
        fake.result.conflict = now
        let r2 = await model.answer(q, option: "yes", text: "")
        XCTAssertFalse(r2)
        XCTAssertEqual(model.questions.first?.text, "Reworded?")
        XCTAssertEqual(model.failures["q1"], "The question changed meanwhile. Look at it again, then answer.")
    }

    func testARefusalSaysTheContractsCodesInWordsAndOthersAsSent() async {
        let fake = FakeQuestions()
        let model = QuestionsModel(projectId: "p1", scope: .item("ASL-4"), service: fake)
        let q = question("q1")
        model.seed([q])
        var refused = Flotilla_Board_V1_QuestionRefused()
        refused.code = "question.no_option"
        refused.text = "No such option."
        fake.result.refused = refused
        let r3 = await model.answer(q, option: "maybe", text: "")
        XCTAssertFalse(r3)
        XCTAssertEqual(model.failures["q1"], "That option isn’t offered any more. Look at the question again.")
        XCTAssertEqual(model.questions.first?.state, .open)

        XCTAssertEqual(QuestionWords.refusal(code: "question.empty", text: ""), "Pick an option or write an answer.")
        XCTAssertEqual(QuestionWords.refusal(code: "question.too_many", text: ""), "Too many open questions. Answer some first.")
        XCTAssertEqual(QuestionWords.refusal(code: "forbidden", text: "Needs the approve grant."), "Needs the approve grant.")

        fake.error = DaemonError(code: "forbidden", message: "This device can't answer.")
        let r4 = await model.answer(q, option: "yes", text: "")
        XCTAssertFalse(r4)
        XCTAssertEqual(model.failures["q1"], "This device can't answer.")
    }

    // MARK: Lists

    func testOpenOnesComeFirstThenTheNewest() {
        let old = question("a", asked: 0)
        let new = question("b", asked: 100)
        let answered = question("c", state: .answered, asked: 200)
        XCTAssertEqual(QuestionOrder.sorted([answered, old, new]).map(\.id), ["b", "a", "c"])
        // An older copy never replaces a newer one.
        var stale = new
        stale.version = 0
        stale.text = "stale"
        XCTAssertEqual(QuestionOrder.merge([new], [stale]).first?.text, "Question b?")
    }

    func testPushesKeepAListLiveAndAnsweredOnesLeaveTheOpenList() async {
        let fake = FakeQuestions()
        let model = QuestionsModel(projectId: "p1", scope: .project, state: .open, service: fake)
        fake.page.questions = [question("q1")]
        await model.start()
        XCTAssertEqual(model.questions.map(\.id), ["q1"])
        fake.push(question("q2", asked: 50))
        XCTAssertEqual(model.questions.map(\.id), ["q2", "q1"])
        fake.push(question("q1", state: .answered, version: 2))
        XCTAssertEqual(model.questions.map(\.id), ["q2"])
        // Another project's push is not this list's.
        fake.push(question("q3"), project: "p2")
        XCTAssertEqual(model.questions.map(\.id), ["q2"])
        model.stop()
        XCTAssertTrue(fake.handlers.isEmpty)
    }

    func testACardsListHoldsOnlyItsCardAndANodesItsOwnAndItsCards() {
        let fake = FakeQuestions()
        let card = QuestionsModel(projectId: "p1", scope: .item("ASL-4"), service: fake)
        XCTAssertTrue(card.belongs(question("a", item: "ASL-4")))
        XCTAssertFalse(card.belongs(question("b", item: "ASL-5")))
        let node = QuestionsModel(projectId: "p1", scope: .node("PL-2"), service: fake)
        node.nodeCards = ["ASL-9"]
        XCTAssertTrue(node.belongs(question("c", item: nil, node: "PL-2")))
        XCTAssertTrue(node.belongs(question("d", item: "ASL-9")))
        XCTAssertFalse(node.belongs(question("e", item: "ASL-4")))
    }

    func testPagesFollowTheCursor() async throws {
        let fake = FakeQuestions()
        fake.page.questions = [question("q2", asked: 10)]
        fake.page.next = "cursor-1"
        fake.pages["cursor-1"] = { var p = QuestionPage(); p.questions = [question("q1")]; return p }()
        let model = QuestionsModel(projectId: "p1", scope: .project, state: .open, service: fake)
        await model.load()
        XCTAssertEqual(model.next, "cursor-1")
        try await model.loadMore()
        XCTAssertEqual(model.questions.map(\.id), ["q2", "q1"])
        XCTAssertNil(model.next)
        XCTAssertEqual(fake.lists.last?.before, "cursor-1")
    }

    func testBlockingOnesAreCountedAndSaidToHoldTheGate() {
        let fake = FakeQuestions()
        let model = QuestionsModel(projectId: "p1", scope: .node("PL-2"), service: fake)
        model.seed([question("a", node: "PL-2", blocking: true), question("b", node: "PL-2"),
                    question("c", state: .answered, node: "PL-2", blocking: true)])
        XCTAssertEqual(model.open.count, 2)
        XCTAssertEqual(model.blocking.map(\.id), ["a"])
        XCTAssertEqual(QuestionWords.count(open: 2, blocking: 1), "2 open · 1 holds the gate")
        XCTAssertEqual(QuestionWords.badge(2)?.text, "? 2")
        XCTAssertEqual(QuestionWords.badge(1)?.label, "1 open question")
        XCTAssertNil(QuestionWords.badge(0))
    }

    func testWhoAnsweredIsSaidInWords() {
        var q = question("a", state: .answered)
        var answer = Flotilla_Board_V1_OwnerAnswer()
        answer.option = "no"
        answer.answeredBy = "owner-via-bot:b-lead"
        q.answer = answer
        XCTAssertEqual(QuestionWords.answer(q).picked, "No")
        XCTAssertNil(QuestionWords.answer(q).text)
        XCTAssertEqual(QuestionWords.answeredLine(q) { $0 == "b-lead" ? "Lead" : nil }, "Answered by you, through Lead")
    }

    // MARK: The daemon's side

    /// A question push reaches the screens following its project, and only them.
    func testAQuestionChangePushReachesItsProjectsFollowers() throws {
        let store = AppStore(defaults: ComputerDefaults(id: "test-question-push"))
        var heard: [String] = []
        store.questionListeners["p1"] = [UUID(): { heard.append($0.question.id) }]
        store.questionListeners["p2"] = [UUID(): { _ in XCTFail("another project's screen") }]
        store.envelopePushed(try envelope("push.question_change.json"))
        XCTAssertEqual(heard, ["d-7f3a"])
    }

    func testEveryPartWaitsForItsCapability() {
        let store = AppStore(defaults: ComputerDefaults(id: "test-question-caps"))
        XCTAssertFalse(store.hasQuestions)
        XCTAssertFalse(store.hasArtifactsV2)
        store.capabilities = ["questions_v1"]
        XCTAssertTrue(store.hasQuestions)
        XCTAssertFalse(store.hasArtifactsV2)
        store.capabilities = ["artifacts_v2"]
        XCTAssertTrue(store.hasArtifactsV2)
    }

    func testAQuestionRowInNeedsYouIsWordedAndAnswered() {
        var row = HomeAttentionRow()
        row.kind = .question
        row.target = .decisionID("d-7f3a")
        XCTAssertEqual(row.kindWord, "Question")
        XCTAssertEqual(AskAction.label(row, opens: .decision(computerId: "mac", decisionId: "d-7f3a")), "Answer")
        row.questionBlocking = true
        XCTAssertEqual(row.kindWord, "Question · holds the gate")
        XCTAssertEqual(row.tone, .needsYou)
    }
}
