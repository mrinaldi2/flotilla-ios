import Foundation
import Observation

// Artifacts by kind (0.22.0, capability `artifacts_v2`): a project's shared
// files, grouped as Shared, Uploads and Checks, each with the cards that use
// it, and a tidy-up list of loose shared files (no card uses them, not kept)
// for the owner to keep, attach to a card or remove. Nothing is removed on
// its own; a removed file goes to the trash.

/// The groups `list_artifacts {group}` takes, in the list's order.
enum ArtifactGroup: String, CaseIterable, Identifiable {
    case shared, uploads, checks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shared: "Shared"
        case .uploads: "Uploads"
        case .checks: "Checks"
        }
    }

    /// What the group holds, said under its list.
    var footer: String {
        switch self {
        case .shared: "Files the project’s bots share: references, datasets, builds. Work for one card is attached to that card."
        case .uploads: "Files you sent from the app."
        case .checks: "Logs of the project’s checks."
        }
    }
}

/// The artifact requests, behind a protocol so the models run in tests without a daemon.
@MainActor
protocol ArtifactService: AnyObject {
    func listArtifacts(projectId: String, group: String?, before: String?) async throws -> ArtifactPage
    /// Marks a file kept, or takes the mark off (`artifact_keep`); the file as now listed, when the daemon sends it.
    func keepArtifact(projectId: String, path: String, keep: Bool) async throws -> ArtifactFile?
    /// Moves a file to the trash (`artifact_trash`); refused while a live card uses it.
    func trashArtifact(projectId: String, path: String) async throws
    /// Attaches a file to a card as a document (`item_attach {artifact}`).
    func attachArtifact(itemId: String, path: String) async throws
    /// The cards a file can be attached to: the project's live ones.
    func attachableCards(projectId: String) async throws -> [BoardCard]
}

extension AppStore: ArtifactService {
    func keepArtifact(projectId: String, path: String, keep: Bool) async throws -> ArtifactFile? {
        let reply = try await client.request("artifact_keep", ["project_id": projectId, "path": path, "keep": keep])
        return reply.dict("artifact").map(ArtifactFile.init)
    }

    func trashArtifact(projectId: String, path: String) async throws {
        _ = try await client.request("artifact_trash", ["project_id": projectId, "path": path])
    }

    func attachArtifact(itemId: String, path: String) async throws {
        var attach = Flotilla_Board_V1_ItemAttach()
        attach.id = itemId
        attach.artifact = path
        _ = try await self.attach(attach)
    }

    func attachableCards(projectId: String) async throws -> [BoardCard] {
        let snapshot = try await board(projectId: projectId)
        return snapshot.cards.filter { !$0.draft }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
}

enum ArtifactWords {
    /// "On SP-12, SP-14", the cards that use a file.
    static func usedBy(_ file: ArtifactFile) -> String? {
        guard !file.usedBy.isEmpty else { return nil }
        let shown = file.usedBy.prefix(3).joined(separator: ", ")
        return file.usedBy.count > 3 ? "On \(shown) +\(file.usedBy.count - 3)" : "On \(shown)"
    }

    /// "12 loose files no card uses."
    static func tidyLine(_ count: Int) -> String {
        count == 1 ? "1 loose file no card uses" : "\(count) loose files no card uses"
    }

    /// Why a removal was refused: the daemon names the cards still using it.
    static func trashRefused(_ file: ArtifactFile, _ error: Error) -> String {
        if let error = error as? DaemonError, error.code == "conflict" {
            return error.message.isEmpty ? "\(file.name) is still on a card. Take it off the card first." : error.message
        }
        return "Couldn’t remove \(file.name). \(error.localizedDescription)"
    }
}

/// The project's artifacts on screen: each group a page at a time, and the
/// tidy-up list made from the Shared group.
@MainActor @Observable
final class ArtifactsModel {
    let projectId: String
    private(set) var files: [ArtifactGroup: [ArtifactFile]] = [:]
    /// Each group's next page, while it has more.
    private(set) var next: [ArtifactGroup: String] = [:]
    private(set) var loaded: Set<ArtifactGroup> = []
    private(set) var failure: [ArtifactGroup: String] = [:]
    /// Why the last keep, attach or removal didn't go through.
    var actionFailure: String?
    /// The files being changed, by path.
    private(set) var busy: Set<String> = []

    @ObservationIgnored private let service: ArtifactService

    init(projectId: String, service: ArtifactService) {
        self.projectId = projectId
        self.service = service
    }

    func files(in group: ArtifactGroup) -> [ArtifactFile] { files[group] ?? [] }

    /// Loose shared files: no card uses them and the owner hasn't kept them.
    var loose: [ArtifactFile] { Self.loose(files(in: .shared)) }

    static func loose(_ files: [ArtifactFile]) -> [ArtifactFile] {
        files.filter { $0.usedBy.isEmpty && !$0.kept && ($0.group.isEmpty || $0.group == ArtifactGroup.shared.rawValue) }
    }

    /// A group's first page, replacing what is shown.
    func load(_ group: ArtifactGroup) async {
        do {
            let page = try await service.listArtifacts(projectId: projectId, group: group.rawValue, before: nil)
            files[group] = page.files
            next[group] = page.hasMore ? page.nextBefore : nil
            failure[group] = nil
        } catch {
            failure[group] = error.localizedDescription
        }
        loaded.insert(group)
    }

    func loadMore(_ group: ArtifactGroup) async throws {
        guard let before = next[group] else { return }
        let page = try await service.listArtifacts(projectId: projectId, group: group.rawValue, before: before)
        files[group] = ArtifactPage.merge(files(in: group), page.files)
        next[group] = page.hasMore ? page.nextBefore : nil
    }

    private func replace(_ file: ArtifactFile) {
        for group in ArtifactGroup.allCases {
            if let index = files[group]?.firstIndex(where: { $0.rel == file.rel }) { files[group]?[index] = file }
        }
    }

    private func remove(_ rel: String) {
        for group in ArtifactGroup.allCases { files[group]?.removeAll { $0.rel == rel } }
    }

    private func act(_ file: ArtifactFile, _ action: () async throws -> Void, failed: (Error) -> String) async -> Bool {
        busy.insert(file.rel)
        actionFailure = nil
        defer { busy.remove(file.rel) }
        do {
            try await action()
            return true
        } catch {
            actionFailure = failed(error)
            return false
        }
    }

    /// Keeps a loose file: it stays in Shared, off the tidy-up list.
    @discardableResult
    func keep(_ file: ArtifactFile, _ keep: Bool = true) async -> Bool {
        await act(file, {
            if let now = try await service.keepArtifact(projectId: projectId, path: file.rel, keep: keep) {
                replace(now)
            } else {
                await load(.shared)
            }
        }, failed: { "Couldn’t keep \(file.name). \($0.localizedDescription)" })
    }

    /// Attaches a file to a card: the card uses it now, so it leaves the tidy-up list.
    @discardableResult
    func attach(_ file: ArtifactFile, to itemId: String) async -> Bool {
        await act(file, {
            try await service.attachArtifact(itemId: itemId, path: file.rel)
            await load(.shared)
        }, failed: { "Couldn’t attach \(file.name) to \(itemId). \($0.localizedDescription)" })
    }

    /// Moves a file to the trash, once the owner confirmed.
    @discardableResult
    func trash(_ file: ArtifactFile) async -> Bool {
        await act(file, {
            try await service.trashArtifact(projectId: projectId, path: file.rel)
            remove(file.rel)
        }, failed: { ArtifactWords.trashRefused(file, $0) })
    }

    func cards() async throws -> [BoardCard] { try await service.attachableCards(projectId: projectId) }
}

/// A card's one Documents list (0.22): its attachments, then its artifact
/// links as documents, each file once.
enum CardDocuments {
    /// A doc the daemon lists for an artifact link has an id starting `link:`.
    static func isLink(_ attachment: ItemAttachment) -> Bool { attachment.id.hasPrefix("link:") }

    /// Attachments first, then links; a link to a file already attached as a doc is left out.
    static func merged(_ attachments: [ItemAttachment]) -> [ItemAttachment] {
        var seen: Set<String> = []
        var out: [ItemAttachment] = []
        for attachment in attachments.filter({ !isLink($0) }) + attachments.filter(isLink) {
            if attachment.kind == "doc", !attachment.path.isEmpty, !attachment.removed {
                guard seen.insert(attachment.path).inserted else { continue }
            }
            out.append(attachment)
        }
        return out
    }
}
