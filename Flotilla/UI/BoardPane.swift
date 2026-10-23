import SwiftUI

// The project's Board (UX-024, K7): the board picker, the column chips, a
// row of label chips per label group (K8, as the desktop's filter bar), and
// a paged list per column, live from `board_watch` pushes. A card moves from
// its menu (long press) or its own screen ("Move to…"); + starts a draft. A
// 0.18 home has one board and no drafts: no picker, no tray and no +; its
// platforms read as the `platform` group.

struct BoardPane: View {
    @Environment(Fleet.self) private var fleet
    let home: (computer: Computer, projectId: String)?
    /// The computer that keeps this project's board, for when this one can't show it.
    var homeName: String?
    /// Opens a new card's sheet once the board is in (a card's Add a card).
    var addCard = false
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
                                       description: Text("Update Flotilla on \(home.computer.name) to see the board here."))
            } else if let home, let model {
                BoardContent(model: model, computer: home.computer, homeName: homeName, addCard: addCard)
            } else {
                ProgressView()
            }
        }
        .task(id: key) {
            guard let home, home.computer.store.speaksProto else { return }
            if model?.projectId != home.projectId || model == nil {
                model?.stop()
                let store = home.computer.store
                model = BoardModel(projectId: home.projectId, service: store, questions: store.hasQuestions ? store : nil)
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
    var addCard = false
    @State private var moving: BoardCard?
    @State private var adding = false
    /// `addCard` opens the sheet once, not again on every reload.
    @State private var addedCard = false
    /// A draft just saved, opened at once.
    @State private var opened: String?
    @State private var saveNotice: String?
    /// The plan's nodes by id, read when the home serves a plan (0.21).
    @State private var planNodes: [String: PlanNode] = [:]

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
            Color.clear.frame(height: 0)
                .task {
                    guard addCard, !addedCard, state.hasBoards, store.canControl else { return }
                    addedCard = true
                    adding = true
                }
            BoardBar(model: model, state: state)
            LabelFilterBar(model: model, groups: state.labelGroups())
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
                    let groups = state.labelGroups()
                    ForEach(state.columns, id: \.key) { column in
                        ColumnList(cards: state.cards(in: column.key, matching: model.filter), computerId: computer.id, bots: store.bots,
                                   groups: groups, filtering: model.filter.isOn, canMove: store.canControl,
                                   projectId: model.projectId, roles: state.snapshot.roles, planNodes: planNodes) { moving = $0 }
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
        .task(id: store.reconnects) {
            guard store.hasPlan, let tree = try? await store.planTree(projectId: model.projectId), tree.enabled else { return }
            planNodes = Dictionary(tree.nodes.map { ($0.id, $0) }) { first, _ in first }
        }
        .sheet(item: $moving) { card in
            MoveSheet(model: MoveModel(card: card, service: store), columns: state.allColumns)
                .computerEnvironment(computer)
        }
        .sheet(isPresented: $adding) {
            QuickAddSheet(model: QuickAddModel(projectId: model.projectId, boardId: state.selected, service: store,
                                               itemTypesV2: store.hasItemTypesV2, plan: store.hasPlan ? store : nil),
                          boards: state.boards, groups: { state.labelGroups(for: $0) }) { saved in
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
                    let shown = state.cards(in: column.key, matching: model.filter).count
                    chip(column.chip(shown: shown, of: state.cards(in: column.key).count, filtering: model.filter.isOn), tab: column.key)
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

/// One column's cards, in board order, with the labels of the board's
/// groups. With `control`, a card's menu moves it.
struct ColumnList: View {
    let cards: [BoardCard]
    let computerId: String
    let bots: [Bot]
    var groups: [LabelGroupView] = []
    /// A label filter hides some of the column's cards.
    var filtering = false
    var canMove = false
    /// The project, so a card can be given to one of its bots.
    var projectId: String?
    /// Who holds which board role, for Assign to role.
    var roles: [ProjectRoleRow]? = nil
    /// The project's plan nodes by id, for each card's node chip (0.21).
    var planNodes: [String: PlanNode] = [:]
    var move: (BoardCard) -> Void = { _ in }
    @State private var assignFailure: String?

    var body: some View {
        List {
            if cards.isEmpty {
                EmptyNote(text: filtering ? "No cards with these labels" : "No cards here", systemImage: "tray")
            }
            ForEach(cards, id: \.id) { card in
                NavigationLink(value: NeedsDestination.item(computerId: computerId, itemId: card.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        ItemRow(title: card.title, subtitle: subtitle(card), detail: labels(card), titleLines: 2) {
                            IconTile(systemImage: card.blocked ? "nosign" : "square.text.square", tone: card.blocked ? .failed : nil)
                        } trailing: {
                            // Open questions for the owner (0.22): "? 2".
                            if let badge = QuestionWords.badge(card.questionsOpen) {
                                Pill(text: badge.text, tone: .needsYou)
                                    .accessibilityLabel(badge.label)
                                    .accessibilityIdentifier("card-questions-\(card.id)")
                            }
                        }
                        // A bot's question to the owner holds it (0.24.0).
                        if let waiting = CardWaiting.line(card.ownerWaiting) {
                            Text(waiting).font(.caption.weight(.semibold)).foregroundStyle(Tone.working.text)
                                .padding(.leading, 44).padding(.bottom, 2)
                                .accessibilityLabel(CardWaiting.label(card.ownerWaiting))
                                .accessibilityIdentifier("card-waiting-\(card.id)")
                        }
                        // The plan node it belongs to (0.21), under the title.
                        if card.hasPlanNodeID, let node = planNodes[card.planNodeID] {
                            PlanNodeChip(node: node).padding(.leading, 44).padding(.bottom, 4)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                // Its menu, not a swipe: a sideways swipe pages to the next column.
                .contextMenu {
                    if canMove {
                        Button { move(card) } label: { Label("Move to…", systemImage: "arrow.right.square") }
                        if let projectId {
                            AssignMenu(itemId: card.id, version: card.version, assignee: card.hasAssignee ? card.assignee : nil,
                                       projectId: projectId, roles: roles) { assignFailure = $0 }
                        }
                    }
                }
                .accessibilityActions {
                    if canMove { Button("Move to…") { move(card) } }
                }
            }
        }
        .listStyle(.insetGrouped)
        .errorAlert("Couldn’t assign the card.", $assignFailure)
    }

    /// "ios · desktop": the values of its labels in the board's groups.
    private func labels(_ card: BoardCard) -> String? {
        let shown = BoardState.cardLabels(card, groups: groups).map(Labels.word)
        return shown.isEmpty ? nil : shown.joined(separator: " · ")
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

/// The board's label groups as filter chips, one row per group, as the
/// desktop's filter bar: any picked label within a group, every group.
private struct LabelFilterBar: View {
    @Bindable var model: BoardModel
    let groups: [LabelGroupView]

    var body: some View {
        if !groups.allSatisfy(\.values.isEmpty) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(groups.filter { !$0.values.isEmpty }) { group in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            Text(group.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.secondaryText)
                                .accessibilityHidden(true)
                            ForEach(group.values, id: \.self) { value in
                                chip(group.label(value), value: value, group: group.name)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Label group \(group.name)")
                }
                if model.filter.isOn {
                    Button("Show all cards") { model.filter.clear() }
                        .font(.caption.weight(.semibold))
                        .frame(minHeight: 32)
                        .padding(.horizontal, 16)
                        .accessibilityIdentifier("board-labels-clear")
                }
            }
            .padding(.bottom, 6)
        }
    }

    private func chip(_ label: String, value: String, group: String) -> some View {
        let on = model.filter.has(label)
        return Button { model.filter.toggle(label) } label: {
            Text(on ? "✓ \(value)" : value)
                .font(.caption.weight(on ? .semibold : .regular))
                .padding(.horizontal, 10)
                .frame(minHeight: 32)
                .background(on ? Color.accentColor.opacity(0.15) : Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group): \(value)")
        .accessibilityHint(on ? "Stops filtering by it" : "Shows only cards labelled \(label)")
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("board-label-\(label)")
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
