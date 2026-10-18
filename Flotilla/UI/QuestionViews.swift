import SwiftUI

// Questions for the owner on the phone (0.22, `questions_v1`): a card's and a
// plan node's Questions section, the project's Questions list (⋯ menu) and
// the inline Needs you row. Each question is answered once: an option (the
// bot's recommendation marked), a reply, or both; or dismissed with a reason.

/// One question: what is asked and why, then its options and a reply field
/// while open, or the answer once answered.
struct QuestionCard: View {
    @Environment(AppStore.self) private var store
    let question: Question
    let model: QuestionsModel
    /// Says which card it is on, in lists that mix cards.
    var showsAnchor = false
    /// The card's or node's id, opened from the anchor line.
    var openCard: ((String) -> Void)? = nil
    /// Under a row that already says the question (Needs you): only why, the options and the reply.
    var compact = false
    @State private var picked: String?
    @State private var reply = ""
    @State private var dismissing = false

    private var id: String { question.id }
    private var open: Bool { question.state == .open }
    private var sending: Bool { model.sending.contains(id) }
    private var canAnswer: Bool { store.canApprove && store.status == .connected }
    private var canSend: Bool { canAnswer && !sending && (picked != nil || !reply.trimmed.isEmpty) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !compact {
                HStack(spacing: 6) {
                    Text(QuestionWords.asked(question)).font(.caption).foregroundStyle(Color.secondaryText)
                    Spacer(minLength: 4)
                    if open, question.blocking { Pill(text: QuestionWords.holds, tone: .needsYou).accessibilityIdentifier("question-blocking-\(id)") }
                    if !open { Pill(text: question.state == .answered ? "Answered" : "Dismissed", tone: .quiet) }
                }
            }
            if showsAnchor, let anchor = QuestionWords.anchor(question) {
                if let openCard, question.hasItemID, !question.itemID.isEmpty {
                    Button { openCard(question.itemID) } label: {
                        Label(anchor, systemImage: "square.text.square").font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityHint("Opens the card")
                } else {
                    Label(anchor, systemImage: "flag").font(.caption).foregroundStyle(Color.secondaryText)
                }
            }
            if !compact {
                Text(question.text).font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            }
            if !question.why.isEmpty {
                Text(question.why).font(.footnote).foregroundStyle(Color.secondaryText)
            }
            if open { answering } else { answered }
            if let failure = model.failures[id] {
                Label(failure, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Color.errorText)
                    .accessibilityIdentifier("question-failure-\(id)")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $dismissing) {
            QuestionDismissSheet(question: question) { reason in
                dismissing = false
                Task { await model.dismiss(question, reason: reason) }
            }
        }
    }

    @ViewBuilder private var answering: some View {
        let options = QuestionWords.options(question)
        if !options.isEmpty {
            VStack(spacing: 6) {
                ForEach(options) { row in optionButton(row) }
            }
        }
        if canAnswer {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Reply", text: $reply, prompt: .placeholder(options.isEmpty ? "Your answer" : "Add a note (optional)"), axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("question-reply-\(id)")
                // Borderless: in a list row, a plain-styled button would take the whole row's taps.
                Button(sending ? "Sending…" : "Send") { send() }
                    .fontWeight(.semibold)
                    .buttonStyle(.borderless)
                    .disabled(!canSend)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("question-send-\(id)")
            }
            Button("Dismiss…", role: .destructive) { dismissing = true }
                .font(.footnote)
                .buttonStyle(.borderless)
                .disabled(sending)
                .frame(minHeight: 44)
                .accessibilityIdentifier("question-dismiss-\(id)")
        } else {
            Text(store.status == .connected ? "This device can’t answer questions." : "Not connected.")
                .font(.footnote).foregroundStyle(Color.secondaryText)
        }
    }

    private func optionButton(_ row: QuestionOptionRow) -> some View {
        let on = picked == row.id
        return Button { picked = on ? nil : row.id } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? Color.accentColor : Color.secondaryText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.option.label).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        if row.recommended { Pill(text: "★ Recommended", tone: .working) }
                    }
                    if row.option.hasDescription_p, !row.option.description_p.isEmpty {
                        Text(row.option.description_p).font(.footnote).foregroundStyle(Color.secondaryText)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(on ? Color.accentColor.opacity(0.12) : Color(.tertiarySystemFill),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canAnswer || sending)
        .accessibilityLabel(row.recommended ? "\(row.option.label), recommended" : row.option.label)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("question-option-\(id)-\(row.id)")
    }

    @ViewBuilder private var answered: some View {
        if question.state == .answered {
            let answer = QuestionWords.answer(question)
            VStack(alignment: .leading, spacing: 3) {
                if let picked = answer.picked {
                    Label(picked, systemImage: "checkmark.circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(Color.successText)
                }
                if let text = answer.text { LinkedText(markdown: text).font(.callout) }
                Text(QuestionWords.answeredLine(question) { store.bot($0)?.name }).font(.caption).foregroundStyle(Color.secondaryText)
                if let written = QuestionWords.writtenTo(question) {
                    Label(written, systemImage: "doc.badge.plus").font(.caption).foregroundStyle(Color.secondaryText)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("question-answer-\(id)")
        } else {
            Text(question.hasDismissedReason && !question.dismissedReason.isEmpty ? "Dismissed: “\(question.dismissedReason)”" : "Dismissed.")
                .font(.callout).foregroundStyle(Color.secondaryText)
        }
    }

    private func send() {
        let option = picked
        let text = reply
        Task {
            if await model.answer(question, option: option, text: text) {
                reply = ""
                picked = nil
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }
}

/// Dismiss a question without answering it: the bot is told why.
struct QuestionDismissSheet: View {
    @Environment(\.dismiss) private var close
    let question: Question
    let dismiss: (String) -> Void
    @State private var reason = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("The question") {
                    Text(question.text).font(.callout).foregroundStyle(Color.secondaryText).lineLimit(6)
                }
                Section {
                    TextField("Why", text: $reason, prompt: .placeholder("Why it doesn’t need an answer"), axis: .vertical)
                        .lineLimit(2...6)
                        .focused($focused)
                        .accessibilityIdentifier("question-dismiss-reason")
                } footer: {
                    Text("\(question.askedBy.name.isEmpty ? "The bot" : question.askedBy.name) is told your reason.")
                }
            }
            .navigationTitle("Dismiss the question")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { close() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Dismiss") { dismiss(reason.trimmed) }
                        .disabled(reason.trimmed.isEmpty)
                        .accessibilityIdentifier("question-dismiss-confirm")
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }
}

/// A card's or a plan node's Questions, open ones first.
struct QuestionsSection: View {
    let model: QuestionsModel
    var title = "Questions"
    var showsAnchor = false
    var openCard: ((String) -> Void)? = nil

    var body: some View {
        if !model.questions.isEmpty {
            Section {
                ForEach(model.questions, id: \.id) { question in
                    QuestionCard(question: question, model: model, showsAnchor: showsAnchor, openCard: openCard)
                }
            } header: {
                let open = model.open.count
                SectionTitle(open > 0 ? "\(title) · \(QuestionWords.count(open: open, blocking: model.blocking.count))" : title)
            }
            .accessibilityIdentifier("questions-section")
        }
    }
}

/// The project's questions (its ⋯ menu): open or answered, on one card or
/// plan node or all, a page at a time.
struct QuestionsScreen: View {
    @Environment(AppStore.self) private var store
    let projectId: String
    @State private var model: QuestionsModel?
    @State private var showing = Showing.open
    @State private var filter = Filter.all
    /// The anchors seen so far, for the filter menu.
    @State private var cards: [String] = []
    @State private var nodes: [String] = []
    /// The card opened from a question: the screen's own state (see `Pushes`).
    @State private var opened: CardLink?

    enum Showing: String, CaseIterable {
        case open = "Open", answered = "Answered"
        var state: QuestionState { self == .open ? .open : .answered }
    }

    enum Filter: Hashable {
        case all
        case card(String)
        case node(String)

        var scope: QuestionsModel.Scope {
            switch self {
            case .all: .project
            case .card(let id): .item(id)
            case .node(let id): .node(id)
            }
        }

        var title: String {
            switch self {
            case .all: "All"
            case .card(let id), .node(let id): id
            }
        }
    }

    struct CardLink: Identifiable, Hashable {
        let id: String
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $showing) {
                ForEach(Showing.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            List {
                if let model {
                    if let failure = model.loadFailure {
                        Text(failure).font(.footnote).foregroundStyle(Color.errorText)
                    }
                    if model.loaded, model.questions.isEmpty, model.loadFailure == nil {
                        EmptyNote(text: showing == .open ? "No open questions" : "No answered questions yet", systemImage: "questionmark.bubble")
                    }
                    if !model.questions.isEmpty {
                        Section {
                            ForEach(model.questions, id: \.id) { question in
                                QuestionCard(question: question, model: model, showsAnchor: true) { opened = CardLink(id: $0) }
                            }
                            ListEnd(hasMore: model.next != nil, noun: "questions", loaded: model.questions.count) {
                                try await model.loadMore()
                            }
                        } header: {
                            SectionTitle(filter == .all ? showing.rawValue : "\(showing.rawValue) · \(filter.title)", count: model.questions.count)
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await model?.load() }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Questions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Show", selection: $filter) {
                        Text("All cards and nodes").tag(Filter.all)
                        if !cards.isEmpty {
                            Section("Cards") { ForEach(cards, id: \.self) { Text($0).tag(Filter.card($0)) } }
                        }
                        if !nodes.isEmpty {
                            Section("Plan nodes") { ForEach(nodes, id: \.self) { Text($0).tag(Filter.node($0)) } }
                        }
                    }
                } label: {
                    Label("Filter", systemImage: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityIdentifier("questions-filter")
            }
        }
        .task(id: "\(showing)/\(filter)/\(store.reconnects)") { await reload() }
        .onDisappear { model?.stop() }
        .navigationDestination(item: $opened) { ItemView(itemId: $0.id, projectId: projectId) }
    }

    private func reload() async {
        model?.stop()
        let fresh = QuestionsModel(projectId: projectId, scope: filter.scope, state: showing.state, service: store)
        model = fresh
        await fresh.start()
        // The filter offers every card and node seen, so picking one keeps the others.
        for q in fresh.questions {
            if q.hasItemID, !q.itemID.isEmpty, !cards.contains(q.itemID) { cards.append(q.itemID) }
            if q.hasPlanNodeID, !q.planNodeID.isEmpty, !nodes.contains(q.planNodeID) { nodes.append(q.planNodeID) }
        }
        cards.sort()
        nodes.sort()
    }
}

/// A bot's question in Needs you (`QUESTION`), answerable in place: the
/// question is looked up by the row's `decision_id`, then shows its options
/// and a reply field. The row's title opens its card (or, until the question
/// is read, the decision it is).
struct QuestionAskRow: View {
    @Environment(Fleet.self) private var fleet
    let row: HomeAttentionRow
    /// The computer that keeps the board and takes the answer.
    let computer: Computer
    let open: (NeedsDestination) -> Void
    @State private var model: QuestionsModel?
    @State private var lookupFailed = false

    private var questionId: String {
        if case .decisionID(let id)? = row.target { return id }
        return ""
    }

    private var store: AppStore { computer.store }

    /// Its card once the question is read, else the decision it is.
    private var destination: NeedsDestination {
        if let question = model?.questions.first(where: { $0.id == questionId }), question.hasItemID, !question.itemID.isEmpty {
            return .item(computerId: computer.id, itemId: question.itemID)
        }
        return .decision(computerId: computer.id, decisionId: questionId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { open(destination) } label: {
                ItemRow(title: row.displayTitle, subtitle: subtitle, titleLines: 2, subtitleLines: 1) {
                    AskGlyph(row: row)
                } trailing: {
                    if row.questionBlocking { Pill(text: QuestionWords.holds, tone: .needsYou) }
                }
            }
            .buttonStyle(GlanceButtonStyle())
            if let model, let question = model.questions.first(where: { $0.id == questionId }) {
                QuestionCard(question: question, model: model, compact: true)
                    .computerEnvironment(computer)
            } else if lookupFailed {
                Text("Open the card to answer it.").font(.footnote).foregroundStyle(Color.secondaryText)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .task(id: "\(questionId)/\(store.status == .connected)") { await load() }
        .onChange(of: model?.questions.first(where: { $0.id == questionId })?.state) { _, state in
            // Answered or dismissed: Needs you reads again and the row goes.
            guard let state, state != .open else { return }
            Task { await fleet.home.refreshAll(fleet.computers, force: true) }
        }
    }

    private var subtitle: String {
        var parts = [row.kindWord]
        if row.hasCreatedAt { parts.append(row.createdAt.date.relative) }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        guard store.status == .connected, !questionId.isEmpty else { return }
        do {
            // The row names only the question: it is found among the project's open ones.
            guard let question = try await store.openQuestion(projectId: row.projectID, itemId: nil, id: questionId) else {
                lookupFailed = true
                return
            }
            let fresh = model ?? QuestionsModel(projectId: row.projectID, scope: .project, service: store)
            fresh.seed([question])
            model = fresh
            lookupFailed = false
        } catch {
            lookupFailed = true
        }
    }
}
