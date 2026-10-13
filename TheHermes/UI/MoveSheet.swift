import SwiftUI

/// "Move to…" (K7): every other column of the card's board with what the
/// daemon says stands in the way, checked before anything is sent, as the
/// desktop's move menu does. A reason or an override field appears only when
/// a rule asks for one. The daemon decides; its refusal is shown as it says it.
struct MoveSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var model: MoveModel
    let columns: [BoardColumnRow]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(model.card.title).font(.headline)
                    if let now = columns.first(where: { $0.key == model.card.columnKey }) {
                        Text("Now in \(now.name)").font(.subheadline).foregroundStyle(Color.secondaryText)
                    }
                }
                switch model.phase {
                case .checking:
                    Section { ProgressView("Checking the columns…") }
                case .failed(let message):
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Color.errorText)
                        Button("Try again") { Task { await model.check(columns: columns) } }
                    }
                default:
                    options
                    fields
                }
                if !model.refusal.isEmpty {
                    Section {
                        ForEach(model.refusal, id: \.self) { line in
                            Label(line, systemImage: "xmark.octagon").foregroundStyle(Color.errorText)
                        }
                    } header: {
                        SectionTitle("Not moved")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Move \(model.card.id)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if model.phase == .sending {
                        ProgressView()
                    } else {
                        Button("Move") { Task { await model.move(columns: columns) } }
                            .disabled(!model.canMove)
                    }
                }
            }
            .task { await model.check(columns: columns) }
            .onChange(of: model.phase) { _, phase in
                if case .moved = phase {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    dismiss()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder private var options: some View {
        Section {
            if model.options.isEmpty {
                EmptyNote(text: "No other column on this board", systemImage: "rectangle.split.3x1")
            }
            ForEach(model.options) { option in
                Button { model.target = option.key } label: { row(option) }
                    .buttonStyle(.plain)
                    .disabled(!option.allowed)
                    .accessibilityAddTraits(model.target == option.key ? .isSelected : [])
            }
        } header: {
            SectionTitle("Move to")
        }
    }

    private func row(_ option: MoveOption) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: model.target == option.key ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(option.allowed ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondaryText))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(option.visible ? option.name : "\(option.name) (hidden)")
                    .font(.body.weight(.medium))
                    .foregroundStyle(option.allowed ? Color.primary : Color.secondaryText)
                Text(option.verdict)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(option.allowed ? (option.unmet.isEmpty ? Color.successText : Color.warningText) : Color.errorText)
                ForEach(MoveOutcome.lines(option.refusals), id: \.self) { line in
                    Text(line).font(.footnote).foregroundStyle(Color.secondaryText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var fields: some View {
        if let chosen = model.chosen, chosen.allowed {
            if chosen.needsReason {
                Section {
                    TextField("Reason", text: $model.reason, prompt: .placeholder("Why it moves"), axis: .vertical)
                        .lineLimit(1...4)
                } header: {
                    SectionTitle("Reason")
                } footer: {
                    Text(chosen.unmet.first { $0.code == MoveOption.reasonCode }?.text ?? "This move needs a reason.")
                        .foregroundStyle(Color.secondaryText)
                }
            }
            if chosen.needsOverride {
                Section {
                    TextField("Override reason", text: $model.overrideReason, prompt: .placeholder("Why it goes past the limit"), axis: .vertical)
                        .lineLimit(1...4)
                } header: {
                    SectionTitle("Over the WIP limit")
                } footer: {
                    Text(chosen.unmet.first { $0.code == MoveOption.wipCode }.map { "\($0.text) Your reason shows on the card." } ?? "")
                        .foregroundStyle(Color.secondaryText)
                }
            }
        }
    }
}
