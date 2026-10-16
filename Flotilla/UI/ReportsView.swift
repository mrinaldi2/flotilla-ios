import SwiftUI

/// The Files tab: the reports the bots write for each other and for you,
/// newest first, and the files on the computer itself.
struct ReportsView: View {
    @Environment(AppStore.self) private var store
    @Environment(LensStore.self) private var lens
    @State private var mode = Mode.reports
    @State private var query = ""
    @State private var count = Page.size

    enum Mode: String, CaseIterable {
        case reports = "Artifacts"
        case computer = "On this computer"
    }

    private var matching: [LensArtifact] {
        guard !query.isEmpty else { return lens.artifacts }
        return lens.artifacts.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    /// The newest reports; searching looks through all of them.
    private var shown: [LensArtifact] { Array(matching.prefix(count)) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ConnectionBanner()
                Picker("Show", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0 == .computer ? "Files on \(store.computerName)" : $0.rawValue) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                switch mode {
                case .reports: reports
                case .computer: FolderView(path: "")
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Files")
            .toolbar { ToolbarItem(placement: .topBarLeading) { ComputerSwitcher() } }
            .navigationDestination(for: LensArtifact.self) { ReportView(artifact: $0) }
            .navigationDestination(for: FolderLink.self) { FolderView(path: $0.path) }
        }
    }

    private var reports: some View {
        List {
            if !shown.isEmpty {
                Section {
                    ForEach(shown) { artifact in
                        NavigationLink(value: artifact) {
                            ItemRow(title: artifact.title, subtitle: meta(artifact), titleLines: 2) {
                                IconTile(systemImage: "doc.richtext")
                            }
                        }
                    }
                    ListEnd(hasMore: matching.count > count || !lens.artifactCursors.isEmpty, noun: "artifacts", loaded: shown.count) {
                        if matching.count <= count { await lens.loadMoreArtifacts() }
                        count += Page.size
                    }
                } header: {
                    SectionTitle(query.isEmpty ? "Newest" : "Found")
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay { if lens.artifacts.isEmpty { LensEmptyState() } }
        .searchable(text: $query, prompt: "Search artifacts")
        .refreshable { await lens.loadArtifacts() }
        .task(id: store.projects.count) { await lens.loadArtifacts() }
    }

    private func meta(_ artifact: LensArtifact) -> String {
        // From the daemon, artifacts name their project by id.
        var parts = [store.projects.first { $0.id == artifact.project }?.name ?? artifact.project]
        if let modified = artifact.modified { parts.append(modified.relative) }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(artifact.size), countStyle: .file))
        return parts.joined(separator: " · ")
    }
}

struct ReportView: View {
    @Environment(LensStore.self) private var lens
    let artifact: LensArtifact
    @State private var text: String?
    @State private var error: String?

    var body: some View {
        ScrollView {
            Group {
                if let text {
                    if artifact.name.hasSuffix(".md") || artifact.name.hasSuffix(".markdown") {
                        MarkdownText(text, report: (artifact.project, artifact.name))
                    } else {
                        Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    }
                } else if let error {
                    Text(error).foregroundStyle(Color.secondaryText)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(artifact.title == artifact.name ? "Artifact" : artifact.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if let text {
                ShareLink(item: text, subject: Text(artifact.title)) { Image(systemName: "square.and.arrow.up") }
            }
        }
        .task {
            do { text = try await lens.artifact(project: artifact.project, name: artifact.name) } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
