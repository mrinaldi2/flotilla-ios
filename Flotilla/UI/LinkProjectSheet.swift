import SwiftUI

/// Links a project with one on a connected daemon, so their bots work as one
/// team across the two machines, or removes such a link.
struct LinkProjectSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let projectId: String
    @State private var peerId = ""
    @State private var remote: [PeerProject] = []
    /// nil: a new project on the peer, named like this one.
    @State private var remoteId: String?
    @State private var loading = false
    @State private var busy = false
    @State private var failure: String?
    @State private var showingNetwork = false
    /// The link waiting for the owner to confirm Unlink.
    @State private var unlinking: ProjectLink?

    private var project: Project? { store.projects.first { $0.id == projectId } }
    private var peers: [Peer] { store.peers.filter(\.isActive) }
    private var linkedPeers: Set<String> { Set(project?.links.map(\.peerId) ?? []) }
    private var available: [Peer] { peers.filter { !linkedPeers.contains($0.id) } }

    var body: some View {
        NavigationStack {
            Form {
                if !store.hasLinkedProjects {
                    Section {
                        Text("The Hermes on \(store.computerName) does not link projects yet. It needs a Hermes service with linked projects; this phone already speaks it.")
                            .foregroundStyle(Color.secondaryText)
                    }
                }
                if let links = project?.links, !links.isEmpty {
                    Section("Linked") {
                        ForEach(links) { link in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(link.remoteProjectName)
                                    Text("on \(link.peerName)\(link.online ? "" : " · offline")")
                                        .font(.caption).foregroundStyle(Color.secondaryText)
                                }
                                Spacer()
                                Button("Unlink", role: .destructive) { unlinking = link }
                                    .buttonStyle(.borderless)
                                    .disabled(busy || !store.canControl)
                            }
                        }
                    }
                }
                if store.hasLinkedProjects {
                    if available.isEmpty {
                        Section {
                            Text(peers.isEmpty
                                 ? "\(store.computerName) is not connected to another computer yet."
                                 : "Linked with every connected computer.")
                                .foregroundStyle(Color.secondaryText)
                            Button("Open the network", systemImage: "point.3.connected.trianglepath.dotted") { showingNetwork = true }
                        }
                    } else {
                        Section {
                            Picker("Computer", selection: $peerId) {
                                ForEach(available) { peer in
                                    Text(peer.online ? peer.name : "\(peer.name) (offline)").tag(peer.id)
                                }
                            }
                        } header: {
                            Text("Link with").foregroundStyle(Color.secondaryText)
                        }
                        Section {
                            choice(nil, title: "New project “\(project?.name ?? "")”", detail: "Created there, named like this one")
                            if loading { ProgressView() }
                            ForEach(remote) { other in
                                let taken = other.linkedProjectId != nil && other.linkedProjectId != projectId
                                choice(other.id, title: other.name,
                                       detail: taken ? "Already linked with another project"
                                           : "\(other.botCount) bot\(other.botCount == 1 ? "" : "s")")
                                    .disabled(taken)
                            }
                        } header: {
                            Text("Project there").foregroundStyle(Color.secondaryText)
                        } footer: {
                            Text("Every bot on each side joins the other as a linked bot, and stays in step as bots come and go. They hand each other tasks and files like local bots. Bot names must be unique across both.").foregroundStyle(Color.secondaryText)
                        }
                    }
                }
            }
            .navigationTitle("Link \(project?.name ?? "project")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else if store.hasLinkedProjects, !available.isEmpty {
                        Button("Link", action: link).disabled(peerId.isEmpty || !store.canControl)
                    }
                }
            }
            .confirmationDialog("Unlink \(unlinking?.remoteProjectName ?? "")?", isPresented: Binding(
                get: { unlinking != nil }, set: { if !$0 { unlinking = nil } }), titleVisibility: .visible
            ) {
                if let unlinking {
                    Button("Unlink project", role: .destructive) { unlink(unlinking) }
                }
            } message: {
                Text("The bots on \(unlinking?.peerName ?? "the other computer") leave \(project?.name ?? "this project"), and this project's bots leave theirs. History is kept, and you can link again later.")
            }
            .errorAlert("Couldn’t change the link.", $failure)
            .task {
                try? await store.loadPeers()
                if peerId.isEmpty { peerId = available.first(where: \.online)?.id ?? available.first?.id ?? "" }
            }
            .task(id: peerId) { await loadRemote() }
            .sheet(isPresented: $showingNetwork) { NetworkView() }
        }
    }

    private func choice(_ id: String?, title: String, detail: String) -> some View {
        Button { remoteId = id } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(Color.secondaryText)
                }
                Spacer()
                if remoteId == id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
        }
    }

    private func loadRemote() async {
        remote = []
        remoteId = nil
        guard store.hasLinkedProjects, !peerId.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            remote = try await store.peerProjects(peerId: peerId)
            // A project of the same name is most likely the one meant.
            remoteId = remote.first { $0.name == project?.name && $0.linkedProjectId == nil }?.id
        } catch {
            failure = error.localizedDescription
        }
    }

    private func link() {
        busy = true
        Task {
            do {
                try await store.linkProject(projectId, peerId: peerId, remoteProjectId: remoteId)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
            busy = false
        }
    }

    private func unlink(_ link: ProjectLink) {
        busy = true
        Task {
            do {
                try await store.unlinkProject(projectId, peerId: link.peerId)
            } catch {
                failure = error.localizedDescription
            }
            busy = false
        }
    }
}
