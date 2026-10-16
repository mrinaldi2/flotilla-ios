import XCTest
@testable import Flotilla

/// Creating a project from the phone (0.20, BG-Rules §7): the templates,
/// what each step checks before Next, and how a clone's end is waited for.
@MainActor
final class ProjectSetupTests: XCTestCase {
    // MARK: Templates

    /// The keys are the daemon's (kanban/presets.rs): a listed key keeps its column's rules.
    func testTemplatesAreTheDaemonsPresets() {
        XCTAssertEqual(BoardTemplate.simpleReview.columns.compactMap(\.key), ["todo", "doing", "review", "done"])
        XCTAssertEqual(BoardTemplate.simple.columns.compactMap(\.key), ["todo", "doing", "done"])
        XCTAssertEqual(BoardTemplate.releaseGated.columns.compactMap(\.key),
                       ["inbox", "ready", "doing", "review", "verify", "approval", "deploying", "done"])
        XCTAssertTrue(BoardTemplate.releaseGated.renameOnly)
        XCTAssertFalse(BoardTemplate.simpleReview.renameOnly)
        XCTAssertEqual(BoardTemplate.allCases.first, .simpleReview, "the recommended one first")
    }

    func testChoosingATemplateResetsItsColumns() {
        var plan = ProjectPlan()
        plan.columns[0].name = "Backlog"
        plan.columnsEdited = true
        plan.choose(.releaseGated)
        XCTAssertEqual(plan.columns.count, 8)
        XCTAssertFalse(plan.columnsEdited)
        plan.choose(.releaseGated)
        XCTAssertEqual(plan.columns.first?.name, "Inbox")
    }

    func testThePreviewBarHasASegmentPerColumnUpToFive() {
        XCTAssertEqual(TemplatePreview.segments(BoardTemplate.simpleReview.columns).map(\.name), ["To do", "Doing", "Review", "Done"])
        XCTAssertEqual(TemplatePreview.segments(BoardTemplate.simpleReview.columns)[2].shade, .review)
        XCTAssertEqual(TemplatePreview.segments(BoardTemplate.releaseGated.columns).count, MiniBoard.maxSegments)
    }

    // MARK: Checks

    func testANameMustBeNewIgnoringCase() {
        XCTAssertEqual(PlanCheck.name("  ", taken: []), "Give the project a name.")
        XCTAssertEqual(PlanCheck.name("thesis writing", taken: ["Thesis writing"]), "You already have a project called thesis writing.")
        XCTAssertNil(PlanCheck.name("Thesis", taken: ["Thesis writing"]))
        XCTAssertEqual(PlanCheck.freeName("Thesis writing", taken: ["Thesis writing", "thesis writing 2"]), "Thesis writing 3")
    }

    func testCustomColumnsNeedNewWorkAndDone() {
        var columns = BoardTemplate.simple.columns
        XCTAssertNil(PlanCheck.columns(columns, template: .simple))
        columns.removeAll { $0.kind == .done }
        XCTAssertEqual(PlanCheck.columns(columns, template: .simple), "Keep at least one Done column.")
        columns = BoardTemplate.simple.columns.filter { $0.kind != .open }
        XCTAssertEqual(PlanCheck.columns(columns, template: .simple), "Keep at least one column for new work.")
        columns = BoardTemplate.simple.columns
        columns[1].name = "to do"
        XCTAssertEqual(PlanCheck.columns(columns, template: .simple), "Two columns are named to do.")
        columns[1].name = " "
        XCTAssertEqual(PlanCheck.columns(columns, template: .simple), "Every column needs a name.")
    }

    func testARepositoryClonesOverHttpsIntoAFolder() {
        var plan = ProjectPlan()
        XCTAssertNil(PlanCheck.repository(plan), "optional")
        plan.repoURL = "github.com/me/thesis"
        XCTAssertEqual(plan.cloneURL, "https://github.com/me/thesis")
        XCTAssertEqual(PlanCheck.repository(plan), "Pick a folder to clone it into.")
        plan.folder = ProjectPlan.suggestedFolder(for: plan.repoURL)
        XCTAssertEqual(plan.folder, "~/Developer/thesis")
        XCTAssertNil(PlanCheck.repository(plan))
        plan.repoURL = "git@github.com:me/thesis.git"
        XCTAssertNotNil(PlanCheck.repository(plan), "no SSH keys")
        plan.repoURL = "https://github.com/me/thesis.git"
        plan.folder = "Developer/thesis"
        XCTAssertEqual(PlanCheck.repository(plan), "Give the folder as ~/… or a full path.")
        XCTAssertEqual(ProjectPlan.suggestedFolder(for: "https://github.com/me/thesis.git"), "~/Developer/thesis")
    }

    func testTheLeadIsNamedAfterTheProject() {
        XCTAssertEqual(ProjectPlan.suggestedLead(for: "thesis writing"), "Thesis Lead")
        XCTAssertEqual(ProjectPlan.suggestedLead(for: ""), "Lead")
        XCTAssertEqual(PlanCheck.lead(" "), "Give the lead a name.")
    }

    func testADescriptionIsAtMostTwoKilobytes() {
        XCTAssertNil(PlanCheck.description(String(repeating: "a", count: 2048)))
        XCTAssertNotNil(PlanCheck.description(String(repeating: "a", count: 2049)))
    }

    // MARK: Creating

    func testACreationWithoutARepositorySkipsTheClone() {
        var plan = ProjectPlan()
        plan.name = "Thesis"
        plan.leadName = "Thesis Lead"
        let creation = ProjectCreation(plan: plan, computerId: "mac")
        XCTAssertEqual(creation.steps, [.board, .lead, .reading])
        XCTAssertEqual(creation.label(.lead), "Starting Thesis Lead")
        XCTAssertFalse(creation.finished)
        XCTAssertFalse(creation.projectExists)
        plan.repoURL = "github.com/me/thesis"
        XCTAssertEqual(ProjectCreation(plan: plan, computerId: "mac").steps, [.board, .clone, .lead, .reading])
    }

    func testACloneThatEndedBeforeAnyoneWaitedIsNotLost() async {
        let store = AppStore(defaults: ComputerDefaults(id: "test-clone-early"))
        store.cloneUpdated(RepoClone(["project_id": "p", "state": "failed", "error": "No such branch."]))
        let clone = await store.cloneFinished(projectId: "p")
        XCTAssertEqual(clone.state, .failed)
        XCTAssertEqual(clone.error, "No such branch.")
    }

    func testAWaitingCloneEndsOnItsPush() async {
        let store = AppStore(defaults: ComputerDefaults(id: "test-clone-push"))
        store.cloneUpdated(RepoClone(["project_id": "p", "state": "cloning"]))
        async let finished = store.cloneFinished(projectId: "p")
        try? await Task.sleep(for: .milliseconds(20))
        store.cloneUpdated(RepoClone(["project_id": "p", "state": "done", "path": "/Users/me/app"]))
        let clone = await finished
        XCTAssertEqual(clone.state, .done)
        XCTAssertEqual(clone.path, "/Users/me/app")
    }
}
