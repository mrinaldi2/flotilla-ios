import SwiftUI

/// "Assign to…": the project's bots, the current one ticked, and Unassign.
/// For a card's long-press menu or a toolbar.
struct AssignMenu: View {
    @Environment(AppStore.self) private var store
    let itemId: String
    let version: UInt64
    let assignee: String?
    let projectId: String
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
            if assignee != nil {
                Divider()
                Button("Unassign", systemImage: "person.crop.circle.badge.minus") { send(nil) }
            }
        } label: {
            Label(assignee == nil ? "Assign to…" : "Reassign…", systemImage: "person.crop.circle.badge.plus")
        }
        .disabled(bots.isEmpty)
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
