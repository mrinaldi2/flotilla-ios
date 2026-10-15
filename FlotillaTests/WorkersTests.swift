import XCTest
@testable import Flotilla

/// Temporary workers, the shared repository and worker bots, against frames
/// shaped as Gravity's docs/protocol.md describes them.
final class WorkersTests: XCTestCase {
    private func worker(_ state: String, position: Int? = nil, machine: String? = nil, id: String = "w") -> Worker {
        var row: JSONDict = ["id": id, "project_id": "p", "name": "ch-\(id)", "state": state,
                             "parent_bot_id": "lead", "brief": "Write a chapter.", "created_at": "2026-10-02T09:00:00Z"]
        if let position { row["queue_position"] = position }
        if let machine { row["machine"] = machine }
        return Worker(row)
    }

    func testDecodesAWorkerWithEveryField() {
        let parsed = Worker([
            "id": "w1", "project_id": "p1", "name": "ch-3", "state": "running", "queue_position": 2,
            "machine": "win-pc", "parent_bot_id": "b1", "parent_name": "Tech Writer",
            "brief": "Write chapter 3.", "task_id": "t1", "note": "waiting for a free worker slot", "bot_id": "b9",
            "created_at": "2026-10-02T09:00:00Z", "started_at": "2026-10-02T09:01:00Z",
            "finished_at": "2026-10-02T09:30:00Z",
        ])
        XCTAssertEqual(parsed.id, "w1")
        XCTAssertEqual(parsed.projectId, "p1")
        XCTAssertEqual(parsed.queuePosition, 2)
        XCTAssertEqual(parsed.machine, "win-pc")
        XCTAssertEqual(parsed.parentBotId, "b1")
        XCTAssertEqual(parsed.parentName, "Tech Writer")
        XCTAssertEqual(parsed.taskId, "t1")
        XCTAssertEqual(parsed.note, "waiting for a free worker slot")
        XCTAssertEqual(parsed.botId, "b9")
        XCTAssertNotNil(parsed.startedAt)
        XCTAssertEqual(parsed.when, parsed.finishedAt, "the latest of finished, started, created")
    }

    func testDecodesAWorkerWithoutItsOptionalFields() {
        let parsed = worker("queued")
        XCTAssertNil(parsed.queuePosition)
        XCTAssertNil(parsed.machine)
        XCTAssertNil(parsed.parentName)
        XCTAssertNil(parsed.taskId)
        XCTAssertNil(parsed.note)
        XCTAssertNil(parsed.botId)
        XCTAssertNil(parsed.startedAt)
        XCTAssertNil(parsed.finishedAt)
        XCTAssertEqual(parsed.when, parsed.createdAt)
        XCTAssertTrue(parsed.isActive)
    }

    func testDecodesAListing() {
        let listing = WorkerListing(["project_id": "p", "running_here": 3, "max_workers_here": 4,
                                     "workers": [["id": "a", "state": "running"], ["id": "b", "state": "queued"]]])
        XCTAssertEqual(listing.runningHere, 3)
        XCTAssertEqual(listing.maxHere, 4)
        XCTAssertEqual(listing.workers.map(\.id), ["a", "b"])
    }

    func testChipWording() {
        XCTAssertEqual(worker("queued", position: 2).chip, "#2 in queue")
        XCTAssertEqual(worker("queued").chip, "Queued")
        XCTAssertEqual(worker("running").chip, "Running")
        XCTAssertEqual(worker("running", machine: "here").chip, "Running")
        XCTAssertEqual(worker("running", machine: "win-pc").chip, "Running on win-pc")
        for state in ["done", "cancelled", "expired", "failed"] {
            XCTAssertEqual(worker(state).chip, state.prefix(1).uppercased() + state.dropFirst())
            XCTAssertFalse(worker(state).isActive, "\(state) cannot be cancelled")
        }
    }

    func testSectionsKeepTheDaemonsOrder() {
        let workers = [worker("queued", position: 1, id: "q1"), worker("running", id: "r1"),
                       worker("queued", position: 2, id: "q2"), worker("done", id: "d1"),
                       worker("running", id: "r2"), worker("failed", id: "f1"), worker("cancelled", id: "c1")]
        let sections = Worker.sections(workers)
        XCTAssertEqual(sections.running.map(\.id), ["r1", "r2"])
        XCTAssertEqual(sections.queued.map(\.id), ["q1", "q2"])
        XCTAssertEqual(sections.finished.map(\.id), ["d1", "f1", "c1"])
        XCTAssertTrue(Worker.sections([]).running.isEmpty)
    }

    func testBotTemporaryDefaultsToFalse() {
        XCTAssertTrue(Bot(["id": "b", "temporary": true]).temporary)
        XCTAssertFalse(Bot(["id": "b", "temporary": false]).temporary)
        XCTAssertFalse(Bot(["id": "b"]).temporary, "older daemons leave it out")
    }

    func testProjectRepoPresentNullOrAbsent() {
        let present = Project(["id": "p", "name": "Notes", "repo": ["url": "git@example.com:notes.git", "branch": "dev"]])
        XCTAssertEqual(present.repo, ProjectRepo(url: "git@example.com:notes.git", branch: "dev"))
        XCTAssertNil(Project(["id": "p", "name": "Notes", "repo": NSNull()]).repo, "null means none")
        XCTAssertNil(Project(["id": "p", "name": "Notes"]).repo, "absent means none")
        XCTAssertEqual(Project(["id": "p", "name": "Notes", "repo": ["url": "/srv/notes.git"]]).repo?.branch, "main")
    }
}
