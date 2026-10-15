import SwiftUI

/// Where a computer's Hermes service is and the device token to use: the
/// first-run screen, and the sheet that adds another computer. A pairing code
/// or link fills everything in one step; the sheet stays open until the
/// service answers, and says which field to fix when it does not.
struct ConnectView: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.dismiss) private var dismiss
    /// Shown as a sheet over the app, with a Cancel button.
    var adding = false
    /// A pairing link the system opened the app with. It fills the form but
    /// waits for Connect: a link from a web page or message is not something
    /// the owner chose to scan.
    var initialLink: PairingLink? = nil
    @State private var fromLink = false
    @State private var name = ""
    @State private var kind = ComputerKind.mac
    @State private var host = ""
    @State private var port = "49777"
    @State private var token = ""
    /// Computers to pair the new one with once it is connected.
    @State private var linkWith: Set<String> = []
    @State private var manual = false
    @State private var scanning = false
    @State private var scannerMissing = false
    @State private var pasteFailed = false
    /// The computer being tried: connected on its own, saved only once its
    /// Hermes service answers.
    @State private var trying: Computer?
    @State private var failure: PairingFailure?

    private static let errorRow = "pairing-error"

    /// How long to wait for the Hermes service to answer.
    static let answerTimeout: Duration = .seconds(15)

    /// The computers already here that could be paired with the new one.
    private var linkable: [Computer] {
        fleet.computers.filter { $0.store.status == .connected && $0.store.canControl }
    }

    private var valid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && Int(port) != nil
            && !token.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var computerName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? kind.label : trimmed
    }

    private var configPath: String {
        kind == .mac ? "~/.gravity/gravityd.toml" : "%USERPROFILE%\\.gravity\\gravityd.toml"
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    Section {
                        Button { scan() } label: {
                            Label("Scan pairing code", systemImage: "qrcode.viewfinder")
                                .labelStyle(.titleAndIcon)
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        // A plain button rather than PasteButton, whose label is
                        // fixed to "Paste"; iOS asks once before the app reads it.
                        Button { pasted(UIPasteboard.general.string ?? "") } label: {
                            Label("Paste pairing link", systemImage: "doc.on.clipboard")
                                .labelStyle(.titleAndIcon)
                        }
                        Button { withAnimation { manual.toggle() } } label: {
                            HStack {
                                Text("Enter manually")
                                Spacer()
                                Image(systemName: manual ? "chevron.down" : "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.secondaryText)
                            }
                        }
                    } footer: {
                        if pasteFailed {
                            Text("That isn’t a pairing link. It starts with thehermes://pair and comes from The Hermes on your computer: Settings → Devices.")
                                .foregroundStyle(Color.warningText)
                        } else {
                            // Until desktop shows pairing codes (H-010 desktop), it may show only a token.
                            Text("On your computer, open The Hermes → Settings → Devices and create a device. Scan its pairing code, or, if it shows only a token, choose Enter manually.")
                                .foregroundStyle(Color.secondaryText)
                        }
                    }
                    .disabled(trying != nil)

                    if fromLink, trying == nil, failure == nil {
                        Section {
                            Label("Opened from a pairing link. Check the computer and its address, then tap Connect.",
                                  systemImage: "link")
                                .font(.footnote)
                        }
                    }

                    if let trying {
                        Section {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Connecting to \(trying.name)…")
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } else if let failure, failure.field == .version {
                        // No field to fix: said here. The others are said next
                        // to their field, which is scrolled into view.
                        Section { failureText(failure) }
                    }

                    if manual {
                        manualSections
                    }

                    if adding, !linkable.isEmpty {
                        Section {
                            ForEach(linkable) { computer in
                                Toggle(isOn: Binding(
                                    get: { linkWith.contains(computer.id) },
                                    set: { if $0 { linkWith.insert(computer.id) } else { linkWith.remove(computer.id) } })
                                ) {
                                    ItemRow(title: computer.name, subtitle: "Its bots can work with the new computer's") {
                                        IconTile(systemImage: computer.kind.symbol, tone: .ready)
                                    }
                                }
                            }
                        } header: {
                            Text("Link it with").foregroundStyle(Color.secondaryText)
                        } footer: {
                            Text("Linked computers can share projects and hand each other tasks. You can change this later under Computers → Network.").foregroundStyle(Color.secondaryText)
                        }
                    }
                }
                // A scanned link leaves the fields below the fold: bring the
                // field to fix into view.
                .onChange(of: failure) { _, failure in
                    guard let failure, failure.field != .version else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        withAnimation { proxy.scrollTo(Self.errorRow, anchor: .center) }
                    }
                }
            }
            .navigationTitle(adding ? "Add a computer" : "Connect to The Hermes")
            .onAppear {
                linkWith = Set(linkable.map(\.id))
                #if DEBUG
                // Screenshots and checks without a camera: -pairLink <link> pairs as if scanned.
                if trying == nil, let text = UserDefaults.standard.string(forKey: "pairLink") { pasted(text) }
                #endif
            }
            .onChange(of: initialLink, initial: true) { _, link in
                if let link { prefill(link) }
            }
            .onDisappear { stopTrying() }
            .toolbar {
                if adding {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { stopTrying(); dismiss() } }
                }
            }
            .sheet(isPresented: $scanning) {
                PairingScannerSheet { link in use(link) }
            }
            .alert("Can’t scan here", isPresented: $scannerMissing) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("This iPhone can’t scan codes right now. Paste the pairing link, or enter it manually.")
            }
        }
    }

    @ViewBuilder private var manualSections: some View {
        Section {
            Picker("Type", selection: $kind) {
                Text("Mac").tag(ComputerKind.mac)
                Text("Windows").tag(ComputerKind.windows)
            }
            .pickerStyle(.segmented)
            LabeledContent("Name") {
                TextField("Name", text: $name, prompt: .placeholder(kind.label))
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("Computer").foregroundStyle(Color.secondaryText)
        }

        Section {
            LabeledContent("Address") {
                TextField("Address", text: $host, prompt: .placeholder("Tailscale name or 100.x.y.z"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Port") {
                TextField("Port", text: $port, prompt: .placeholder("49777"))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            }
            if let failure, failure.field == .address { failureText(failure).id(Self.errorRow) }
        } header: {
            Text("Hermes service").foregroundStyle(Color.secondaryText)
        } footer: {
            Text("The computer running The Hermes, as Tailscale shows it. The Hermes service must list that Tailscale address under bind in \(configPath).").foregroundStyle(Color.secondaryText)
        }

        Section {
            LabeledContent("Token") {
                SecureField("Token", text: $token, prompt: .placeholder("Device token"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
            }
            if let failure, failure.field == .token { failureText(failure).id(Self.errorRow) }
        } header: {
            Text("Device token").foregroundStyle(Color.secondaryText)
        } footer: {
            Text("In The Hermes on that computer: Settings → Devices → add a device with read, control and approve. The token is shown once. It is stored in this iPhone's Keychain.").foregroundStyle(Color.secondaryText)
        }

        Section {
            Button("Connect") { connect() }
                .disabled(!valid || trying != nil)
        }
    }

    private func failureText(_ failure: PairingFailure) -> some View {
        Label(failure.message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(Color.errorText)
    }

    // MARK: Filling in

    private func scan() {
        pasteFailed = false
        if PairingScanner.isAvailable { scanning = true } else { scannerMissing = true }
    }

    private func pasted(_ text: String) {
        if let link = PairingLink.parse(text) {
            use(link)
        } else {
            pasteFailed = true
        }
    }

    /// A scanned or pasted link: everything is known, so connect straight away.
    private func use(_ link: PairingLink) {
        fill(link)
        fromLink = false
        connect()
    }

    /// A link from outside the app: filled in, shown, and left for Connect.
    private func prefill(_ link: PairingLink) {
        stopTrying()
        failure = nil
        fill(link)
        fromLink = true
        manual = true
    }

    private func fill(_ link: PairingLink) {
        pasteFailed = false
        host = link.host
        port = String(link.port)
        token = link.token
        if let linkKind = link.kind { kind = linkKind }
        if let linkName = link.name { name = linkName }
    }

    // MARK: Connecting

    private func connect() {
        stopTrying()
        failure = nil
        let hostName = host.trimmingCharacters(in: .whitespaces)
        let portNumber = Int(port) ?? PairingLink.defaultPort
        let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = ComputerRecord(name: computerName, kind: kind, host: hostName, port: portNumber)
        let computer = Computer(record, token: secret)
        trying = computer
        Task { @MainActor in
            let outcome = await Self.answer(from: computer)
            guard trying === computer else { return }
            if outcome == .connected {
                trying = nil
                connected(computer, token: secret)
            } else {
                stopTrying()
                failure = PairingFailure.from(outcome, host: hostName, port: portNumber, computer: computerName)
                    ?? PairingFailure.unreachable(host: hostName, port: portNumber)
                // The field to fix has to be on screen.
                if failure?.field != .version { manual = true }
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    /// The first settled status: connected, or the failure that ended the
    /// first attempt. A service that never answers counts as unreachable.
    private static func answer(from computer: Computer) async -> ConnectionStatus {
        let deadline = ContinuousClock.now + answerTimeout
        while ContinuousClock.now < deadline {
            switch computer.store.status {
            case .connected, .authFailed, .versionMismatch, .disconnected: return computer.store.status
            case .idle, .connecting: break
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return .disconnected("No answer.")
    }

    private func stopTrying() {
        trying?.store.disconnect()
        trying = nil
    }

    private func connected(_ added: Computer, token: String) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let others = fleet.computers.filter { linkWith.contains($0.id) }
        fleet.adopt(added, token: token)
        if adding { dismiss() }
        guard !others.isEmpty else { return }
        Task { @MainActor in
            for other in others where fleet.peer(of: added, for: other) == nil {
                try? await fleet.connect(added, to: other)
            }
        }
    }
}
