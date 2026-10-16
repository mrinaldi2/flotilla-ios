import SwiftUI

/// A project's page: its bots, the work around them (workers, their
/// conversations, the shared repository) and the computers it spans.
struct ProjectView: View {
    @Environment(AppStore.self) private var store
    let projectId: String
    @State private var creatingBot = false
    @State private var linking = false
    @State private var editingRepo = false
    @State private var openBot: String?

    private var project: Project? { store.projects.first { $0.id == projectId } }

    var body: some View {
        List {
            if let project {
                let bots = store.bots(in: project)
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: -8) {
                            ForEach(bots.prefix(6)) { bot in
                                AvatarView(avatar: bot.avatar, name: bot.name, size: 34)
                                    .overlay(RoundedRectangle(cornerRadius: 34 * 0.28, style: .continuous).stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2))
                            }
                        }
                        .accessibilityHidden(true)
                        Text(summary(bots)).font(.footnote).foregroundStyle(Color.secondaryText)
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    ForEach(bots) { bot in
                        NavigationLink(value: bot.id) { BotRow(bot: bot) }
                    }
                    if store.canControl, store.status == .connected {
                        Button { creatingBot = true } label: { Label("New bot in \(project.name)", systemImage: "plus") }
                    }
                } header: {
                    SectionTitle("Bots", count: bots.count)
                }
                if store.hasWorkers || store.hasConversations {
                    Section {
                        if store.hasWorkers {
                            NavigationLink(value: WorkersLink(projectId: project.id)) {
                                ItemRow(title: "Temporary workers", subtitle: "Bots spawned for one task each") {
                                    IconTile(systemImage: "person.badge.clock", tone: .worker)
                                }
                            }
                        }
                        if store.hasConversations {
                            NavigationLink(value: ConversationsLink(projectId: project.id)) {
                                ItemRow(title: "Conversations", subtitle: "What the bots say to each other") {
                                    IconTile(systemImage: "bubble.left.and.bubble.right")
                                }
                            }
                        }
                        if store.hasWorkers {
                            Button { editingRepo = true } label: {
                                ItemRow(title: "Shared repository",
                                        subtitle: project.repo.map { "\($0.url) · \($0.branch)" } ?? "None: workers start from an empty folder") {
                                    IconTile(systemImage: "arrow.triangle.branch")
                                } trailing: {
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(!store.canControl)
                        }
                    } header: {
                        SectionTitle("Work")
                    }
                }
                Section {
                    ItemRow(title: store.computerName, subtitle: "This project's home") {
                        IconTile(systemImage: store.kind.symbol, tone: .ready)
                    }
                    ForEach(project.links) { link in
                        ItemRow(title: link.peerName,
                                subtitle: link.remoteProjectName == project.name ? "Linked" : "Linked as \(link.remoteProjectName)") {
                            IconTile(systemImage: "link", tone: link.online ? .ready : nil)
                        } trailing: {
                            StatusLabel(text: link.online ? "Online" : "Offline", tone: link.online ? .ready : .quiet)
                        }
                    }
                    if store.canControl, store.hasLinkedProjects {
                        Button { linking = true } label: {
                            Label(project.links.isEmpty ? "Link with another computer" : "Change linked computers", systemImage: "link")
                        }
                    }
                } header: {
                    SectionTitle("Computers")
                } footer: {
                    Text("A linked project's bots on every computer work as one team and hand each other tasks and files.").foregroundStyle(Color.secondaryText)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(project?.name ?? "Project")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
        .sheet(isPresented: $creatingBot) {
            NewBotSheet(projectId: projectId) { bot in
                creatingBot = false
                openBot = bot.id
            }
        }
        .sheet(isPresented: $linking) { LinkProjectSheet(projectId: projectId) }
        .sheet(isPresented: $editingRepo) { RepoSheet(projectId: projectId) }
        .navigationDestination(item: $openBot) { BotDetailView(botId: $0) }
    }

    private func summary(_ bots: [Bot]) -> String {
        var parts = [bots.count == 1 ? "1 bot" : "\(bots.count) bots"]
        let working = bots.filter { $0.state == .working }.count
        if working > 0 { parts.append("\(working) working") }
        let waiting = bots.filter(\.state.needsOwner).count
        if waiting > 0 { parts.append(waiting == 1 ? "1 needs you" : "\(waiting) need you") }
        if let project, !project.links.isEmpty {
            parts.append("on \(project.links.count + 1) computers")
        }
        return parts.joined(separator: " · ")
    }
}
