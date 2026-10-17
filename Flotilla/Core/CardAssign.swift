import Foundation

// Giving a card to a bot from the phone (`item_assign`): the owner may
// assign any card of the project to one of its bots, or take it back.

extension AppStore {
    /// Assigns the card to `botId`, or unassigns it with nil. The answer's
    /// failure in words, or nil when it was done.
    func assign(itemId: String, version: UInt64, botId: String?) async throws -> String? {
        var assign = Flotilla_Board_V1_ItemAssign()
        assign.id = itemId
        assign.expectedVersion = version
        if let botId { assign.bot = botId }
        guard case .edited(let result) = try await boardCall(.itemAssign(assign), name: "item_assign") else {
            throw DaemonError(code: "decode", message: "The Flotilla service answered item_assign with something else.")
        }
        return CardAssign.failure(result)
    }
}

enum CardAssign {
    /// The bots a card can go to: the project's, linked ones too, not its
    /// temporary workers, by name.
    static func candidates(_ bots: [Bot], projectId: String) -> [Bot] {
        bots.filter { $0.projectId == projectId && !$0.temporary && $0.deletedAt == nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func failure(_ result: Flotilla_Board_V1_EditResult) -> String? {
        switch result.outcome {
        case .done?: nil
        case .refused(let refused)?: MoveOutcome.lines(refused.unmet).joined(separator: "\n")
        case .conflict?: "The card changed meanwhile. Try again."
        case nil: "The Flotilla service didn't say whether it was assigned."
        }
    }
}
