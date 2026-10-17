import SwiftUI

/// A plan node waiting for the owner, in Needs you (0.21, `PLAN_GATE`), with
/// the two answers its kind takes: a document gate's Review (the gate
/// screen) or Later; a proposed initiative's Accept (Face ID) or Decline
/// (with a note); a research skip's Skip (Face ID) or Keep research (with a
/// note). The node is read for its stage and version; until it is, the row
/// offers Review.
struct PlanAskRow: View {
    @Environment(Fleet.self) private var fleet
    let row: HomeAttentionRow
    /// The computer that keeps the plan and takes the ruling.
    let computer: Computer
    var primary = false
    let open: (NeedsDestination) -> Void
    @State private var node: PlanNode?
    @State private var noting = false
    @State private var note = ""
    @State private var busy = false
    @State private var failure: String?

    private var nodeId: String {
        if case .planNodeID(let id)? = row.target { return id }
        return ""
    }

    private var ask: PlanAsk { PlanAsk(node?.gate.stage ?? .unspecified) }
    private var store: AppStore { computer.store }
    private var destination: NeedsDestination { .planNode(computerId: computer.id, projectId: row.projectID, nodeId: nodeId) }

    private var subtitle: String {
        var parts = [PlanAsk.kindWord(node?.hasGate == true ? node?.gate.stage : nil)]
        if row.hasCreatedAt { parts.append(row.createdAt.date.relative) }
        return parts.joined(separator: " · ")
    }

    /// "Creates 3 features.", the lead's reason to skip.
    private var detail: String? {
        guard let node, node.hasGate else { return nil }
        switch ask.kind {
        case .document: return PlanWords.creates(node.gate).map { "\($0)." }
        case .proposal: return "It would start in Research."
        case .researchSkip: return node.gate.hasNote ? "Lead: “\(node.gate.note)”" : nil
        }
    }

    private var unavailable: String? {
        if store.status != .connected { return "Not connected to \(computer.name)" }
        if ask.kind != .document, !store.canApprove { return "This device can’t rule on the plan" }
        return failure
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { open(destination) } label: {
                ItemRow(title: row.displayTitle, subtitle: subtitle, detail: unavailable ?? detail, titleLines: 2, subtitleLines: 1) {
                    AskGlyph(row: row)
                }
            }
            .buttonStyle(GlanceButtonStyle())
            HStack(spacing: 8) {
                Button { yes() } label: { AskButtonLabel(text: busy ? "Sending…" : ask.yes, primary: primary, enabled: canYes, wide: true) }
                    .disabled(!canYes)
                    .accessibilityIdentifier("plan-ask-yes-\(nodeId)")
                Button { no() } label: { AskButtonLabel(text: ask.no, primary: false, enabled: canNo, wide: true) }
                    .disabled(!canNo)
                    .accessibilityIdentifier("plan-ask-no-\(nodeId)")
            }
            .buttonStyle(GlanceButtonStyle())
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .task(id: "\(nodeId)/\(row.createdAt.seconds)/\(store.status == .connected)") { await load() }
        .sheet(isPresented: $noting) {
            PlanNoteSheet(title: ask.noteTitle, prompt: ask.kind == .proposal ? "Why not now" : "Why research is still needed",
                          note: $note) {
                noting = false
                rule(approve: false)
            }
        }
    }

    private var connected: Bool { store.status == .connected }
    private var canYes: Bool { connected && !busy && (ask.kind == .document || (node != nil && store.canApprove)) }
    private var canNo: Bool { !busy && (ask.kind == .document || (connected && node != nil && store.canApprove)) }

    private func load() async {
        guard connected, !nodeId.isEmpty else { return }
        node = try? await store.planNode(nodeId).node
    }

    private func yes() {
        switch ask.kind {
        case .document: open(destination)
        case .proposal, .researchSkip: rule(approve: true)
        }
    }

    private func no() {
        switch ask.kind {
        case .document: withAnimation(.snappy) { fleet.home.putOff(row.id) }
        case .proposal, .researchSkip:
            note = ""
            noting = true
        }
    }

    /// Accept or Skip ask for Face ID first; Decline and Keep research carry the note.
    private func rule(approve: Bool) {
        guard let node else { return }
        busy = true
        failure = nil
        Task {
            defer { busy = false }
            let model = GateModel(node: node, service: store) { reason in
                try await OwnerAuth.confirm(reason, action: .approvePlan, computer: computer.name)
            }
            model.note = approve ? "" : note
            if approve { await model.approve() } else { await model.sendBack() }
            if model.ruled != nil {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                await fleet.home.refreshAll(fleet.computers, force: true)
            } else {
                failure = model.failure.first
            }
        }
    }
}
