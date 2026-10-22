import Foundation

// Giving a card to a bot from the phone (`item_assign`): the owner may
// assign any card of the project to one of its bots, or take it back. From
// 0.23 (`team_on_demand_v1`) a card can go to a role instead: the daemon
// picks a holder that is free, else one asleep, which wakes.

typealias BoardRole = Flotilla_Board_V1_Role
typealias ProjectRoleRow = Flotilla_Board_V1_ProjectRole

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

    /// Assigns the card to whoever holds `role` (0.23). The answer's failure
    /// in words, or nil when it was done.
    func assign(itemId: String, version: UInt64, role: BoardRole) async throws -> String? {
        var assign = Flotilla_Board_V1_ItemAssign()
        assign.id = itemId
        assign.expectedVersion = version
        assign.role = role
        guard case .edited(let result) = try await boardCall(.itemAssign(assign), name: "item_assign") else {
            throw DaemonError(code: "decode", message: "The Flotilla service answered item_assign with something else.")
        }
        return CardAssign.failure(result, role: role)
    }
}

enum CardAssign {
    /// The bots a card can go to: the project's, linked ones too, not its
    /// temporary workers, by name.
    static func candidates(_ bots: [Bot], projectId: String) -> [Bot] {
        bots.filter { $0.projectId == projectId && !$0.temporary && $0.deletedAt == nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The refusal in words. `role.unheld` gets the phone's own: the
    /// daemon's names its MCP tool.
    static func failure(_ result: Flotilla_Board_V1_EditResult, role: BoardRole? = nil) -> String? {
        switch result.outcome {
        case .done?: nil
        case .refused(let refused)?:
            refused.unmet.map { unmet in
                unmet.code == RoleWords.unheldCode ? RoleWords.unheld(role) : MoveOutcome.lines([unmet])[0]
            }.joined(separator: "\n")
        case .conflict?: "The card changed meanwhile. Try again."
        case nil: "The Flotilla service didn't say whether it was assigned."
        }
    }
}

/// The board's roles in the desktop's words, and who holds them.
enum RoleWords {
    static let unheldCode = "role.unheld"

    /// What "Assign to role" offers: the on-demand team's way of working,
    /// Product shapes a card, Architect designs it, Developer builds it,
    /// Tester verifies it.
    static let assignable: [BoardRole] = [.product, .architect, .dev, .tester]

    static func label(_ role: BoardRole) -> String {
        switch role {
        case .lead: "Lead"
        case .coach: "Coach"
        case .devops: "DevOps"
        case .reviewerArch: "Architecture reviewer"
        case .reviewerUx: "UX reviewer"
        case .reviewerCe: "Security reviewer"
        case .tester: "Tester"
        case .dev: "Developer"
        case .product: "Product"
        case .architect: "Architect"
        case .unspecified, .UNRECOGNIZED: "Role"
        }
    }

    /// The names of the bots holding `role` in the project, by name.
    static func holders(_ role: BoardRole, roles: [ProjectRoleRow], bots: [Bot]) -> [String] {
        roles.filter { $0.role == role }
            .map { row in bots.first { $0.id == row.botID }?.name ?? row.botID }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// "Architect · Ada", "Architect · nobody yet"; just the role when the
    /// holders aren't known.
    static func menuLine(_ role: BoardRole, roles: [ProjectRoleRow]?, bots: [Bot]) -> String {
        guard let roles else { return label(role) }
        let names = holders(role, roles: roles, bots: bots)
        return "\(label(role)) · \(names.isEmpty ? "nobody yet" : names.joined(separator: ", "))"
    }

    /// A role from its token in a `ROLE_UNHELD` row: "architect", "dev" or "developer".
    static func role(token: String) -> BoardRole? {
        let token = token.lowercased().replacingOccurrences(of: "role_", with: "")
        if token == "developer" { return .dev }
        if token == "qa" { return .tester }
        return BoardRole.allCases.first { role in
            role != .unspecified && (label(role).lowercased() == token || "\(role)".lowercased() == token.replacingOccurrences(of: "_", with: ""))
        }
    }

    /// A column gives cards to a role nobody holds (0.24.0, `ROLE_UNHELD`): what to do.
    static func unheld(_ token: String, on place: String) -> String {
        let name = role(token: token).map(label) ?? token.capitalizedFirst
        return "A column gives its cards to the \(name), and nobody in this project holds that role, so they wait there. "
            + "Create a bot with the \(name) role, or give the role to a bot, in Flotilla on \(place)."
    }

    /// Why a card can't go to a role nobody holds.
    static func unheld(_ role: BoardRole?) -> String {
        let name = role.map(label) ?? "that"
        return "Nobody in this project holds the \(name) role yet. Give the role to a bot in Flotilla on your computer, or assign the card to a bot by name."
    }
}
