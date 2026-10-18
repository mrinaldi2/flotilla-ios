import SwiftUI

// A project's artifacts by kind (0.22, `artifacts_v2`), from its ⋯ menu:
// Shared, Uploads and Checks, each file with the cards that use it, and
// Tidy up for the loose shared files.

/// The project's artifacts, one group at a time.
struct ProjectArtifactsScreen: View {
    @Environment(AppStore.self) private var store
    let projectId: String
    @State private var model: ArtifactsModel?
    @State private var group = ArtifactGroup.shared
    @State private var reading: ArtifactSheet?
    /// Tidy up and the cards, opened from the screen's own state (see `Pushes`).
    @State private var opened: Opened?

    enum Opened: Hashable, Identifiable {
        case tidyUp
        case card(String)
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Group", selection: $group) {
                ForEach(ArtifactGroup.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .accessibilityIdentifier("artifacts-group")
            List {
                if let model {
                    if group == .shared, model.loaded.contains(.shared), !model.loose.isEmpty {
                        Section {
                            Button { opened = .tidyUp } label: {
                                Pushes {
                                    ItemRow(title: "Tidy up", subtitle: ArtifactWords.tidyLine(model.loose.count)
                                                + (model.next[.shared] == nil ? "" : " so far")) {
                                        IconTile(systemImage: "tray.full", tone: .needsYou)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("artifacts-tidy-up")
                        }
                    }
                    let files = model.files(in: group)
                    if let failure = model.failure[group] {
                        Text(failure).font(.footnote).foregroundStyle(Color.errorText)
                    }
                    if model.loaded.contains(group), files.isEmpty, model.failure[group] == nil {
                        EmptyNote(text: "No \(group.title.lowercased()) files", systemImage: "doc")
                    }
                    if !files.isEmpty {
                        Section {
                            ForEach(files) { file in
                                ArtifactRow(file: file) { reading = ArtifactSheet(file: file) } openCard: { opened = .card($0) }
                            }
                            ListEnd(hasMore: model.next[group] != nil, noun: "files", loaded: files.count) {
                                try await model.loadMore(group)
                            }
                        } header: {
                            SectionTitle(group.title, count: files.count)
                        } footer: {
                            Text(group.footer).foregroundStyle(Color.secondaryText)
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await model?.load(group) }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Artifacts")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(group)/\(store.reconnects)") {
            if model == nil { model = ArtifactsModel(projectId: projectId, service: store) }
            await model?.load(group)
            // Tidy up is offered from Shared: read it too, whichever group opened.
            if group != .shared, !(model?.loaded.contains(.shared) ?? true) { await model?.load(.shared) }
        }
        .sheet(item: $reading) { sheet in DocumentScreen(source: .artifact(projectId: projectId, path: sheet.file.rel, name: sheet.file.name)) }
        .navigationDestination(item: $opened) { page in
            switch page {
            case .tidyUp: if let model { TidyUpScreen(model: model) }
            case .card(let id): ItemView(itemId: id, projectId: projectId)
            }
        }
    }
}

struct ArtifactSheet: Identifiable {
    let file: ArtifactFile
    var id: String { file.rel }
}

/// A file with who made it and the cards that use it, as chips.
struct ArtifactRow: View {
    let file: ArtifactFile
    let read: () -> Void
    var openCard: ((String) -> Void)? = nil

    private var meta: String {
        var parts = [file.title == nil ? file.rel : file.name, ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)]
        if let modified = file.modified { parts.append(modified.relative) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: read) {
                ItemRow(title: file.title ?? file.name, subtitle: meta, detail: file.createdBy?.label, titleLines: 2) {
                    IconTile(systemImage: ArtifactSymbol.of(file))
                } trailing: {
                    if file.kept { Pill(text: "Kept", tone: .quiet) }
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the file")
            .accessibilityIdentifier("artifact-\(file.rel)")
            if !file.usedBy.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("On cards").font(.caption).foregroundStyle(Color.secondaryText).accessibilityHidden(true)
                        ForEach(file.usedBy, id: \.self) { card in
                            Button { openCard?(card) } label: {
                                Text(card)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .frame(minHeight: 30)
                                    .background(Color(.tertiarySystemFill), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(openCard == nil)
                            .accessibilityLabel("On card \(card)")
                            .accessibilityHint("Opens the card")
                        }
                    }
                    .padding(.leading, 44)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("artifact-used-by")
            }
        }
    }
}

enum ArtifactSymbol {
    static func of(_ file: ArtifactFile) -> String {
        if file.mime.hasPrefix("image/") { return "photo" }
        if file.mime == "text/markdown" { return "doc.richtext" }
        if file.mime == "application/pdf" { return "doc.text.image" }
        if file.mime == "text/html" { return "globe" }
        if file.group == ArtifactGroup.checks.rawValue { return "checkmark.seal" }
        return "doc"
    }
}

/// Tidy up: the shared files no card uses that you haven't kept. Each one is
/// kept, attached to a card or removed (to the trash, after asking).
struct TidyUpScreen: View {
    @Environment(AppStore.self) private var store
    let model: ArtifactsModel
    @State private var reading: ArtifactSheet?
    @State private var attaching: ArtifactFile?
    @State private var removing: ArtifactFile?

    private var canChange: Bool { store.canApprove && store.status == .connected }
    private var place: String { store.computerName.isEmpty ? "the computer" : store.computerName }

    var body: some View {
        List {
            if let failure = model.actionFailure {
                Label(failure, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Color.errorText)
                    .accessibilityIdentifier("tidy-failure")
            }
            let loose = model.loose
            if loose.isEmpty, model.next[.shared] == nil {
                EmptyNote(text: "Nothing to tidy: every shared file is on a card or kept.", systemImage: "checkmark.circle")
            }
            if !loose.isEmpty || model.next[.shared] != nil {
                Section {
                    ForEach(loose) { file in row(file) }
                    ListEnd(hasMore: model.next[.shared] != nil, noun: "files", loaded: model.files(in: .shared).count) {
                        try await model.loadMore(.shared)
                    }
                } header: {
                    SectionTitle("Loose files", count: loose.count)
                } footer: {
                    Text("Nothing is removed on its own. A removed file goes to the trash on \(place).")
                        .foregroundStyle(Color.secondaryText)
                }
            }
            if !canChange {
                Text(store.status == .connected ? "This device can’t change the project’s files." : "Not connected.")
                    .font(.footnote).foregroundStyle(Color.secondaryText)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Tidy up")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load(.shared) }
        .sheet(item: $reading) { sheet in DocumentScreen(source: .artifact(projectId: model.projectId, path: sheet.file.rel, name: sheet.file.name)) }
        .sheet(item: $attaching) { file in
            AttachToCardSheet(file: file, model: model) { card in
                attaching = nil
                Task { await model.attach(file, to: card) }
            }
        }
        .confirmationDialog("Remove \(removing?.name ?? "the file")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { file in
            Button("Move to the trash", role: .destructive) { Task { await model.trash(file) } }
                .accessibilityIdentifier("tidy-remove-confirm")
        } message: { _ in
            Text("It goes to the trash on \(place), where you can still get it back.")
        }
    }

    private func row(_ file: ArtifactFile) -> some View {
        let busy = model.busy.contains(file.rel)
        return VStack(alignment: .leading, spacing: 6) {
            ArtifactRow(file: file) { reading = ArtifactSheet(file: file) }
            HStack(spacing: 8) {
                Button("Keep") { Task { await model.keep(file) } }
                    .accessibilityIdentifier("tidy-keep")
                Button("Attach to a card…") { attaching = file }
                    .accessibilityIdentifier("tidy-attach")
                Spacer(minLength: 0)
                Button("Remove…", role: .destructive) { removing = file }
                    .accessibilityIdentifier("tidy-remove")
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canChange || busy)
            .padding(.leading, 44)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tidy-\(file.rel)")
    }
}

/// Picks the card a loose file is attached to, as a document.
struct AttachToCardSheet: View {
    @Environment(\.dismiss) private var dismiss
    let file: ArtifactFile
    let model: ArtifactsModel
    let attach: (String) -> Void
    @State private var cards: [BoardCard]?
    @State private var failure: String?
    @State private var query = ""

    private var shown: [BoardCard] {
        guard let cards else { return [] }
        guard !query.isEmpty else { return cards }
        return cards.filter { $0.id.localizedCaseInsensitiveContains(query) || $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let failure { Text(failure).foregroundStyle(Color.errorText) }
                if cards == nil, failure == nil { ProgressView() }
                if cards?.isEmpty == true { EmptyNote(text: "No cards on the board", systemImage: "tray") }
                ForEach(shown, id: \.id) { card in
                    Button { attach(card.id) } label: {
                        ItemRow(title: card.title, subtitle: "\(card.id) · \(Release.PlanItem.column(card.columnKey))", titleLines: 2) {
                            IconTile(systemImage: "square.text.square")
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("attach-card-\(card.id)")
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Find a card")
            .navigationTitle("Attach \(file.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task {
                do { cards = try await model.cards() } catch { failure = error.localizedDescription }
            }
        }
    }
}
