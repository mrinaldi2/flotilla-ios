import SwiftUI

/// A lead's proposed board change (K4, `owner_confirms`), in Needs you like
/// any decision: what it changes, the column strip before and after when the
/// change is a column, and Approve (with Face ID, as release rulings) or
/// Decline. Structure is otherwise edited on the computer.
struct ProposalSection: View {
    @Environment(AppStore.self) private var store
    let decision: Decision
    let proposal: BoardProposal
    @State private var columns: [BoardColumnRow] = []
    @State private var note = ""
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        Section {
            Text(proposal.summary.capitalizedFirst).font(.body.weight(.medium))
            LabeledContent("Board", value: proposal.boardName)
            if let strips = proposal.strips(before: columns) {
                strip("Before", strips.before)
                strip("After", strips.after)
            }
        } header: {
            SectionTitle("Board change")
        }
        .task(id: decision.projectId) { await loadColumns() }
        if store.canApprove {
            Section {
                TextField("Note for the lead (optional)", text: $note, prompt: .placeholder("Note for the lead (optional)"), axis: .vertical)
                    .lineLimit(1...4)
                Button { rule(approve: true) } label: { Label("Approve", systemImage: "checkmark.circle") }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("proposal-approve")
                Button(role: .destructive) { rule(approve: false) } label: { Label("Decline", systemImage: "xmark.circle") }
                    .accessibilityIdentifier("proposal-decline")
                if let failure {
                    Text(failure).font(.footnote).foregroundStyle(Color.errorText)
                }
            } header: {
                SectionTitle("Your answer")
            } footer: {
                Text("Approving applies the change at once; nothing changes until you do. The lead is told either way.")
                    .foregroundStyle(Color.secondaryText)
            }
            .disabled(busy)
        } else {
            Section {
                Text("This device can’t approve board changes.").font(.footnote).foregroundStyle(Color.secondaryText)
            }
        }
    }

    /// "Before: To do · Doing · Done", as chips.
    private func strip(_ title: String, _ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Color.secondaryText)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                        Pill(text: name, tone: name.hasPrefix("+ ") ? .ready : name.hasPrefix("− ") ? .failed : .quiet)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(names.joined(separator: ", "))")
    }

    /// The board as it is now, for the "before" strip; nothing when it can't be read.
    private func loadColumns() async {
        guard !decision.projectId.isEmpty, store.speaksProto, let snapshot = try? await store.board(projectId: decision.projectId) else { return }
        let state = BoardState(snapshot: snapshot)
        let named = state.boards.first { $0.name == proposal.boardName }
        var chosen = state
        if let named { chosen.select(named.id) }
        columns = chosen.columns
    }

    private func rule(approve: Bool) {
        busy = true
        failure = nil
        Task {
            defer { busy = false }
            do {
                if approve {
                    try await OwnerAuth.confirm("Approve this board change? \(proposal.summary.capitalizedFirst).",
                                                action: .approveBoardChange, computer: store.computerName)
                }
                try await store.ruleProposal(proposal.id, approve: approve, note: note.trimmed)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
