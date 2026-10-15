import SwiftUI

/// The Control Center: what the bots are waiting on the owner to rule on.
struct DecisionsView: View {
    @Environment(AppStore.self) private var store
    @Binding var openDecision: String?
    @State private var path = NavigationPath()
    @State private var openBot: String?
    /// A prompt to scroll to, from a tapped notification.
    var focusPermission: Binding<String?> = .constant(nil)

    private var pending: [Decision] {
        store.decisions.filter(\.pending).sorted { lhs, rhs in
            if lhs.urgent != rhs.urgent { return lhs.urgent }
            return (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast)
        }
    }

    private var held: [Decision] { store.decisions.filter { $0.state == "held" } }

    private var closed: [Decision] {
        Array(store.decisions.filter { $0.state == "settled" || $0.state == "withdrawn" }.prefix(store.settledLimit))
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
            List {
                if store.hasPermissions, !store.permissions.isEmpty {
                    Section {
                        ForEach(store.permissions) { request in
                            PermissionCard(request: request) { openBot = $0 }
                                .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .id(request.id)
                        }
                    } header: {
                        SectionTitle("Permission requests", count: store.permissions.count)
                    }
                }
                section("Open", pending)
                section("On hold", held)
                // Waiting and held ones all load; settled ones a page at a time.
                section("Settled", closed, more: closed.count >= store.settledLimit)
            }
            .listStyle(.insetGrouped)
            .onChange(of: focusPermission.wrappedValue, initial: true) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .top) }
                focusPermission.wrappedValue = nil
            }
            }
            .overlay {
                if store.decisions.isEmpty, store.permissions.isEmpty {
                    ContentUnavailableView("Nothing to decide", systemImage: "checkmark.circle",
                                           description: Text("Bots raise decisions here when they need your ruling."))
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { ConnectionBanner() }
            .refreshable { await store.refreshDecisions() }
            .navigationTitle("Decisions")
            .toolbar { ToolbarItem(placement: .topBarLeading) { ComputerSwitcher() } }
            .navigationDestination(for: String.self) { DecisionDetailView(decisionId: $0) }
            .needsDestinations()
            .navigationDestination(item: $openBot) { BotDetailView(botId: $0) }
        }
        // Card ids anywhere in this stack open the card here (H-204).
        .opensCardLinks { path.append($0) }
        .onChange(of: openDecision, initial: true) { _, id in
            guard let id else { return }
            path = NavigationPath([id])
            openDecision = nil
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ decisions: [Decision], more: Bool = false) -> some View {
        if !decisions.isEmpty {
            Section {
                ForEach(decisions) { decision in
                    NavigationLink(value: decision.id) { DecisionRow(decision: decision) }
                }
                if more {
                    ListEnd(hasMore: true, noun: "decisions", loaded: decisions.count) {
                        store.settledLimit += Page.size
                        await store.refreshDecisions()
                    }
                }
            } header: {
                SectionTitle(title, count: more ? nil : decisions.count)
            }
        }
    }
}

private struct DecisionRow: View {
    @Environment(AppStore.self) private var store
    let decision: Decision

    private var meta: String {
        var parts = [decision.raisedByName, store.projectName(decision.projectId)]
        if let at = decision.createdAt { parts.append(at.relative) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        ItemRow(title: decision.title, subtitle: meta,
                detail: decision.tags.prefix(3).map { "#\($0)" }.joined(separator: " "), titleLines: 2) {
            AvatarView(avatar: decision.raisedByAvatar, name: decision.raisedByName, size: 36)
        } trailing: {
            if decision.urgent {
                Pill(text: "Urgent", tone: .failed)
            } else if let deadline = decision.deadlineAt, decision.pending {
                Pill(text: "Due \(deadline.relative)", tone: .needsYou)
            } else if decision.state == "answered" {
                Pill(text: "Draft", tone: .working)
            } else if decision.state == "withdrawn" {
                Pill(text: "Withdrawn")
            }
        }
    }
}
