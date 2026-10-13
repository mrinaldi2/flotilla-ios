import SwiftProtobuf
import XCTest
@testable import TheHermes

/// K8 on the phone: labels and a board's label groups from a 0.19 home, and
/// a 0.18 home's platforms read as `platform:` labels.
@MainActor
final class KanbanLabelTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("contract/fixtures/board")

    private func fixture(_ name: String) throws -> String {
        try String(contentsOf: Self.fixtures.appendingPathComponent(name), encoding: .utf8)
    }

    func testALabelsGroupIsWhatComesBeforeItsColon() {
        XCTAssertEqual(Labels.group(of: "platform:ios"), "platform")
        XCTAssertEqual(Labels.word("platform:ios"), "ios")
        XCTAssertEqual(Labels.group(of: "dashboard"), "")
        XCTAssertEqual(Labels.word("dashboard"), "dashboard")
        XCTAssertEqual(Labels.group(of: ":odd"), "", "no group name")
        XCTAssertEqual(Labels.group(of: "odd:"), "", "no value")
        XCTAssertEqual(Labels.word("was:B:12"), "B:12", "only the first colon splits")
    }

    func testThe019CardAndItemFixturesCarryPlatformsAsLabels() throws {
        let card = try BoardCard(jsonString: try fixture("card.json"))
        XCTAssertEqual(card.labels, ["dashboard", "platform:daemon", "platform:desktop"])
        XCTAssertEqual(card.allLabels, card.labels, "the deprecated platforms say the same: nothing doubles")
        let item = try Hermes_Board_V1_Item(jsonString: try fixture("item.json"))
        XCTAssertEqual(item.allLabels, ["dashboard", "platform:daemon", "platform:desktop"])
    }

    func testA018CardsPlatformsReadAsPlatformLabels() throws {
        var card = BoardCard()
        card.labels = ["dashboard"]
        card.platforms = [.ios, .infra, .unspecified]
        XCTAssertEqual(card.allLabels, ["dashboard", "platform:ios", "platform:infra"])
        let snapshot = try BoardSnapshot(jsonString: """
        {"columns": [{"key": "doing", "name": "Doing", "ord": 0, "category": "COLUMN_CATEGORY_DOING", "visible": true}],
         "cards": [
          {"id": "H-1", "title": "One", "rank": "a", "columnKey": "doing", "platforms": ["PLATFORM_IOS"]},
          {"id": "H-2", "title": "Two", "rank": "b", "columnKey": "doing", "platforms": ["PLATFORM_DESKTOP", "PLATFORM_IOS"], "labels": ["ux"]}],
         "seq": "3"}
        """)
        let state = BoardState(snapshot: snapshot)
        let groups = state.labelGroups()
        XCTAssertEqual(groups, [LabelGroupView(name: "platform", values: ["ios", "desktop"])], "a 0.18 home declares none: the cards make it")
        var filter = LabelFilter()
        filter.toggle("platform:desktop")
        XCTAssertEqual(state.cards(in: "doing", matching: filter).map(\.id), ["H-2"])
        XCTAssertEqual(BoardState.cardLabels(state.cards(in: "doing")[1], groups: groups), ["platform:ios", "platform:desktop"],
                       "in the group's order; the plain label stays in the item screen")
    }

    func testTheSettingsFixtureKeysMachinesByLabel() throws {
        let settings = try Hermes_Board_V1_BoardSettings(jsonString: try fixture("settings.json"))
        XCTAssertEqual(settings.requiredMachinesByLabel["platform:desktop"]?.values, ["mac", "win-pc"])
        XCTAssertEqual(settings.requiredMachines["desktop"]?.values, ["mac", "win-pc"], "still filled for 0.18 readers")
    }

    private func board(_ id: String, groups: [(String, [String])]) -> KanbanBoard {
        var board = KanbanBoard()
        board.id = id
        board.name = id
        board.labelGroups = groups.map { name, values in
            var group = LabelGroup()
            group.name = name
            group.values = values
            return group
        }
        return board
    }

    func testTheBarOffersTheBoardsGroupsThenSmallOnesItsCardsUse() {
        let declared = board("b", groups: [("platform", ["ios", "android"]), ("area", [])]).labelGroups
        let wasTags = (1...9).map { ["was:B\($0)"] }
        let groups = Labels.groups(declared: declared,
                                   cardLabels: [["platform:web", "dashboard"], ["course:main", "course:dessert"], ["area:import"]] + wasTags)
        XCTAssertEqual(groups.map(\.name), ["platform", "area", "course"], "an import's nine `was:` tags are no filter")
        XCTAssertEqual(groups[0].values, ["ios", "android", "web"], "the board's values first, then those its cards use")
        XCTAssertEqual(groups[1].values, ["import"])
        XCTAssertEqual(groups[2].values, ["main", "dessert"])
        XCTAssertEqual(groups[2].label("main"), "course:main")
        let big = Labels.groups(declared: board("b", groups: [("was", [])]).labelGroups, cardLabels: wasTags)
        XCTAssertEqual(big.first?.values.count, 9, "a group the board declares shows all its values")
    }

    func testAFilterWantsOneLabelPerGroupAndEveryGroup() {
        var filter = LabelFilter()
        XCTAssertTrue(filter.matches([]), "no filter: every card")
        filter.toggle("platform:ios")
        filter.toggle("platform:android")
        XCTAssertTrue(filter.matches(["platform:android"]), "any within a group")
        filter.toggle("area:import")
        XCTAssertFalse(filter.matches(["platform:android"]), "every group picked from")
        XCTAssertTrue(filter.matches(["platform:ios", "area:import", "x"]))
        filter.toggle("platform:ios")
        XCTAssertEqual(filter.picked, ["platform:android", "area:import"])
        filter.keep(only: [LabelGroupView(name: "platform", values: ["android"])])
        XCTAssertEqual(filter.picked, ["platform:android"], "another board: what it doesn't offer goes")
        filter.clear()
        XCTAssertFalse(filter.isOn)
    }

    func testABoardsGroupsAndTheChipCounts() throws {
        var snapshot = try KanbanLogicTests.snapshot019()
        snapshot.boards = snapshot.boards.map { b in
            b.id == "b-main" ? { var m = b; m.labelGroups = board("x", groups: [("platform", ["ios", "desktop"])]).labelGroups; return m }() : b
        }
        snapshot.cards[0].labels = ["platform:ios"]
        snapshot.cards[1].labels = ["topic:flour"]
        let state = BoardState(snapshot: snapshot)
        XCTAssertEqual(state.labelGroups().map(\.name), ["platform"], "the board on screen: Main")
        XCTAssertEqual(state.labelGroups(for: "b-research").map(\.name), ["topic"], "another board's, for quick add")
        var filter = LabelFilter()
        filter.toggle("platform:desktop")
        let doing = try XCTUnwrap(state.columns.first { $0.key == "doing" })
        let shown = state.cards(in: "doing", matching: filter).count
        XCTAssertEqual(doing.chip(shown: shown, of: state.cards(in: "doing").count, filtering: filter.isOn), "Doing 0 of 1")
        XCTAssertEqual(doing.chip(shown: 1, of: 1, filtering: false), "Doing 1/3", "unfiltered: the WIP limit as before")
    }
}
