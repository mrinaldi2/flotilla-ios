import SwiftProtobuf
import XCTest
@testable import TheHermes

/// gravity#26 on the phone: who a draft is discussed with, from the draft
/// and from its card's `invited` (field 19), Remove (`item_invite{remove}`),
/// and Discuss and Remove sending one request however often they are tapped.
@MainActor
final class KanbanDiscussionTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("contract/fixtures/board")

    private func draftDetail(_ invited: [String]) -> BoardItemDetail {
        var detail = BoardItemDetail()
        detail.item.id = "RB-20"
        detail.item.state = "draft"
        detail.invited = invited
        return detail
    }

    private func draftCard(_ id: String = "RB-20", invited: [String]) -> BoardCard {
        var card = BoardCard()
        card.id = id
        card.draft = true
        card.invited = invited
        return card
    }

    private func eventually(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), what)
    }

    // MARK: Decoding `invited`

    /// The daemon's DRAFT_CHANGED push, as gravity#26 sends it: the card names its invited bots.
    func testTheDraftChangedPushCarriesTheInvitedBots() throws {
        let url = Self.fixtures.appendingPathComponent("messages/push.board_event.draft_changed.json")
        var text = try String(contentsOf: url, encoding: .utf8)
        // The vendored fixture is from a draft nobody discusses: no `invited`, which reads as none.
        let plain = try Hermes_Wire_V1_Envelope(jsonString: text)
        guard case .boardPush(let push)? = plain.body, case .boardEvent(let event)? = push.push else { return XCTFail("not a push") }
        XCTAssertTrue(event.card.draft)
        XCTAssertTrue(event.card.invited.isEmpty)

        text = text.replacingOccurrences(of: "\"draft\": true", with: "\"draft\": true,\n        \"invited\": [\"b-lead\", \"b-ios\"]")
        let envelope = try Hermes_Wire_V1_Envelope(jsonString: text)
        guard case .boardPush(let filled)? = envelope.body, case .boardEvent(let card)? = filled.push else { return XCTFail("not a push") }
        XCTAssertEqual(card.card.invited, ["b-lead", "b-ios"])

        // Through the binary wire, as the phone reads it: field 19.
        let back = try Hermes_Wire_V1_Envelope(serializedBytes: try envelope.serializedData())
        guard case .boardPush(let wire)? = back.body, case .boardEvent(let wired)? = wire.push else { return XCTFail("not a push") }
        XCTAssertEqual(wired.card.invited, ["b-lead", "b-ios"])
    }

    /// A card from a home before gravity#26 has no field 19; one after it
    /// read by that home's peers keeps it as an unknown field, never an error.
    func testAnOlderCardHasNoInvitedAndField19IsTheNewOne() throws {
        var card = draftCard(invited: ["b-lead"])
        let bytes: Data = try card.serializedData()
        // Tag 19, wire type 2 (length-delimited): 19 << 3 | 2 = 154 = 0x9A 0x01.
        XCTAssertTrue(bytes.range(of: Data([0x9A, 0x01])) != nil, "invited is field 19")
        card.invited = []
        XCTAssertTrue(try BoardCard(serializedBytes: try card.serializedData()).invited.isEmpty)
        let old = try BoardCard(jsonString: #"{"id": "RB-20", "draft": true, "version": "5"}"#)
        XCTAssertTrue(old.invited.isEmpty)
    }

    // MARK: The list

    func testTheListFollowsTheDraftAndACardThatCarriesInvited() {
        let model = DiscussionModel(itemId: "RB-20", service: FakeKanban())
        XCTAssertEqual(model.take(draftDetail(["b-lead", "b-ios"])), [])
        XCTAssertEqual(model.invited, ["b-lead", "b-ios"], "the daemon's order")

        // The board's drafts show this home fills cards' `invited`.
        model.take(drafts: [draftCard("RB-21", invited: ["b-ios"]), draftCard(invited: ["b-lead", "b-ios"])])
        XCTAssertTrue(model.cardsCarryInvited)
        // Another device removes the lead: the push says so at once.
        XCTAssertEqual(model.take(card: draftCard(invited: ["b-ios"])), ["b-lead"])
        XCTAssertEqual(model.invited, ["b-ios"])
        XCTAssertEqual(model.take(card: draftCard(invited: [])), ["b-ios"], "the last one too: empty means nobody")
        XCTAssertTrue(model.invited.isEmpty)
        XCTAssertEqual(model.take(card: draftCard("RB-21", invited: [])), [], "another draft's card")
        var live = draftCard(invited: [])
        live.draft = false
        model.take(draftDetail(["b-lead"]))
        XCTAssertEqual(model.take(card: live), [], "a finalized card says nothing about the discussion")
        XCTAssertEqual(model.invited, ["b-lead"])
    }

    /// A home before gravity#26 never fills a card's `invited`: an empty one
    /// is no news, and the draft read after the push has the list.
    func testAnOlderHomesCardsLeaveTheListToTheDraft() async {
        let fake = FakeKanban()
        let model = DiscussionModel(itemId: "RB-20", service: fake)
        model.take(draftDetail(["b-lead"]))
        model.take(drafts: [draftCard(invited: [])])
        XCTAssertFalse(model.cardsCarryInvited)
        XCTAssertEqual(model.take(card: draftCard(invited: [])), [])
        XCTAssertEqual(model.invited, ["b-lead"], "kept: the card can't say")

        fake.itemReply = draftDetail([])
        await model.refresh()
        XCTAssertEqual(fake.itemReads, 1)
        XCTAssertTrue(model.invited.isEmpty, "removed on another device, seen in the draft")
    }

    // MARK: Inviting and removing

    func testDiscussInvitesEvenABotAlreadyInvited() async {
        let fake = FakeKanban()
        let model = DiscussionModel(itemId: "RB-20", service: fake)
        model.take(draftDetail(["b-lead"]))
        fake.inviteReply = draftDetail(["b-lead"])
        let opened = await model.discuss(with: "b-lead")
        XCTAssertTrue(opened)
        XCTAssertEqual(fake.invites.count, 1, "sent again: the bot gets the draft again")
        XCTAssertEqual(fake.invites.first?.bot, "b-lead")
        XCTAssertEqual(fake.invites.first?.remove, false)

        // A reply without the list: what this phone just did.
        fake.inviteReply = BoardItemDetail()
        _ = await model.discuss(with: "b-ios")
        XCTAssertEqual(model.invited, ["b-ios"])
    }

    func testRemoveSendsRemoveAndUpdatesTheList() async {
        let fake = FakeKanban()
        let model = DiscussionModel(itemId: "RB-20", service: fake)
        model.take(draftDetail(["b-lead", "b-ios"]))
        fake.inviteReply = draftDetail(["b-ios"])
        let removed = await model.remove("b-lead")
        XCTAssertTrue(removed)
        XCTAssertEqual(fake.invites.map(\.bot), ["b-lead"])
        XCTAssertEqual(fake.invites.map(\.remove), [true])
        XCTAssertEqual(model.invited, ["b-ios"])
        XCTAssertNil(model.failure)

        // A reply that still lists it (a slow read): this phone removed it.
        fake.inviteReply = draftDetail(["b-ios"])
        _ = await model.remove("b-ios")
        XCTAssertTrue(model.invited.isEmpty)
    }

    func testARefusedRemoveSaysWhyAndKeepsTheBot() async {
        let fake = FakeKanban()
        let model = DiscussionModel(itemId: "RB-20", service: fake)
        model.take(draftDetail(["b-lead"]))
        fake.inviteError = DaemonError(code: "forbidden", message: "only the owner, from the app or a paired device, invites to a draft")
        let removed = await model.remove("b-lead")
        XCTAssertFalse(removed)
        XCTAssertEqual(model.invited, ["b-lead"])
        XCTAssertEqual(model.failure, "only the owner, from the app or a paired device, invites to a draft")
        XCTAssertFalse(model.isBusy, "Remove is back after the refusal")

        fake.inviteError = nil
        fake.inviteReply = draftDetail([])
        let again = await model.remove("b-lead")
        XCTAssertTrue(again)
        XCTAssertNil(model.failure, "the old refusal goes")
    }

    // MARK: Double taps

    func testDiscussAndRemoveSendOneRequestUntilTheHomeAnswers() async {
        let fake = FakeKanban()
        let model = DiscussionModel(itemId: "RB-20", service: fake)
        model.take(draftDetail(["b-lead"]))
        fake.inviteReply = draftDetail(["b-lead"])
        fake.holdInvites = true
        let first = Task { await model.discuss(with: "b-lead") }
        let second = Task { await model.discuss(with: "b-lead") }
        await eventually("the first invite is out") { fake.invites.count == 1 }
        XCTAssertTrue(model.isBusy)
        XCTAssertEqual(model.inviting, "b-lead")
        XCTAssertNil(model.removing)
        let removeMeanwhile = await model.remove("b-lead")
        XCTAssertFalse(removeMeanwhile, "Remove is off while the invite is out")
        let secondOpened = await second.value
        XCTAssertFalse(secondOpened, "the second tap sent nothing")
        fake.holdInvites = false
        let firstOpened = await first.value
        XCTAssertTrue(firstOpened)
        XCTAssertEqual(fake.invites.count, 1)
        XCTAssertFalse(model.isBusy, "on again once answered")

        // Remove the same way, and an error turns it back on too.
        fake.holdInvites = true
        fake.inviteError = DaemonError(code: "unavailable", message: "The Hermes service is not connected.")
        let removing = Task { await model.remove("b-lead") }
        let again = Task { await model.remove("b-lead") }
        await eventually("the removal is out") { fake.invites.count == 2 }
        XCTAssertEqual(model.removing, "b-lead")
        let againRemoved = await again.value
        XCTAssertFalse(againRemoved)
        fake.holdInvites = false
        let removed = await removing.value
        XCTAssertFalse(removed)
        XCTAssertEqual(fake.invites.count, 2, "one removal sent")
        XCTAssertFalse(model.isBusy, "on again after the error")
        XCTAssertEqual(model.invited, ["b-lead"])
    }

    // MARK: Words

    func testTheWordsAreTheDesktops() {
        XCTAssertEqual(DiscussionWords.removeTitle("Team Lead", from: "RB-20"), "Remove Team Lead from RB-20?")
        XCTAssertEqual(DiscussionWords.removeMessage("Team Lead"),
                       "The discussion ends: Team Lead is told, and can no longer see or change the draft. What you said stays in Team Lead’s chat.")
        XCTAssertEqual(DiscussionWords.removeLabel("Team Lead"), "Remove Team Lead from the discussion")
        XCTAssertEqual(DiscussionWords.name("b-gone") { _ in nil }, "a bot")
        XCTAssertEqual(DiscussionWords.ended("RB-20"), "No longer discussing RB-20")
    }
}
