import XCTest
@testable import Flotilla

/// Who made each artifact (`created_by` in `list_artifacts`), and what a
/// command row offers to copy.
final class FileCreatorTests: XCTestCase {
    private func creator(_ via: String, name: String = "lead", machine: String? = nil, botId: String? = "b1") -> FileCreator {
        var row: JSONDict = ["name": name, "avatar": "icon:orbit", "via": via]
        if let botId { row["bot_id"] = botId }
        if let machine { row["machine"] = machine }
        return FileCreator(row)
    }

    func testLabelsByHowTheFileWasMade() {
        XCTAssertEqual(creator("wrote").label, "written by lead")
        XCTAssertEqual(creator("edited").label, "first edited by lead")
        XCTAssertEqual(creator("command").label, "made by a command of lead")
        XCTAssertEqual(creator("upload", name: "you", botId: nil).label, "uploaded by you")
        XCTAssertEqual(creator("sent", name: "windev", machine: "win-pc").label, "sent by windev @ win-pc")
    }

    func testMachineIsAppendedWheneverSet() {
        XCTAssertEqual(creator("wrote", name: "windev", machine: "win-pc").label, "written by windev @ win-pc")
        XCTAssertEqual(creator("command", name: "windev", machine: "win-pc").label,
                       "made by a command of windev @ win-pc")
        XCTAssertEqual(creator("sent", name: "windev").label, "sent by windev", "no machine, no suffix")
    }

    func testAnUnknownWayStillNamesTheBot() {
        XCTAssertEqual(creator("copied").label, "made by lead")
    }

    func testDecodesWithEveryField() {
        let file = ArtifactFile([
            "path": "/p/artifacts/build.ps1", "rel": "build.ps1", "name": "build.ps1", "size": 120, "mime": "text/x-code",
            "created_by": ["bot_id": "b9", "name": "windev", "avatar": "icon:volt", "machine": "win-pc", "via": "sent"],
        ])
        let creator = try! XCTUnwrap(file.createdBy)
        XCTAssertEqual(creator.botId, "b9")
        XCTAssertEqual(creator.name, "windev")
        XCTAssertEqual(creator.avatar, "icon:volt")
        XCTAssertEqual(creator.machine, "win-pc")
        XCTAssertEqual(creator.via, "sent")
        XCTAssertFalse(creator.isOwner)
    }

    func testDecodesWithoutTheOptionalFields() {
        let file = ArtifactFile([
            "path": "/p/artifacts/notes.md", "name": "notes.md", "size": 10, "mime": "text/markdown",
            "created_by": ["name": "you", "avatar": "", "via": "upload"],
        ])
        let creator = try! XCTUnwrap(file.createdBy)
        XCTAssertNil(creator.botId)
        XCTAssertNil(creator.machine)
        XCTAssertTrue(creator.isOwner, "no bot_id: the owner, shown without an avatar")
        XCTAssertEqual(creator.label, "uploaded by you")
    }

    func testOlderDaemonsSendNoCreator() {
        let file = ArtifactFile(["path": "/p/artifacts/old.md", "name": "old.md", "size": 1, "mime": "text/markdown"])
        XCTAssertNil(file.createdBy)
    }
}

final class CommandCopyTests: XCTestCase {
    private func command(output: String?) -> BotCommand {
        var row: JSONDict = ["id": "c1", "command": "npm test\n--watch=false", "background": false,
                             "status": "done", "started_at": "2026-10-02T09:00:00Z"]
        if let output { row["output"] = output }
        return BotCommand(row)
    }

    func testOnlyAnOutputWithTextOffersCopy() {
        XCTAssertNil(command(output: nil).copyableOutput)
        XCTAssertNil(command(output: "").copyableOutput)
        XCTAssertNil(command(output: "  \n").copyableOutput)
        XCTAssertEqual(command(output: "ok\n").copyableOutput, "ok\n", "copied exactly, newline and all")
    }

    func testTheWholeCommandIsKept() {
        XCTAssertEqual(command(output: nil).command, "npm test\n--watch=false")
    }
}
