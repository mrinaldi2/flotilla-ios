import Foundation
import Observation

// Who the owner discusses a draft with (0.19.0, gravity#26): the invited
// bots, inviting one ("Discuss with a bot", which sends it the draft again
// every time) and removing one, which ends its discussion: the daemon tells
// the bot, and the bot can no longer see or change the draft. What was said
// stays in the bot's chat.
//
// The list comes from the daemon. `ItemDetail.invited` (every home with
// drafts) is read with the draft and comes back from each invite and
// removal; a draft's card also carries `invited` since gravity#26, so a
// DRAFT_CHANGED push says at once that another device removed a bot. An
// older home sends cards without it: an empty `invited` then says nothing,
// and the draft read after the push settles the list.

@MainActor
@Observable
final class DiscussionModel {
    let itemId: String
    /// The invited bots by id, in the daemon's order (who was invited first).
    private(set) var invited: [String] = []
    /// An invite or a removal in flight: Discuss and Remove are off until
    /// the daemon answers, so a second tap sends nothing.
    private(set) var pending: Pending?
    /// The daemon's refusal of the last invite or removal, in its words.
    var failure: String?

    /// Seen a draft card with bots in `invited`: this home fills it, so an
    /// empty one means nobody is invited any more.
    @ObservationIgnored private(set) var cardsCarryInvited = false
    @ObservationIgnored private let service: DraftService

    init(itemId: String, service: DraftService) {
        self.itemId = itemId
        self.service = service
    }

    struct Pending: Equatable {
        let botId: String
        let remove: Bool
    }

    var isBusy: Bool { pending != nil }
    var inviting: String? { pending?.remove == false ? pending?.botId : nil }
    var removing: String? { pending?.remove == true ? pending?.botId : nil }

    // MARK: Following the daemon

    /// The draft as read (or as an invite or removal answered): the whole
    /// list. Returns the bots no longer invited.
    @discardableResult
    func take(_ detail: BoardItemDetail) -> [String] {
        guard detail.item.id.isEmpty || detail.item.id == itemId else { return [] }
        return replace(with: detail.invited)
    }

    /// A draft card from a push or the board's snapshot. Applied only from a
    /// home known to fill `invited`; returns the bots no longer invited.
    @discardableResult
    func take(card: BoardCard) -> [String] {
        if card.draft, !card.invited.isEmpty { cardsCarryInvited = true }
        guard card.id == itemId, card.draft, cardsCarryInvited else { return [] }
        return replace(with: card.invited)
    }

    /// The board's drafts: whether this home fills a card's `invited`, and
    /// this draft's own card.
    func take(drafts: [BoardCard]) {
        if drafts.contains(where: { $0.draft && !$0.invited.isEmpty }) { cardsCarryInvited = true }
        if let card = drafts.first(where: { $0.id == itemId }) { take(card: card) }
    }

    private func replace(with fresh: [String]) -> [String] {
        let gone = invited.filter { !fresh.contains($0) }
        invited = fresh
        return gone
    }

    // MARK: The owner's acts

    /// "Discuss with a bot": `item_invite`, even for a bot already invited,
    /// so it is sent the draft again (as the desktop does). True when the
    /// chat can open; false when refused or already busy.
    func discuss(with botId: String) async -> Bool {
        guard pending == nil else { return false }
        pending = Pending(botId: botId, remove: false)
        failure = nil
        defer { pending = nil }
        do {
            let answer = try await service.invite(itemId: itemId, botId: botId, remove: false)
            take(answer)
            // A reply without the list (never seen): what this phone just did.
            if !invited.contains(botId) { invited.append(botId) }
            return true
        } catch {
            failure = error.localizedDescription
            return false
        }
    }

    /// Remove from the discussion: `item_invite{remove: true}`. True when the
    /// bot is no longer invited.
    func remove(_ botId: String) async -> Bool {
        guard pending == nil else { return false }
        pending = Pending(botId: botId, remove: true)
        failure = nil
        defer { pending = nil }
        do {
            let answer = try await service.invite(itemId: itemId, botId: botId, remove: true)
            take(answer)
            invited.removeAll { $0 == botId }
            return true
        } catch {
            failure = error.localizedDescription
            return false
        }
    }

    /// Reads the draft again (the chat, while it is open, follows it so).
    func refresh() async {
        if let detail = try? await service.item(itemId) { take(detail) }
    }
}

/// The words of "Discussing with", as the desktop's drawer says them.
enum DiscussionWords {
    static func name(_ botId: String, _ botName: (String) -> String?) -> String { botName(botId) ?? "a bot" }

    static func removeTitle(_ name: String, from itemId: String) -> String { "Remove \(name) from \(itemId)?" }

    static func removeMessage(_ name: String) -> String {
        "The discussion ends: \(name) is told, and can no longer see or change the draft. What you said stays in \(name)’s chat."
    }

    static func removeLabel(_ name: String) -> String { "Remove \(name) from the discussion" }

    /// The chat's pin once the bot is no longer invited.
    static func ended(_ itemId: String) -> String { "No longer discussing \(itemId)" }
}
