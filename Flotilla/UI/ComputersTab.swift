import SwiftUI

/// What one computer looks like from the phone: its link, its daemon, its bots.
extension Computer {
    /// How the link is: up, coming up, refused, or down.
    var connectionTone: Tone {
        switch store.status {
        case .connected: .ready
        case .connecting: .working
        case .authFailed, .versionMismatch: .failed
        case .idle, .disconnected: .quiet
        }
    }

    /// The link, or that something there needs the owner.
    var statusTone: Tone {
        switch store.status {
        case .connected: store.decisionsBadge > 0 || !store.approvals.isEmpty ? .needsYou : .ready
        case .connecting: .working
        case .authFailed, .versionMismatch: .failed
        case .idle, .disconnected: .quiet
        }
    }

    /// "Online · 42 ms", "Connecting…", "Token rejected".
    var statusLine: String {
        guard store.status == .connected else { return store.status.label }
        guard let latency = store.latency else { return "Online" }
        let ms = Int((Double(latency.components.attoseconds) / 1e15 + Double(latency.components.seconds) * 1000).rounded())
        return ms < 1 ? "Online · under 1 ms" : "Online · \(ms) ms"
    }

    /// "8 bots · 1 working · 2 need you".
    var botsLine: String {
        let bots = store.bots.filter { !$0.isLinked }
        guard !bots.isEmpty else { return store.status == .connected ? "No bots yet" : "" }
        var parts = [bots.count == 1 ? "1 bot" : "\(bots.count) bots"]
        let working = bots.filter { $0.state == .working }.count
        if working > 0 { parts.append("\(working) working") }
        let waiting = store.decisionsBadge + store.approvals.count
        if waiting > 0 { parts.append(waiting == 1 ? "1 needs you" : "\(waiting) need you") }
        return parts.joined(separator: " · ")
    }
}

/// The Computers tab: every computer this iPhone reaches, how each link is
/// doing, the links between them, and adding another.
struct ComputersView: View {
    @Environment(Fleet.self) private var fleet
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(fleet.computers) { computer in
                        NavigationLink {
                            ComputerPage(computer: computer).computerEnvironment(computer)
                        } label: {
                            ItemRow(title: computer.name, subtitle: computer.statusLine, detail: computer.botsLine) {
                                IconTile(systemImage: computer.kind.symbol, tone: computer.connectionTone, size: 40)
                            } trailing: {
                                StatusDot(tone: computer.statusTone)
                            }
                        }
                    }
                    Button { adding = true } label: {
                        Label("Add a computer", systemImage: "plus")
                    }
                } header: {
                    SectionTitle("This iPhone reaches", count: fleet.computers.count)
                } footer: {
                    Text("Every computer stays connected, so notifications and decisions come from all of them.").foregroundStyle(Color.secondaryText)
                }
                Section {
                    NavigationLink {
                        NetworkView(embedded: true)
                    } label: {
                        ItemRow(title: "Links between computers", subtitle: "Pair computers so their bots work as one team") {
                            IconTile(systemImage: "link", tone: .working)
                        }
                    }
                } header: {
                    SectionTitle("Network")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Computers")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add a computer")
                }
            }
            .sheet(isPresented: $adding) { ConnectView(adding: true) }
        }
    }
}

/// One computer: how it is reached, its screen and disk, its bots, and the
/// settings that belong to it.
struct ComputerPage: View {
    @Environment(Fleet.self) private var fleet
    @Environment(AppStore.self) private var store
    @Environment(LensStore.self) private var lens
    let computer: Computer
    @State private var diagnostics: Diagnostics?
    @State private var opening: Place?

    /// Where the two big tiles lead.
    enum Place: Hashable, Identifiable {
        case screen, files
        var id: Self { self }
    }

    /// Its own bots, the ones needing the owner first, then the busy ones.
    private var bots: [Bot] {
        store.bots.filter { !$0.isLinked }.sorted { a, b in
            let rank = { (bot: Bot) in bot.state.needsOwner ? 0 : bot.state == .working ? 1 : 2 }
            return rank(a) != rank(b) ? rank(a) < rank(b) : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    IconTile(systemImage: computer.kind.symbol, tone: computer.connectionTone, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        StatusLabel(text: computer.statusLine, tone: computer.connectionTone, busy: store.status == .connecting)
                        Text(computer.botsLine).font(.footnote).foregroundStyle(Color.secondaryText)
                    }
                }
                .padding(.vertical, 4)
                if case .disconnected(let reason) = store.status {
                    Text(reason).font(.footnote).foregroundStyle(Color.secondaryText)
                    Button("Reconnect now") { store.client.reconnectNow() }
                }
                if case .authFailed(let reason) = store.status { Text(reason).font(.footnote).foregroundStyle(Color.errorText) }
                if case .versionMismatch(let reason) = store.status { Text(reason).font(.footnote).foregroundStyle(Color.errorText) }
            }
            Section {
                HStack(spacing: 12) {
                    tile("Screen", "Control the desktop", "display", .screen)
                    tile("Files on \(computer.name)", "Browse the disk", "folder", .files)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            if !bots.isEmpty {
                Section {
                    ForEach(bots.prefix(8)) { bot in
                        NavigationLink {
                            BotDetailView(botId: bot.id)
                        } label: {
                            ItemRow(title: bot.name, subtitle: store.projectName(bot.projectId)) {
                                AvatarView(avatar: bot.avatar, name: bot.name, size: 36)
                            } trailing: {
                                StateBadge(state: bot.state)
                            }
                        }
                    }
                } header: {
                    SectionTitle("Bots here", count: bots.count)
                } footer: {
                    if bots.count > 8 { Text("All of them are on the Bots tab, with \(computer.name) picked.").foregroundStyle(Color.secondaryText) }
                }
            }
            Section {
                if let endpoint = store.endpoint {
                    LabeledContent("Address", value: "\(endpoint.host):\(endpoint.port)")
                }
                if !store.serverVersion.isEmpty {
                    LabeledContent("Hermes service", value: store.serverVersion)
                }
                LabeledContent("Access", value: store.grants.sorted().joined(separator: ", "))
                if let diagnostics {
                    LabeledContent("Active bots", value: "\(diagnostics.activeBots)")
                    let engine = BotEngine(rawValue: diagnostics.runtimeKind)?.label ?? diagnostics.runtimeKind
                    LabeledContent("Engine", value: diagnostics.runtimeAvailable ? engine : "\(engine) (unavailable)")
                    LabeledContent("Database", value: diagnostics.dbHealthy ? "Healthy" : "Degraded")
                    LabeledContent("Undelivered messages", value: "\(diagnostics.deliveryBacklog)")
                    LabeledContent("Uptime", value: uptime(diagnostics.uptimeSeconds))
                    if diagnostics.staleBuild {
                        Label("The Hermes service was updated on disk and needs a restart.", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(Color.warningText)
                    }
                }
            } header: {
                SectionTitle("Hermes service")
            }
            Section {
                LabeledContent("Status", value: lens.status.label)
                if case .unreachable(let reason) = lens.status {
                    Text(reason).font(.footnote).foregroundStyle(Color.secondaryText)
                }
                LabeledContent("Port", value: String(lens.port))
                Button("Check now") { Task { await lens.refresh() } }
            } header: {
                SectionTitle("Lens")
            } footer: {
                Text("The companion that turns the bots' logs into Activity and artifacts, and serves the file browser. It uses the same device token as the Hermes service.").foregroundStyle(Color.secondaryText)
            }
            MacSettingsSection()
            Section {
                NavigationLink("Name, addresses and token") { ComputerEditor(computer: computer) }
            } header: {
                SectionTitle("This computer")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(computer.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: store.status) {
            await loadDiagnostics()
            // Only the computer on screen elsewhere keeps its Lens checked.
            if lens.status == .unknown, store.status == .connected { await lens.refresh() }
        }
        .refreshable { await loadDiagnostics() }
        .navigationDestination(item: $opening) { place in
            switch place {
            case .screen: ScreenView().navigationTitle("Screen").navigationBarTitleDisplayMode(.inline)
            case .files: FolderView(path: "")
            }
        }
    }

    // Buttons rather than links: a link in a list row gets the row's arrow.
    private func tile(_ title: String, _ subtitle: String, _ symbol: String, _ place: Place) -> some View {
        Button {
            opening = place
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                IconTile(systemImage: symbol, tone: .working, size: 36)
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(subtitle).font(.footnote).foregroundStyle(Color.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func loadDiagnostics() async {
        guard let reply = try? await store.client.request("diagnostics"),
              let body = reply.dict("diagnostics") else { return }
        diagnostics = Diagnostics(body)
    }

    private func uptime(_ seconds: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds) s"
    }
}
