import SwiftUI


/// A lead's proposed board change (K4, `owner_confirms`), in Needs you like
/// any decision: what it changes, the column strip before and after with
/// each changed column marked, the rules and anything else it changes, and
/// Approve (with Face ID, as release rulings) or Decline. A home since K5
/// sends the proposal with its request; an older one only words it in the
/// decision, and then only an added or removed column is drawn. Structure is
/// otherwise edited on the computer.
struct ProposalSection: View {
    @Environment(AppStore.self) private var store
    let decision: Decision
    let proposal: ProposalCard
    @State private var note = ""
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        let diff = proposal.diff
        Section {
            Text(proposal.summary.capitalizedFirst).font(.body.weight(.medium))
            if !proposal.boardName.isEmpty {
                LabeledContent(isNewBoard ? "New board" : "Board", value: proposal.boardName)
            }
            if diff.showsColumns {
                strip("Before", diff.before.map(\.chip), empty: "No board yet")
                strip("After", diff.after.map(\.chip), empty: "No columns")
            }
            ForEach(diff.notes, id: \.self) { line in
                Text(line).font(.subheadline)
            }
        } header: {
            SectionTitle("Board change")
        }
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

    private var isNewBoard: Bool {
        if case .boardCreate? = proposal.change { return true }
        return false
    }

    /// "Before: To do · Doing · Done", as chips: "+ QA" added, "− Review"
    /// removed, "~ Doing" changed.
    private func strip(_ title: String, _ names: [String], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Color.secondaryText)
            if names.isEmpty {
                Text(empty).font(.footnote).foregroundStyle(Color.secondaryText)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                            Pill(text: name, tone: name.hasPrefix("+ ") ? .ready : name.hasPrefix("− ") ? .failed
                                 : name.hasPrefix("~ ") ? .working : .quiet)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(names.isEmpty ? empty : names.joined(separator: ", "))")
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
