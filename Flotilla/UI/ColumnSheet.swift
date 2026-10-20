import SwiftUI

// Board glance (0.20, case 5): tapping a column under a card's bar opens that
// column as a sheet, with its cards and what can be done with them, without
// leaving the tab. Review's cards offer Send back and Approve.

/// A column of a project's board, on the computer that keeps it.
struct ColumnSheetLink: Identifiable, Hashable {
    let computerId: String
    let projectId: String
    let projectName: String
    let key: String
    let name: String
    /// The card it came from, whose board "Open the full board" opens.
    let card: HomeProjectLink

    var id: String { "\(computerId):\(projectId):\(key)" }
}

struct ColumnSheet: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.dismiss) private var dismiss
    let link: ColumnSheetLink
    /// "Open the full board": the project's Board, on the tab's stack.
    let openBoard: () -> Void
    @State private var model: BoardModel?
    @State private var moving: Moving?
    @State private var assignFailure: String?

    /// A card on its way out of the column, with where it should go.
    private struct Moving: Identifiable {
        let card: BoardCard
        let target: String?
        var id: String { card.id }
    }

    private var computer: Computer? { fleet.computer(id: link.computerId) }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(link.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                }
                .needsDestinations()
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            guard let computer, model == nil else { return }
            let board = BoardModel(projectId: link.projectId, service: computer.store)
            model = board
            await board.start()
        }
        .onDisappear { model?.stop() }
        .sheet(item: $moving) { item in
            if let computer, let state = model?.state {
                MoveSheet(model: Self.move(item.card, to: item.target, service: computer.store), columns: state.allColumns)
                    .computerEnvironment(computer)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let computer, let model {
            switch model.phase {
            case .loading:
                ProgressView()
            case .elsewhere:
                ContentUnavailableView("Board on another computer", systemImage: "rectangle.split.3x1",
                                       description: Text("Connect to the computer that keeps \(link.projectName)'s board to see this column."))
            case .failed(let message):
                ContentUnavailableView("Couldn’t load the column", systemImage: "exclamationmark.triangle", description: Text(message))
            case .loaded:
                if let state = model.state { cards(state, computer: computer) }
            }
        } else {
            ContentUnavailableView("Not connected", systemImage: "wifi.slash")
        }
    }

    private func cards(_ state: BoardState, computer: Computer) -> some View {
        let cards = state.cards(in: link.key)
        let review = ColumnActions.isReview(link.key, in: state.allColumns)
        let canMove = computer.store.canControl
        return List {
            Section {
                if cards.isEmpty {
                    EmptyNote(text: "No cards here", systemImage: "tray")
                }
                ForEach(cards, id: \.id) { card in
                    VStack(alignment: .leading, spacing: 10) {
                        NavigationLink(value: NeedsDestination.item(computerId: computer.id, itemId: card.id)) {
                            ItemRow(title: card.title, subtitle: ColumnActions.subtitle(card, bots: computer.store.bots), titleLines: 2) {
                                IconTile(systemImage: card.blocked ? "nosign" : "square.text.square", tone: card.blocked ? .failed : nil)
                            }
                        }
                        if review, canMove {
                            HStack(spacing: 10) {
                                Button("Send back") {
                                    moving = Moving(card: card, target: ColumnActions.sendBack(from: link.key, in: state.allColumns))
                                }
                                .buttonStyle(.bordered)
                                Button("Approve") {
                                    moving = Moving(card: card, target: ColumnActions.approve(in: state.allColumns))
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .contextMenu {
                        if canMove {
                            Button { moving = Moving(card: card, target: nil) } label: { Label("Move to…", systemImage: "arrow.right.square") }
                            AssignMenu(itemId: card.id, version: card.version, assignee: card.hasAssignee ? card.assignee : nil,
                                       projectId: link.projectId, roles: model?.state?.snapshot.roles) { assignFailure = $0 }
                        }
                    }
                }
            } header: {
                Text(ColumnActions.header(project: link.projectName, count: cards.count, review: review)).textCase(nil)
            }
            Section {
                Button("Open the full board") {
                    dismiss()
                    openBoard()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .listStyle(.insetGrouped)
        .errorAlert("Couldn’t assign the card.", $assignFailure)
    }

    private static func move(_ card: BoardCard, to target: String?, service: BoardService) -> MoveModel {
        let model = MoveModel(card: card, service: service)
        model.target = target
        return model
    }
}

/// What a column's sheet offers, apart from the view so the tests hold it.
enum ColumnActions {
    /// The owner's column: `review` on the presets, or the Review category
    /// of a release-gated board.
    static func isReview(_ key: String, in columns: [BoardColumnRow]) -> Bool {
        guard let column = columns.first(where: { $0.key == key }) else { return key == "review" }
        return column.key == "review" || column.category == .review
    }

    /// Approve moves a card to the board's first Done column.
    static func approve(in columns: [BoardColumnRow]) -> String? {
        columns.first { $0.visible && ($0.kind == .done || $0.category == .done) }?.key
    }

    /// Send back moves it to the active column before this one (Doing).
    static func sendBack(from key: String, in columns: [BoardColumnRow]) -> String? {
        guard let index = columns.firstIndex(where: { $0.key == key }) else { return nil }
        return columns[..<index].last { $0.visible && ($0.kind == .active || $0.category == .doing) }?.key
    }

    /// "PhD · 2 cards wait for you", "PhD · 3 cards".
    static func header(project: String, count: Int, review: Bool) -> String {
        let cards = "\(count) card\(count == 1 ? "" : "s")"
        if review, count > 0 { return "\(project) · \(cards) wait\(count == 1 ? "s" : "") for you" }
        return "\(project) · \(cards)"
    }

    static func subtitle(_ card: BoardCard, bots: [Bot]) -> String {
        let who = card.assignee.isEmpty ? nil : (bots.first { $0.id == card.assignee }?.name ?? card.assignee)
        return [card.id, who].compactMap { $0 }.joined(separator: " · ")
    }
}

extension ColumnSheetLink {
    /// A card's column, on the computer that keeps its board (in that
    /// computer's project id), else the one that answered for the card.
    @MainActor
    static func of(_ card: HomeCard, key: String, fleet: Fleet) -> ColumnSheetLink? {
        guard let name = card.row.columns.first(where: { $0.key == key })?.name else { return nil }
        let home = fleet.computer(daemonId: card.row.boardHome)
        let projectId = home.flatMap { _ in card.row.members.first { $0.daemonID == card.row.boardHome }?.projectID }
        guard let computer = home ?? fleet.computer(id: card.computerId) else { return nil }
        return ColumnSheetLink(computerId: computer.id, projectId: projectId ?? card.row.projectID,
                               projectName: card.row.name, key: key, name: name,
                               card: HomeProjectLink(computerId: card.computerId, projectId: card.row.projectID))
    }
}

/// Pull-down search on Projects, once there are five projects (§3).
struct GlanceSearch: ViewModifier {
    let enabled: Bool
    @Binding var text: String

    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $text, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search projects")
        } else {
            content
        }
    }
}

/// What Delete says before it deletes (case 6).
enum DeleteWords {
    /// "PhD is deleted on This Mac. Its 3 bots stop, and what it left on disk
    /// moves to the Trash, where it can be put back."
    static func message(_ card: HomeCard, computer: String) -> String {
        let trash = "what it left on disk moves to the Trash, where it can be put back."
        let bots = Int(card.row.bots)
        guard bots > 0 else { return "\(card.row.name) is deleted on \(computer), and \(trash)" }
        let stop = bots == 1 ? "Its bot stops" : "Its \(bots) bots stop"
        return "\(card.row.name) is deleted on \(computer). \(stop), and \(trash)"
    }
}
