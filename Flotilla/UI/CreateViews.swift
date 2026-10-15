import SwiftUI

/// A project is only a name; its folder is derived from it once and never moves.
struct NewProjectSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let created: (Project, _ addBot: Bool) -> Void
    @State private var name = ""
    @State private var addBot = true
    /// A connected daemon to link the new project with; empty for none.
    @State private var linkPeerId = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var peers: [Peer] { store.peers.filter(\.isActive) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Project name", text: $name, prompt: .placeholder("Project name"))
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(create)
                } footer: {
                    Text("Its bots share a folder of artifacts on \(store.computerName): ~/.gravity/projects/<name>.").foregroundStyle(Color.secondaryText)
                }
                if store.hasLinkedProjects, !peers.isEmpty {
                    Section {
                        Picker("Link with", selection: $linkPeerId) {
                            Text("No other computer").tag("")
                            ForEach(peers) { peer in
                                Text(peer.online ? peer.name : "\(peer.name) (offline)").tag(peer.id)
                            }
                        }
                    } footer: {
                        Text(linkPeerId.isEmpty
                             ? "Link it with a connected computer to have bots on both computers in one team."
                             : "A project of the same name is made there and linked: bots on either computer work as one team.")
                            .foregroundStyle(Color.secondaryText)
                    }
                }
                Section {
                    Toggle("Add a first bot next", isOn: $addBot)
                }
            }
            .navigationTitle("New project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else { Button("Create", action: create).disabled(trimmed.isEmpty) }
                }
            }
            .disabled(busy)
            .errorAlert("Couldn’t create the project.", $error)
            .onAppear { focused = true }
            .task { if store.hasLinkedProjects { try? await store.loadPeers() } }
        }
        .presentationDetents([.medium, .large])
    }

    private func create() {
        guard !trimmed.isEmpty, !busy else { return }
        busy = true
        Task {
            do {
                let project = try await store.createProject(name: trimmed)
                if !linkPeerId.isEmpty {
                    do {
                        try await store.linkProject(project.id, peerId: linkPeerId, remoteProjectId: nil)
                    } catch {
                        // The project exists either way; say why it is not linked.
                        self.error = "\(project.name) was created but not linked: \(error.localizedDescription)"
                        busy = false
                        return
                    }
                }
                created(project, addBot)
            } catch {
                self.error = error.localizedDescription
                busy = false
            }
        }
    }
}

/// A bot needs only its project. It starts running as soon as it is created;
/// the charter can be written now or left for the bot to ask about.
struct NewBotSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let created: (Bot) -> Void
    @State private var projectId: String
    @State private var name = ""
    @State private var description = ""
    @State private var instructions = ""
    /// nil: the daemon deals a random icon.
    @State private var avatar: String?
    /// nil: the daemon's default engine.
    @State private var engine: BotEngine?
    /// Empty: this computer; else a peer the project is linked through.
    @State private var peerId = ""
    @State private var busy = false
    @State private var error: String?

    init(projectId: String?, created: @escaping (Bot) -> Void) {
        _projectId = State(initialValue: projectId ?? "")
        self.created = created
    }

    /// Only bots that run here count towards the limit; linked ones run elsewhere.
    private var bots: Int { store.bots.filter { $0.projectId == projectId && !$0.isLinked }.count }
    private var project: Project? { store.projects.first { $0.id == projectId } }
    private var links: [ProjectLink] { store.hasLinkedProjects ? project?.links ?? [] : [] }
    private var full: Bool { peerId.isEmpty && bots >= 12 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Project", selection: $projectId) {
                        ForEach(store.sortedProjects) { Text($0.name).tag($0.id) }
                    }
                    TextField("Name (empty: New Bot)", text: $name, prompt: .placeholder("Name (empty: New Bot)"))
                        .textInputAutocapitalization(.words)
                } footer: {
                    if full {
                        Text("This project already has 12 bots on \(store.computerName), the most Hermes allows. Delete one on your computer first\(links.isEmpty ? "" : ", or run the new one on a linked computer").")
                            .foregroundStyle(Color.warningText)
                    }
                }

                if store.hasEngines || !links.isEmpty {
                    Section {
                        if store.hasEngines {
                            Picker("Engine", selection: $engine) {
                                Text("Default").tag(BotEngine?.none)
                                ForEach(BotEngine.allCases) { Text($0.label).tag(BotEngine?.some($0)) }
                            }
                        }
                        if !links.isEmpty {
                            Picker("Runs on", selection: $peerId) {
                                Text(store.computerName).tag("")
                                ForEach(links) { link in
                                    Text(link.online ? link.peerName : "\(link.peerName) (offline)").tag(link.peerId)
                                }
                            }
                        }
                    } header: {
                        Text("Engine and computer").foregroundStyle(Color.secondaryText)
                    } footer: {
                        Text(peerId.isEmpty
                             ? "Default is the engine Hermes on \(store.computerName) is set to. The bot can switch engines later and keeps its workspace."
                             : "It runs on \(links.first { $0.peerId == peerId }?.peerName ?? "the other computer"), in the linked project, and works with the bots here as one team.")
                            .foregroundStyle(Color.secondaryText)
                    }
                }

                Section {
                    TextField("One line: what this bot is for", text: $description, prompt: .placeholder("One line: what this bot is for"), axis: .vertical)
                        .lineLimit(1...3)
                    TextField("Instructions", text: $instructions, prompt: .placeholder("Instructions"), axis: .vertical)
                        .lineLimit(4...12)
                } header: {
                    Text("Profile").foregroundStyle(Color.secondaryText)
                } footer: {
                    Text("Optional. Without one, the bot asks you what it is for and writes the answer down itself. It can change its own instructions later.").foregroundStyle(Color.secondaryText)
                }

                Section("Avatar") {
                    AvatarPicker(selection: $avatar)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("New bot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else { Button("Create", action: create).disabled(projectId.isEmpty || full) }
                }
            }
            .disabled(busy)
            .errorAlert("Couldn’t create the bot.", $error)
            .onAppear {
                if projectId.isEmpty { projectId = store.sortedProjects.first?.id ?? "" }
            }
            .onChange(of: projectId) { _, _ in peerId = "" }
        }
    }

    private func create() {
        guard !projectId.isEmpty, !busy else { return }
        busy = true
        Task {
            do {
                let bot = try await store.createBot(
                    projectId: projectId,
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                    instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines),
                    avatar: avatar, engine: engine, peerId: peerId.isEmpty ? nil : peerId)
                created(bot)
            } catch {
                self.error = error.localizedDescription
                busy = false
            }
        }
    }
}

/// Gravity's twenty icons, plus "any" for a random one.
private struct AvatarPicker: View {
    @Binding var selection: String?

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
            Button { selection = nil } label: {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 44, height: 44)
                    .overlay { Image(systemName: "shuffle").foregroundStyle(Color.secondaryText) }
                    .overlay(ring(selection == nil))
            }
            .accessibilityLabel("Random avatar")
            ForEach(AvatarView.icons, id: \.self) { icon in
                Button { selection = "icon:\(icon)" } label: {
                    AvatarView(avatar: "icon:\(icon)", name: icon, size: 44)
                        .overlay(ring(selection == "icon:\(icon)"))
                }
                .accessibilityLabel("Avatar \(icon)")
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 6)
    }

    private func ring(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .stroke(selected ? Color.accentColor : .clear, lineWidth: 3)
            .padding(-3)
    }
}
