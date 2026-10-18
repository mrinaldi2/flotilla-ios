import XCTest
@testable import Flotilla

/// A daemon that serves artifacts by kind: answers from what the test set, records what was asked.
@MainActor
final class FakeArtifacts: ArtifactService {
    var groups: [String: [ArtifactFile]] = [:]
    var kept: ArtifactFile?
    var trashError: Error?
    var cardList: [BoardCard] = []
    private(set) var listed: [String?] = []
    private(set) var keeps: [(String, Bool)] = []
    private(set) var trashed: [String] = []
    private(set) var attached: [(String, String)] = []

    func listArtifacts(projectId: String, group: String?, before: String?) async throws -> ArtifactPage {
        listed.append(group)
        return ArtifactPage(files: groups[group ?? ""] ?? [], hasMore: false, nextBefore: nil)
    }

    func keepArtifact(projectId: String, path: String, keep: Bool) async throws -> ArtifactFile? {
        keeps.append((path, keep))
        return kept
    }

    func trashArtifact(projectId: String, path: String) async throws {
        if let trashError { throw trashError }
        trashed.append(path)
    }

    func attachArtifact(itemId: String, path: String) async throws { attached.append((itemId, path)) }
    func attachableCards(projectId: String) async throws -> [BoardCard] { cardList }
}

/// 0.22 step 5 on the phone: artifacts grouped as the daemon lists them,
/// the tidy-up list and its three answers, and a card's one Documents list.
@MainActor
final class ArtifactsTests: XCTestCase {
    private func file(_ rel: String, group: String = "shared", usedBy: [String] = [], kept: Bool = false) -> ArtifactFile {
        ArtifactFile(["path": "/p/artifacts/\(rel)", "rel": rel, "name": (rel as NSString).lastPathComponent, "size": 10,
                      "mime": "text/markdown", "group": group, "used_by": usedBy, "kept": kept])
    }

    func testAListedFileCarriesItsGroupItsCardsAndKept() {
        let row: JSONDict = ["path": "/x/artifacts/refs/saints.csv", "rel": "refs/saints.csv", "name": "saints.csv", "size": 2048,
                             "mime": "text/csv", "group": "shared", "used_by": ["ASL-4", "ASL-7"], "kept": true]
        let f = ArtifactFile(row)
        XCTAssertEqual(f.group, "shared")
        XCTAssertEqual(f.usedBy, ["ASL-4", "ASL-7"])
        XCTAssertTrue(f.kept)
        XCTAssertEqual(ArtifactWords.usedBy(f), "On ASL-4, ASL-7")
        // An older daemon sends none of them.
        let old = ArtifactFile(["path": "/x/a.md", "name": "a.md"])
        XCTAssertEqual(old.group, "")
        XCTAssertEqual(old.usedBy, [])
        XCTAssertFalse(old.kept)
        XCTAssertNil(ArtifactWords.usedBy(old))
        XCTAssertEqual(ArtifactWords.usedBy(file("a", usedBy: ["A-1", "A-2", "A-3", "A-4", "A-5"])), "On A-1, A-2, A-3 +2")
    }

    func testTidyUpListsSharedFilesNoCardUsesAndNotKept() {
        let loose = ArtifactsModel.loose([file("loose.md"), file("used.md", usedBy: ["A-1"]), file("kept.md", kept: true),
                                          file("up.png", group: "uploads")])
        XCTAssertEqual(loose.map(\.rel), ["loose.md"])
        XCTAssertEqual(ArtifactWords.tidyLine(1), "1 loose file no card uses")
        XCTAssertEqual(ArtifactWords.tidyLine(3), "3 loose files no card uses")
    }

    func testEachGroupIsAskedForByName() async {
        let fake = FakeArtifacts()
        fake.groups = ["shared": [file("a.md")], "checks": [file("checks/x.log", group: "checks")]]
        let model = ArtifactsModel(projectId: "p1", service: fake)
        await model.load(.shared)
        await model.load(.checks)
        XCTAssertEqual(fake.listed, ["shared", "checks"])
        XCTAssertEqual(model.files(in: .checks).map(\.rel), ["checks/x.log"])
        XCTAssertEqual(model.loose.map(\.rel), ["a.md"])
    }

    func testKeepAttachAndRemoveTakeAFileOffTheTidyUpList() async {
        let fake = FakeArtifacts()
        fake.groups = ["shared": [file("a.md"), file("b.md"), file("c.md")]]
        let model = ArtifactsModel(projectId: "p1", service: fake)
        await model.load(.shared)
        XCTAssertEqual(model.loose.count, 3)

        fake.kept = file("a.md", kept: true)
        let r1 = await model.keep(model.loose[0])
        XCTAssertTrue(r1)
        XCTAssertEqual(fake.keeps.map(\.0), ["a.md"])
        XCTAssertEqual(fake.keeps.map(\.1), [true])
        XCTAssertEqual(model.loose.map(\.rel), ["b.md", "c.md"])

        // Attached, the file is read again: the card uses it now.
        fake.groups = ["shared": [file("a.md", kept: true), file("b.md", usedBy: ["ASL-4"]), file("c.md")]]
        let r2 = await model.attach(model.loose[0], to: "ASL-4")
        XCTAssertTrue(r2)
        XCTAssertEqual(fake.attached.map(\.0), ["ASL-4"])
        XCTAssertEqual(fake.attached.map(\.1), ["b.md"])
        XCTAssertEqual(model.loose.map(\.rel), ["c.md"])

        let r3 = await model.trash(model.loose[0])
        XCTAssertTrue(r3)
        XCTAssertEqual(fake.trashed, ["c.md"])
        XCTAssertTrue(model.loose.isEmpty)
        XCTAssertFalse(model.files(in: .shared).contains { $0.rel == "c.md" })
    }

    func testARemovalRefusedForALiveCardSaysWhyAndKeepsTheFile() async {
        let fake = FakeArtifacts()
        fake.groups = ["shared": [file("a.md")]]
        fake.trashError = DaemonError(code: "conflict", message: "a.md is on ASL-4. Take it off the card first.")
        let model = ArtifactsModel(projectId: "p1", service: fake)
        await model.load(.shared)
        let r4 = await model.trash(model.loose[0])
        XCTAssertFalse(r4)
        XCTAssertEqual(model.actionFailure, "a.md is on ASL-4. Take it off the card first.")
        XCTAssertEqual(model.loose.map(\.rel), ["a.md"])
    }

    func testACardHasOneDocumentsListWithEachFileOnce() {
        func attachment(_ id: String, kind: String = "doc", path: String = "", name: String = "") -> ItemAttachment {
            var a = ItemAttachment()
            a.id = id
            a.kind = kind
            a.path = path
            a.name = name
            return a
        }
        let link = attachment("link:refs/saints.csv", path: "refs/saints.csv")
        let attached = attachment("att-1", path: "refs/saints.csv")
        let image = attachment("att-2", kind: "image", name: "shot.png")
        let other = attachment("link:notes/plan.md", path: "notes/plan.md")
        let merged = CardDocuments.merged([link, image, attached, other])
        XCTAssertEqual(merged.map(\.id), ["att-2", "att-1", "link:notes/plan.md"])
        XCTAssertTrue(CardDocuments.isLink(other))
        XCTAssertFalse(CardDocuments.isLink(attached))
    }
}
