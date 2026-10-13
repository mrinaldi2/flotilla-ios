import SwiftUI

// The project's Board (UX-024, K7): the board picker, the column chips and a
// paged list per column, live from `board_watch` pushes. A card moves with a
// swipe or its menu ("Move to…"); + starts a draft. A 0.18 home has one
// board and no drafts: no picker, no tray and no +.

struct BoardPane: View {
    @Environment(Fleet.self) private var fleet
    let home: (computer: Computer, projectId: String)?
    /// The computer that keeps this project's board, for when this one can't show it.
    var homeName: String?
    @State private var model: BoardModel?

    /// A new model when the project or computer changes; a reload when the link comes back.
    private struct Key: Equatable {
        let computer: String?
        let project: String?
        let reconnects: Int?
    }

    private var key: Key {
        Key(computer: home?.computer.id, project: home?.projectId, reconnects: home?.computer.store.reconnects)
    }

    var body: some View {
        Group {
            if let home, !home.computer.store.speaksProto {
                ContentUnavailableView("Board needs an update", systemImage: "arrow.up.circle",
                                       description: Text("Update The Hermes on \(home.computer.name) to see the board here."))
            } else if let home, let model {
                BoardContent(model: model, computer: home.computer, homeName: homeName)
            } else {
                ProgressView()
            }
        }
        .task(id: key) {
            guard let home, home.computer.store.speaksProto else { return }
            if model?.projectId != home.projectId || model == nil {
                model?.stop()
                model = BoardModel(projectId: home.projectId, service: home.computer.store)
            }
            await model?.start()
            if let state = model?.state {
                // Ids of the project's other boards link here too.
                let project = home.computer.store.projects.first { $0.id == home.projectId }
                fleet.cards.learn(prefixes: state.snapshot.boards.map(\.key) + [state.snapshot.settings.key],
                                  home: .init(computerId: home.computer.id, projectId: home.projectId, projectName: project?.name ?? ""))
            }
        }
        .onDisappear { model?.stop() }
    }
}

/// The board once its model exists: loaded, failed or elsewhere.
private struct BoardContent: View {
    @Bindable var model: BoardModel
    let computer: Computer
    let homeName: String?
    @State private var moving: BoardCard?
    @State private var adding = false
    /// A draft just saved, opened at once.
    @State private var opened: String?
    @State private var saveNotice: String?

    private var store: AppStore { computer.store }

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView()
        case .elsewhere:
            // UX-029: where the board lives, not the service's instruction.
            ContentUnavailableView("Board on another computer", systemImage: "rectangle.split.3x1",
                                   description: Text(BoardWords.elsewhere(homeName)))
        case .failed(let message):
            ContentUnavailableView("Couldn’t load the board", systemImage: "exclamationmark.triangle", description: Text(message))
        case .loaded:
            if let state = model.state {
                loaded(state)
            }
        }
    }

    @ViewBuilder private func loaded(_ state: BoardState) -> some View {
        VStack(spacing: 0) {
            BoardBar(model: model, state: state)
            if let notice = saveNotice ?? model.notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(Color.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }
            if state.columns.isEmpty && !state.hasBoards {
                ContentUnavailableView("No board yet", systemImage: "rectangle.split.3x1")
            } else if state.columns.isEmpty {
                ContentUnavailableView("No columns on this board", systemImage: "rectangle.split.3x1",
                                       description: Text("Add columns to \(state.board?.name ?? "it") on your computer."))
            } else {
                TabView(selection: $model.tab) {
                    ForEach(state.columns, id: \.key) { column in
                        ColumnList(cards: state.cards(in: column.key), computerId: computer.id, bots: store.bots,
                                   canMove: store.canControl) { moving = $0 }
                            .tag(column.key)
                    }
                    if state.hasBoards {
                        DraftsList(state: state, computerId: computer.id, canAdd: store.canControl)
                            .tag(BoardModel.draftsTab)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if state.hasBoards, store.canControl {
                Button { adding = true } label: {
                    Image(systemName: "plus")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Color.accentColor, in: Circle())
                        .shadow(radius: 3, y: 1)
                }
                .padding(20)
                .accessibilityLabel("New item")
                .accessibilityHint("Starts a draft on \(state.board?.name ?? "this board")")
                .accessibilityIdentifier("board-new-item")
            }
        }
        .sheet(item: $moving) { card in
            MoveSheet(model: MoveModel(card: card, service: store), columns: state.allColumns)
                .computerEnvironment(computer)
        }
        .sheet(isPresented: $adding) {
            QuickAddSheet(model: QuickAddModel(projectId: model.projectId, boardId: state.selected, service: store),
                          boards: state.boards) { saved in
                saveNotice = saved.missing.isEmpty ? nil
                    : "\(saved.itemId) was saved without: " + saved.missing.joined(separator: "; ")
                model.tab = BoardModel.draftsTab
                opened = saved.itemId
            }
            .computerEnvironment(computer)
        }
        .navigationDestination(item: $opened) { id in
            ItemView(itemId: id, projectId: model.projectId).computerEnvironment(computer)
        }
    }
}

extension BoardCard: Identifiable {}

/// The row over the columns: the board picker, then a chip per column, then the drafts tray.
private struct BoardBar: View {
    @Bindable var model: BoardModel
    let state: BoardState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if state.boards.count > 1, let board = state.board {
                    Menu {
                        Picker("Board", selection: Binding(get: { state.selected }, set: { model.select(board: $0) })) {
                            ForEach(state.boards, id: \.id) { Text($0.name).tag($0.id) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(board.name).font(.subheadline.weight(.semibold))
                            Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 36)
                        .background(Color(.secondarySystemFill), in: Capsule())
                    }
                    .accessibilityLabel("Board: \(board.name)")
                    .accessibilityHint("Shows another of the project’s boards")
                    .accessibilityIdentifier("board-picker")
                }
                ForEach(state.columns, id: \.key) { column in
                    chip(column.chip(count: state.cards(in: column.key).count), tab: column.key)
                }
                if state.hasBoards {
                    chip("✎ Drafts \(state.drafts.count)", tab: BoardModel.draftsTab)
                        .accessibilityIdentifier("board-drafts")
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 6)
    }

    private func chip(_ text: String, tab: String) -> some View {
        let selected = model.tab == tab
        return Button { model.tab = tab } label: {
            Text(text)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .background(selected ? Color.accentColor.opacity(0.15) : Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One column's cards, in board order. With `control`, a swipe or the menu moves one.
struct ColumnList: View {
    let cards: [BoardCard]
    let computerId: String
    let bots: [Bot]
    var canMove = false
    var move: (BoardCard) -> Void = { _ in }

    var body: some View {
        List {
            if cards.isEmpty { EmptyNote(text: "No cards here", systemImage: "tray") }
            ForEach(cards, id: \.id) { card in
                NavigationLink(value: NeedsDestination.item(computerId: computerId, itemId: card.id)) {
                    ItemRow(title: card.title, subtitle: subtitle(card), titleLines: 2) {
                        IconTile(systemImage: card.blocked ? "nosign" : "square.text.square", tone: card.blocked ? .failed : nil)
                    }
                }
                .swipeActions(edge: .trailing) {
                    if canMove {
                        Button { move(card) } label: { Label("Move to…", systemImage: "arrow.right.square") }
                            .tint(.accentColor)
                    }
                }
                .contextMenu {
                    if canMove {
                        Button { move(card) } label: { Label("Move to…", systemImage: "arrow.right.square") }
                    }
                }
                .accessibilityActions {
                    if canMove { Button("Move to…") { move(card) } }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func subtitle(_ card: BoardCard) -> String {
        var parts = [card.id]
        if card.hasAssignee, let name = bots.first(where: { $0.id == card.assignee })?.name { parts.append(name) }
        if card.acTotal > 0 { parts.append("\(card.acChecked)/\(card.acTotal) criteria") }
        if card.blocked { parts.append("Blocked") }
        if card.stale { parts.append("Stale") }
        return parts.joined(separator: " · ")
    }
}

/// The drafts tray: the project's drafts, each opening its review.
private struct DraftsList: View {
    let state: BoardState
    let computerId: String
    let canAdd: Bool

    var body: some View {
        List {
            if state.drafts.isEmpty {
                EmptyNote(text: canAdd ? "No drafts. Tap + to start one." : "No drafts", systemImage: "square.and.pencil")
            }
            ForEach(state.drafts, id: \.id) { card in
                NavigationLink(value: NeedsDestination.item(computerId: computerId, itemId: card.id)) {
                    ItemRow(title: card.title, subtitle: subtitle(card), titleLines: 2) {
                        IconTile(systemImage: "square.and.pencil", tone: .working)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// "✎ Draft · RB-20 · Research".
    private func subtitle(_ card: BoardCard) -> String {
        (["✎ Draft", card.id] + [state.boardName(of: card)].compactMap { $0 }).joined(separator: " · ")
    }
}
