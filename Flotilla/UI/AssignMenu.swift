import SwiftUI

/// "Assign to…": the project's bots, the current one ticked, Assign to role
/// (0.23) and Unassign. For a card's long-press menu or a toolbar.
struct AssignMenu: View {
    @Environment(AppStore.self) private var store
    let itemId: String
    let version: UInt64
    let assignee: String?
    let projectId: String
    /// Who holds which role, from the board's snapshot; nil when not known.
    var roles: [ProjectRoleRow]? = nil
    /// Says why it didn't work; the board's pushes show it when it did.
    let failed: (String) -> Void
    var assigned: () -> Void = {}

    var body: some View {
        let bots = CardAssign.candidates(store.bots, projectId: projectId)
        Menu {
            ForEach(bots) { bot in
                Button { send(bot.id) } label: {
                    if bot.id == assignee { Label(bot.name, systemImage: "checkmark") } else { Text(bot.name) }
                }
            }
            if store.hasTeamOnDemand {
                Menu {
                    ForEach(RoleWords.assignable, id: \.rawValue) { role in
                        Button(RoleWords.menuLine(role, roles: roles, bots: store.bots)) { send(role) }
                    }
                } label: {
                    Label("Assign to role", systemImage: "person.2.badge.gearshape")
                }
            }
            if assignee != nil {
                Divider()
                Button("Unassign", systemImage: "person.crop.circle.badge.minus") { send(nil) }
            }
        } label: {
            Label(assignee == nil ? "Assign to…" : "Reassign…", systemImage: "person.crop.circle.badge.plus")
        }
        .disabled(bots.isEmpty && !store.hasTeamOnDemand)
    }

    private func send(_ role: BoardRole) {
        Task {
            do {
                if let why = try await store.assign(itemId: itemId, version: version, role: role) {
                    failed(why)
                } else {
                    assigned()
                }
            } catch {
                failed(error.localizedDescription)
            }
        }
    }

    private func send(_ botId: String?) {
        Task {
            do {
                if let why = try await store.assign(itemId: itemId, version: version, botId: botId) {
                    failed(why)
                } else {
                    assigned()
                }
            } catch {
                failed(error.localizedDescription)
            }
        }
    }
}
