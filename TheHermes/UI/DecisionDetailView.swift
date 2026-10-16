import SwiftUI

struct DecisionDetailView: View {
    @Environment(Fleet.self) private var fleet
    @Environment(AppStore.self) private var store
    let decisionId: String
    @State private var option: String?
    @State private var rulingText = ""
    @State private var reason = ""
    @State private var comment = ""
    @State private var busy = false
    @State private var error: String?
    /// A lead's proposal behind this decision, from its project's board.
    @State private var proposal: ProposalCard?

    private var decision: Decision? { store.decisions.first { $0.id == decisionId } }

    var body: some View {
        List {
            if let decision {
                header(decision)
                if let ruling = decision.ruling { rulingSection(decision, ruling) }
                if decision.state == "open" {
                    // A lead's board change (K7): Approve or Decline, not a written ruling.
                    // The snapshot's proposal once read (K5), its decision's words until then.
                    if let proposal = proposal ?? ProposalCard(decision) {
                        ProposalSection(decision: decision, proposal: proposal)
                    } else {
                        answerSection(decision)
                    }
                }
                stateActions(decision)
                commentsSection(decision)
            } else {
                Text("This decision is no longer available.").foregroundStyle(Color.secondaryText)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Decision")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .disabled(busy)
        .task(id: store.status) {
            await store.loadDecision(decisionId)
            await findProposal()
        }
        .errorAlert("Couldn’t answer the decision.", $error)
    }

    /// The board is read only for a decision that may be a proposal's, since
    /// `board_get` starts a board where there is none.
    private func findProposal() async {
        guard let decision, ProposalCard.mayBe(decision), !decision.projectId.isEmpty, store.speaksProto else { return }
        let snapshot = try? await store.board(projectId: decision.projectId)
        proposal = ProposalCard.find(decision: decision, in: snapshot)
    }

    // MARK: Sections

    private func header(_ decision: Decision) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    AvatarView(avatar: decision.raisedByAvatar, name: decision.raisedByName, size: 28)
                    Text(decision.raisedByName).font(.subheadline.weight(.semibold))
                    Text(store.projectName(decision.projectId)).font(.subheadline).foregroundStyle(Color.secondaryText)
                    Spacer()
                    if decision.urgent { Pill(text: "Urgent", tone: .failed) }
                }
                Text(decision.title).font(.title3.weight(.semibold))
                if !decision.body.isEmpty {
                    LinkedText(markdown: decision.body)
                }
                if let deadline = decision.deadlineAt {
                    Label("Due \(deadline.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
                        .font(.footnote)
                        .foregroundStyle(Color.warningText)
                }
                if !decision.tags.isEmpty {
                    HStack { ForEach(decision.tags, id: \.self) { Pill(text: $0) } }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func rulingSection(_ decision: Decision, _ ruling: DecisionRuling) -> some View {
        Section(decision.state == "answered" ? "Your draft answer" : "Ruling") {
            let picked = decision.options.first { $0.key == ruling.option }
            if let picked { LabeledContent("Option", value: picked.label) }
            if ruling.text != picked?.label { Text(ruling.text) }
            if let reason = ruling.reason {
                Text(reason).font(.callout).foregroundStyle(Color.secondaryText)
            }
            if ruling.answeredBy.hasPrefix("owner-via-bot") {
                Label("Relayed by a bot, not yet confirmed by you", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Color.warningText)
            }
        }
    }

    @ViewBuilder
    private func answerSection(_ decision: Decision) -> some View {
        if !decision.options.isEmpty {
            Section("Options") {
                ForEach(decision.options) { item in
                    Button {
                        option = option == item.key ? nil : item.key
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: option == item.key ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(option == item.key ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondaryText))
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(item.label).font(.body.weight(.medium)).foregroundStyle(.primary)
                                    if decision.recommendation == item.key { Pill(text: "Recommended", tone: .ready) }
                                }
                                if !item.description.isEmpty {
                                    Text(markdown(item.description)).font(.footnote).foregroundStyle(Color.secondaryText)
                                }
                                if !item.grants.isEmpty {
                                    Label(OptionGrant.words(item.grants) { store.bot($0)?.name ?? $0 }, systemImage: "key")
                                        .font(.footnote.weight(.medium))
                                        .foregroundStyle(Color.warningText)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.canApprove)
                }
            }
        }
        if store.canApprove {
            Section {
                let rulingTitle = decision.options.isEmpty ? "Your ruling" : "Your ruling (optional with an option)"
                TextField(rulingTitle, text: $rulingText, prompt: .placeholder(rulingTitle), axis: .vertical).lineLimit(2...8)
                TextField("Reason (optional)", text: $reason, prompt: .placeholder("Reason (optional)"), axis: .vertical).lineLimit(1...4)
                Button("Publish ruling") {
                    act { try await store.answerAndPublish(decision.id, option: option, text: ruling(decision), reason: reason) }
                }
                .fontWeight(.semibold)
                .disabled(ruling(decision).isEmpty)
                Button("Save as draft") {
                    act { try await store.decide("answer_decision", answerFields(decision)) }
                }
                .disabled(ruling(decision).isEmpty)
                Button("Put on hold") {
                    act { try await store.decide("hold_decision", ["decision_id": decision.id]) }
                }
            } header: {
                Text("Your answer").foregroundStyle(Color.secondaryText)
            } footer: {
                Text("Publishing settles the decision and tells the bot that asked, in your words.").foregroundStyle(Color.secondaryText)
            }
        } else {
            Section {
                Text("This device can’t approve decisions.")
                    .font(.footnote)
                    .foregroundStyle(Color.secondaryText)
            }
        }
    }

    @ViewBuilder
    private func stateActions(_ decision: Decision) -> some View {
        if store.canApprove {
            switch decision.state {
            case "answered":
                Section {
                    Button("Publish ruling") { act { try await store.publish(decision.id) } }.fontWeight(.semibold)
                    Button("Change answer") {
                        act { try await store.decide("unanswer_decision", ["decision_id": decision.id]) }
                    }
                }
            case "held":
                Section {
                    Button("Resume") {
                        act { try await store.decide("resume_decision", ["decision_id": decision.id]) }
                    }
                }
            case "settled" where decision.ruling?.answeredBy.hasPrefix("owner-via-bot") == true:
                Section {
                    Button("Confirm this ruling") {
                        act { try await store.confirmRuling(decision) }
                    }
                }
            default:
                EmptyView()
            }
        }
    }

    private func commentsSection(_ decision: Decision) -> some View {
        Section("Discussion") {
            ForEach(decision.comments) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(entry.authorName).font(.caption.weight(.semibold))
                        if let at = entry.createdAt {
                            Text(at.relative).font(.caption).foregroundStyle(Color.secondaryText)
                        }
                    }
                    LinkedText(markdown: entry.body)
                }
            }
            if store.canControl {
                HStack(alignment: .bottom) {
                    TextField("Ask or comment", text: $comment, prompt: .placeholder("Ask or comment"), axis: .vertical).lineLimit(1...5)
                    Button("Send") {
                        let body = comment
                        comment = ""
                        act { try await store.comment(decision.id, body: body) }
                    }
                    .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: Helpers

    /// The owner's words; an option picked without text is answered with its label.
    private func ruling(_ decision: Decision) -> String {
        let text = rulingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        return decision.options.first { $0.key == option }?.label ?? ""
    }

    private func answerFields(_ decision: Decision) -> JSONDict {
        var fields: JSONDict = ["decision_id": decision.id, "ruling_text": ruling(decision)]
        if let option { fields["ruling_option"] = option }
        if !reason.isEmpty { fields["ruling_reason"] = reason }
        if let sha = decision.grantsSha(for: option) { fields["grants_sha"] = sha }
        return fields
    }

    /// Inline Markdown with card ids as links (H-204).
    private func markdown(_ text: String) -> AttributedString { fleet.linkedText(text) }


    private func act(_ action: @escaping () async throws -> Void) {
        busy = true
        Task {
            do { try await action() } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
