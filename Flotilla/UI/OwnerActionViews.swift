import SwiftUI

// Owner actions and push requests on the phone (0.24.0): the phone runs them
// now, with Face ID, on its device credential. In Needs you, on their own
// screen, and on the card they are for (PhonePush).

extension Fleet {
    /// Where an owner action runs: the computer it targets, when the phone
    /// talks to it and it isn't the one that answered (a run isn't forwarded).
    func runner(for action: OwnerAction, answeredBy store: AppStore) -> OwnerActionService? {
        guard !action.targetMachine.isEmpty, action.targetMachine != store.daemonId,
              let there = computer(daemonId: action.targetMachine), there.store.status == .connected else { return nil }
        return there.store
    }

    func ownerActionModel(_ actionId: String, on computer: Computer) -> OwnerActionModel {
        let store = computer.store
        let name = computer.name
        return OwnerActionModel(actionId: actionId, service: store, runner: { [weak self] action in
            self?.runner(for: action, answeredBy: store)
        }) { reason in
            try await OwnerAuth.confirm(reason, action: .runOwnerAction, computer: name)
        }
    }
}

/// The command or push itself, and what the owner should know before running it.
struct OwnerActionBody: View {
    @Environment(AppStore.self) private var store
    let action: OwnerAction
    /// The live output while it runs, else its tail.
    var output: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(action.content)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel("Command: \(action.content)")
            if let push = action.push {
                facts([("Commit", OwnerActionWords.pushLine(push)), ("To", OwnerActionWords.destination(push)),
                       ("Then", "the bot opens its pull request"), ("Why", action.reason.isEmpty ? nil : "“\(action.reason)”")])
            } else {
                facts([("Where", action.cwd), ("Why", action.reason.isEmpty ? nil : "“\(action.reason)”"),
                       ("On", action.targetName)])
            }
            if let flags = OwnerActionWords.flags(action) {
                Label(flags, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(Color.warningText)
            }
            if let output = output ?? action.outputTail, !output.isEmpty, !action.isOpen {
                Text(output)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel("Output")
            }
            if let reason = action.rejectReason, action.state == "rejected" {
                Text("Rejected: “\(reason)”").font(.footnote).foregroundStyle(Color.secondaryText)
            }
        }
    }

    private func facts(_ rows: [(String, String?)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            ForEach(rows.filter { $0.1?.isEmpty == false }, id: \.0) { label, value in
                GridRow {
                    Text(label).foregroundStyle(Color.secondaryText)
                    Text(value ?? "").textSelection(.enabled)
                }
                .font(.footnote)
            }
        }
    }
}

/// Push (or Run) and Reject: Face ID first, the reason optional.
struct OwnerActionButtons: View {
    let model: OwnerActionModel
    @State private var rejecting = false
    @State private var reason = ""

    var body: some View {
        if let action = model.action, action.isOpen {
            HStack(spacing: 10) {
                Button { Task { await model.run() } } label: {
                    AskButtonLabel(text: model.busy ? "Sending…" : OwnerActionWords.run(action), primary: true,
                                   enabled: model.canAct, wide: true)
                }
                .disabled(!model.canAct)
                .accessibilityIdentifier("owner-action-run")
                Button { reason = ""; rejecting = true } label: {
                    AskButtonLabel(text: "Reject", enabled: model.canAct, wide: true)
                }
                .disabled(!model.canAct)
                .accessibilityIdentifier("owner-action-reject")
            }
            .buttonStyle(GlanceButtonStyle())
            .sheet(isPresented: $rejecting) {
                RejectActionSheet(reason: $reason) {
                    rejecting = false
                    Task { await model.reject(reason: reason) }
                }
            }
        }
    }
}

private struct RejectActionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var reason: String
    let send: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Reason", text: $reason, prompt: .placeholder("Why not (optional)"), axis: .vertical)
                        .lineLimit(2...6)
                } footer: {
                    Text("Nothing runs. The bot is told, with your reason.").foregroundStyle(Color.secondaryText)
                }
            }
            .navigationTitle("Reject")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Reject", role: .destructive) { send() } }
            }
        }
        .presentationDetents([.medium])
    }
}

/// An owner action in Needs you: what it runs and its two answers, right here.
struct OwnerActionAskRow: View {
    @Environment(Fleet.self) private var fleet
    let row: HomeAttentionRow
    /// The computer that keeps it and takes the answer.
    let computer: Computer
    let open: (NeedsDestination) -> Void
    @State private var model: OwnerActionModel?

    private var actionId: String {
        if case .actionID(let id)? = row.target { return id }
        return ""
    }

    private var store: AppStore { computer.store }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { open(.ownerAction(computerId: computer.id, actionId: actionId)) } label: {
                ItemRow(title: title, subtitle: subtitle, detail: detail, titleLines: 2, subtitleLines: 1) {
                    AskGlyph(row: row)
                }
            }
            .buttonStyle(GlanceButtonStyle())
            if let action = model?.action, action.isOpen {
                Text(action.content)
                    .font(.footnote.monospaced())
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel("Command: \(action.content)")
            }
            if let model {
                OwnerActionButtons(model: model)
                if let failure = model.failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Color.errorText)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .task(id: "\(actionId)/\(store.status == .connected)") {
            guard store.status == .connected, !actionId.isEmpty else { return }
            if model == nil { model = fleet.ownerActionModel(actionId, on: computer) }
            await model?.load()
        }
        .onChange(of: store.ownerActionUpdates[actionId]) { _, update in
            model?.take(update)
            if update?.isOpen == false { Task { await fleet.home.refreshAll(fleet.computers, force: true) } }
        }
    }

    private var title: String {
        guard let action = model?.action else { return row.displayTitle }
        return OwnerActionWords.title(action, botName: action.botId.flatMap { store.bot($0)?.name })
    }

    /// "Push · CASS-053 · 4m ago".
    private var subtitle: String {
        var parts = [model?.action?.isPush == true ? "Push" : "Run card"]
        if let card = model?.action?.card { parts.append(card) }
        if row.hasCreatedAt { parts.append(row.createdAt.date.relative) }
        return parts.joined(separator: " · ")
    }

    private var detail: String? {
        if store.status != .connected { return "Not connected to \(computer.name)" }
        if let push = model?.action?.push { return OwnerActionWords.pushLine(push) }
        return nil
    }
}

/// One owner action on its own screen: the whole command, the facts, Run or
/// Reject, then how it ran.
struct OwnerActionScreen: View {
    @Environment(Fleet.self) private var fleet
    @Environment(Computer.self) private var computer
    @Environment(AppStore.self) private var store
    let actionId: String
    @State private var model: OwnerActionModel?

    var body: some View {
        List {
            if let action = model?.action {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(OwnerActionWords.title(action, botName: action.botId.flatMap { store.bot($0)?.name }))
                            .font(.headline)
                        HStack(spacing: 6) {
                            Pill(text: OwnerActionWords.state(action), tone: OwnerActionWords.tone(action))
                            if let expiry = OwnerActionWords.expiry(action) {
                                Text(expiry).font(.caption).foregroundStyle(Color.secondaryText)
                            }
                        }
                    }
                    OwnerActionBody(action: action, output: store.ownerActionOutputs[action.id])
                    if let card = action.card {
                        NavigationLink(value: NeedsDestination.item(computerId: fleet.boardComputer(itemId: card)?.id ?? computer.id, itemId: card)) {
                            Label("Open \(card)", systemImage: "square.stack")
                        }
                    }
                } footer: {
                    if action.isOpen { Text(OwnerActionWords.promise(action)).foregroundStyle(Color.secondaryText) }
                }
                if let model, let failure = model.failure {
                    Section {
                        Label(failure, systemImage: "xmark.octagon").foregroundStyle(Color.errorText)
                    }
                }
                if !store.canApprove, action.isOpen {
                    Section {
                        Text("This device can’t run owner actions. Run it on \(store.computerName), in the Flotilla app.")
                            .font(.footnote).foregroundStyle(Color.secondaryText)
                    }
                }
            } else if let failure = model?.loadFailure {
                Text(failure).foregroundStyle(Color.errorText)
            } else {
                ProgressView()
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(model?.action?.isPush == true ? "Push request" : "Run card")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if let model, store.canApprove, model.action?.isOpen == true {
                OwnerActionButtons(model: model)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.bar)
            }
        }
        .task(id: store.reconnects) {
            if model == nil { model = fleet.ownerActionModel(actionId, on: computer) }
            await model?.load()
        }
        .onChange(of: store.ownerActionUpdates[actionId]) { _, update in
            model?.take(update)
            if update?.isOpen == false { Task { await fleet.home.refreshAll(fleet.computers, force: true) } }
        }
    }
}

/// The card's open owner actions and push requests (Push on a card).
struct CardOwnerActions: View {
    @Environment(Fleet.self) private var fleet
    @Environment(AppStore.self) private var store
    let projectId: String
    let itemId: String
    @State private var actions: [OwnerAction] = []

    var body: some View {
        Group {
            if !actions.isEmpty {
                Section {
                    ForEach(actions) { action in
                        CardOwnerActionRow(action: action)
                    }
                } header: {
                    SectionTitle(actions.allSatisfy(\.isPush) ? "Push requests" : "Waiting for you to run")
                }
            }
        }
        .task(id: "\(store.reconnects)/\(store.ownerActionUpdates.values.filter { $0.card == itemId }.map(\.state).joined())") {
            await load()
        }
    }

    private func load() async {
        guard store.hasOwnerActions, store.status == .connected else { return }
        let all = (try? await store.ownerActions(projectId: projectId.isEmpty ? nil : projectId)) ?? []
        actions = all.filter { $0.card == itemId && ($0.isOpen || $0.isRunning) }
    }
}

private struct CardOwnerActionRow: View {
    @Environment(Fleet.self) private var fleet
    @Environment(AppStore.self) private var store
    let action: OwnerAction
    @State private var model: OwnerActionModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let current = model?.action ?? action
            HStack(spacing: 8) {
                Image(systemName: current.isPush ? "arrow.up.circle.fill" : "terminal.fill")
                    .foregroundStyle(Tone.needsYou.text)
                    .accessibilityHidden(true)
                Text(OwnerActionWords.title(current, botName: current.botId.flatMap { store.bot($0)?.name }))
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                if let expiry = OwnerActionWords.expiry(current) {
                    Text(expiry).font(.caption).foregroundStyle(Color.secondaryText)
                }
            }
            OwnerActionBody(action: current, output: store.ownerActionOutputs[current.id])
            if !current.isOpen { Pill(text: OwnerActionWords.state(current), tone: OwnerActionWords.tone(current)) }
            if let model, store.canApprove {
                OwnerActionButtons(model: model)
                if let failure = model.failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Color.errorText)
                }
            }
            if current.isOpen {
                Text(OwnerActionWords.promise(current)).font(.caption).foregroundStyle(Color.secondaryText)
            }
        }
        .padding(.vertical, 4)
        .task {
            // The card's screen may not carry its computer: the one whose store this is.
            if model == nil, let computer = fleet.computers.first(where: { $0.store === store }) {
                let made = fleet.ownerActionModel(action.id, on: computer)
                made.take(action)
                model = made
            }
        }
        .onChange(of: store.ownerActionUpdates[action.id]) { _, update in model?.take(update) }
    }
}
