import SwiftUI

/// The chip at the top left of every main tab: which computer the tab
/// shows, a dot for how each of the others is doing, and the menu to switch.
struct ComputerSwitcher: View {
    @Environment(Fleet.self) private var fleet
    @Environment(Computer.self) private var current
    @State private var adding = false

    var body: some View {
        Menu {
            ForEach(fleet.computers) { computer in
                Button { fleet.select(computer) } label: {
                    Label(title(computer), systemImage: computer.id == current.id ? "checkmark" : computer.kind.symbol)
                }
            }
            Divider()
            Button { adding = true } label: { Label("Add a computer", systemImage: "plus") }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: current.kind.symbol).font(.footnote.weight(.semibold))
                Text(current.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                if fleet.computers.count > 1 {
                    HStack(spacing: 3) {
                        ForEach(fleet.computers) { StatusDot(tone: $0.statusTone, size: 6) }
                    }
                }
                Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(Color.secondaryText)
            }
            .foregroundStyle(.primary)
        }
        .accessibilityLabel("Computer: \(current.name)")
        .sheet(isPresented: $adding) { ConnectView(adding: true) }
    }

    private func title(_ computer: Computer) -> String {
        var parts = [computer.name]
        if computer.store.status != .connected { parts.append(computer.store.status.label) }
        let waiting = computer.store.decisionsBadge + computer.store.approvals.count
        if waiting > 0 { parts.append(waiting == 1 ? "1 needs you" : "\(waiting) need you") }
        return parts.joined(separator: " · ")
    }
}

/// A computer's name, addresses and token.
struct ComputerEditor: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.dismiss) private var dismiss
    let computer: Computer
    @State private var record: ComputerRecord
    @State private var port: String
    @State private var lensPort: String
    @State private var token = ""
    @State private var confirmRemove = false

    init(computer: Computer) {
        self.computer = computer
        _record = State(initialValue: computer.record)
        _port = State(initialValue: String(computer.record.port))
        _lensPort = State(initialValue: String(computer.record.lensPort))
    }

    private var edited: ComputerRecord {
        var result = record
        result.name = record.name.trimmingCharacters(in: .whitespaces)
        result.host = record.host.trimmingCharacters(in: .whitespaces)
        result.lensHost = record.lensHost.trimmingCharacters(in: .whitespaces)
        result.port = Int(port) ?? record.port
        result.lensPort = Int(lensPort) ?? record.lensPort
        return result
    }

    private var valid: Bool { !edited.name.isEmpty && !edited.host.isEmpty && Int(port) != nil && Int(lensPort) != nil }

    var body: some View {
        Form {
            Section("Computer") {
                TextField("Name", text: $record.name, prompt: .placeholder("Name"))
                Picker("Type", selection: $record.kind) {
                    Text("Mac").tag(ComputerKind.mac)
                    Text("Windows").tag(ComputerKind.windows)
                }
            }
            Section {
                TextField("Tailscale name or 100.x.y.z", text: $record.host, prompt: .placeholder("Tailscale name or 100.x.y.z"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                LabeledContent("Port") {
                    TextField("49777", text: $port, prompt: .placeholder("49777")).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Hermes service").foregroundStyle(Color.secondaryText)
            }
            Section {
                TextField("Address (empty: same as the Hermes service)", text: $record.lensHost, prompt: .placeholder("Address (empty: same as the Hermes service)"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                LabeledContent("Port") {
                    TextField("49778", text: $lensPort, prompt: .placeholder("49778")).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Lens").foregroundStyle(Color.secondaryText)
            }
            Section {
                Button("Save") {
                    fleet.update(computer, edited)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
                .disabled(!valid || edited == computer.record)
            }
            Section {
                SecureField("New device token", text: $token, prompt: .placeholder("New device token"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Replace token") {
                    computer.setToken(token.trimmingCharacters(in: .whitespacesAndNewlines))
                    token = ""
                }
                .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                Text("For a token that was revoked or rejected. Create one on \(computer.name) in The Hermes → Settings → Devices.").foregroundStyle(Color.secondaryText)
            }
            Section {
                Button("Remove \(computer.name)", role: .destructive) { confirmRemove = true }
            } footer: {
                Text("Removes its token and screen password from this iPhone. To cut off a lost phone, revoke the device on that computer in The Hermes → Settings → Devices.").foregroundStyle(Color.secondaryText)
            }
        }
        .navigationTitle(computer.name)
        .confirmationDialog("Remove \(computer.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove computer", role: .destructive) {
                dismiss()
                fleet.remove(computer)
            }
        }
    }
}
