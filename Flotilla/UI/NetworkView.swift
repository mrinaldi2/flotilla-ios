import SwiftUI

/// The peer network: which Gravity daemons are paired with which, whether
/// each link is up, and the way to connect or unlink them. Paired daemons
/// can link projects and hand work to each other's bots.
struct NetworkView: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.dismiss) private var dismiss
    /// computer id → why its peers could not be listed.
    @State private var errors: [String: String] = [:]
    @State private var working: String?
    @State private var failure: String?
    @State private var unlinking: Unlink?

    private struct Unlink: Identifiable {
        let computer: Computer
        let peer: Peer
        var id: String { peer.id }
    }

    private var online: [Computer] {
        fleet.computers.filter { $0.store.status == .connected }
    }

    /// Pairs of the phone's computers that are not connected to each other yet.
    private var unpaired: [(Computer, Computer)] {
        var pairs: [(Computer, Computer)] = []
        for (index, a) in online.enumerated() {
            for b in online.dropFirst(index + 1)
            where fleet.peer(of: a, for: b) == nil && fleet.peer(of: b, for: a) == nil {
                pairs.append((a, b))
            }
        }
        return pairs
    }

    /// Pushed inside another screen's navigation, rather than a sheet of its own.
    var embedded = false

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack {
                content.toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
        }
    }

    private var content: some View {
            List {
                if !unpaired.isEmpty {
                    Section {
                        ForEach(unpaired, id: \.0.id) { a, b in
                            Button {
                                run("\(a.id)-\(b.id)") { try await fleet.connect(a, to: b) }
                            } label: {
                                HStack {
                                    Label("Connect \(a.name) and \(b.name)", systemImage: "link")
                                    Spacer()
                                    if working == "\(a.id)-\(b.id)" { ProgressView() }
                                }
                            }
                            .disabled(working != nil || !a.store.canControl || !b.store.canControl)
                        }
                    } header: {
                        Text("Connect").foregroundStyle(Color.secondaryText)
                    } footer: {
                        Text("\(unpaired.first?.1.name ?? "The second computer") listens for the other, so it needs its Tailscale address under bind in gravityd.toml, as it does for this phone.").foregroundStyle(Color.secondaryText)
                    }
                }

                ForEach(fleet.computers) { computer in
                    Section {
                        if let error = errors[computer.id] {
                            Text(error).font(.footnote).foregroundStyle(Color.secondaryText)
                        }
                        let peers = computer.store.peers.filter(\.isActive)
                        if peers.isEmpty, errors[computer.id] == nil {
                            Text("Not connected to another computer.").foregroundStyle(Color.secondaryText)
                        }
                        ForEach(peers) { peer in
                            PeerRow(peer: peer, known: known(peer, of: computer))
                                .swipeActions {
                                    if computer.store.canControl {
                                        Button("Unlink", role: .destructive) { unlinking = Unlink(computer: computer, peer: peer) }
                                    }
                                }
                                .contextMenu {
                                    if computer.store.canControl {
                                        Button("Unlink", systemImage: "link.badge.minus", role: .destructive) {
                                            unlinking = Unlink(computer: computer, peer: peer)
                                        }
                                    }
                                }
                        }
                    } header: {
                        Label(computer.name, systemImage: computer.kind.symbol).foregroundStyle(Color.secondaryText)
                    } footer: {
                        if computer.store.status != .connected {
                            Text(computer.store.status.label).foregroundStyle(Color.secondaryText)
                        }
                    }
                }

                Section {
                    NavigationLink {
                        InviteView()
                    } label: {
                        Label("Connect a computer this phone doesn't know", systemImage: "qrcode")
                    }
                } footer: {
                    Text("Connected computers can link projects, so their bots work as one team and hand each other tasks and files. Unlinking stops that on both sides; history is kept.").foregroundStyle(Color.secondaryText)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Network")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await load() }
            .task {
                // Online state changes as links come and go.
                while !Task.isCancelled {
                    await load()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
            .confirmationDialog("Unlink \(unlinking?.peer.name ?? "")?", isPresented: Binding(
                get: { unlinking != nil }, set: { if !$0 { unlinking = nil } }), titleVisibility: .visible
            ) {
                if let unlinking {
                    Button("Unlink computer", role: .destructive) { unlink(unlinking) }
                }
            } message: {
                Text("Projects linked through it are unlinked, and its bots leave them on both sides. You can connect again later.")
            }
            .errorAlert("Couldn’t change the connection.", $failure)
    }

    /// The phone's own computer this peer is, if any.
    private func known(_ peer: Peer, of computer: Computer) -> Computer? {
        fleet.computers.first { $0.id != computer.id && fleet.peer(of: computer, for: $0)?.id == peer.id }
    }

    private func load() async {
        for computer in online {
            do {
                try await computer.store.loadPeers()
                errors[computer.id] = nil
            } catch {
                errors[computer.id] = "This computer can’t connect to other computers: \(error.localizedDescription)"
            }
        }
    }

    private func unlink(_ target: Unlink) {
        run(target.peer.id) {
            if let other = known(target.peer, of: target.computer) {
                try await fleet.disconnect(target.computer, other)
            } else {
                try await target.computer.store.revokePeer(target.peer.id)
            }
        }
    }

    private func run(_ id: String, _ action: @escaping () async throws -> Void) {
        working = id
        Task {
            do {
                try await action()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                failure = error.localizedDescription
            }
            working = nil
            await load()
        }
    }
}

private struct PeerRow: View {
    let peer: Peer
    /// One of the phone's computers, when the peer is.
    let known: Computer?

    private var status: String {
        if peer.online { return peer.url == nil ? "Online · dials in" : "Online" }
        if let seen = peer.lastSeenAt { return "Offline · last seen \(seen.relative)" }
        return "Waiting for the first connection"
    }

    var body: some View {
        ItemRow(title: peer.name, subtitle: status) {
            IconTile(systemImage: known?.kind.symbol ?? "server.rack", tone: peer.online ? .ready : nil)
        } trailing: {
            StatusDot(tone: peer.online ? .ready : .quiet)
        }
    }
}

/// Pairing with a Gravity the phone has no token for: one side makes a
/// code, the other adds it.
private struct InviteView: View {
    @Environment(Fleet.self) private var fleet
    @State private var computerId = ""
    @State private var otherName = ""
    @State private var invite: String?
    @State private var code = ""
    @State private var busy = false
    @State private var failure: String?
    @State private var added = false

    private var computer: Computer? {
        fleet.computers.first { $0.id == computerId } ?? fleet.computers.first
    }

    private var name: String { otherName.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        Form {
            Section {
                Picker("This phone's computer", selection: $computerId) {
                    ForEach(fleet.computers) { Text($0.name).tag($0.id) }
                }
                TextField("Name for the other computer", text: $otherName, prompt: .placeholder("Name for the other computer"))
            }
            Section {
                Button("Create an invite code") { createInvite() }
                    .disabled(name.isEmpty || busy)
                if let invite {
                    Text(invite).font(.caption.monospaced()).textSelection(.enabled)
                    Button("Copy code", systemImage: "doc.on.doc") { UIPasteboard.general.string = invite }
                }
            } header: {
                Text("The other computer connects to this one").foregroundStyle(Color.secondaryText)
            } footer: {
                Text("Paste the code on the other computer: hermesd peer add <name> \"<code>\". It holds a token and works once.").foregroundStyle(Color.secondaryText)
            }
            Section {
                TextField("ws://…/peer#…", text: $code, prompt: .placeholder("ws://…/peer#…"), axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.caption.monospaced())
                Button(added ? "Added" : "Add with this code") { addPeer() }
                    .disabled(name.isEmpty || code.isEmpty || busy || added)
            } header: {
                Text("This computer connects to the other").foregroundStyle(Color.secondaryText)
            } footer: {
                Text("Make the code on the other computer: hermesd peer invite <name>.").foregroundStyle(Color.secondaryText)
            }
        }
        .navigationTitle("Invite codes")
        .navigationBarTitleDisplayMode(.inline)
        .errorAlert("Couldn’t connect the computers.", $failure)
        .onAppear { if computerId.isEmpty { computerId = fleet.selected?.id ?? "" } }
    }

    private func createInvite() {
        guard let computer else { return }
        busy = true
        Task {
            do { invite = try await computer.store.createPeerInvite(name: name) } catch { failure = error.localizedDescription }
            busy = false
        }
    }

    private func addPeer() {
        guard let computer else { return }
        busy = true
        Task {
            do {
                try await computer.store.addPeer(name: name, invite: code.trimmingCharacters(in: .whitespacesAndNewlines))
                added = true
            } catch {
                failure = error.localizedDescription
            }
            busy = false
        }
    }
}
