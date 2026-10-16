import SwiftUI
import XCTest
@testable import Flotilla

/// H-214: every view hosted on its own (a context-menu preview, a popover, a
/// sheet) renders with only what it is given. A missing environment object is
/// a crash, so each case here would crash the test run if it regressed.
@MainActor
final class IsolationRenderTests: XCTestCase {
    private func render<V: View>(_ view: V, file: StaticString = #filePath, line: UInt = #line) {
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        host.view.layoutIfNeeded()
        let size = host.sizeThatFits(in: CGSize(width: 390, height: 700))
        XCTAssertGreaterThan(size.height, 0, file: file, line: line)
    }

    func testTheCardPreviewRendersAsAContextMenuPreview() {
        // The 18:51 and 19:10 crashes: the preview hosted without Fleet.
        render(CardPreviewView.hosted(id: "HL-004", fleet: Fleet()))
    }

    func testTheReplySheetRendersOnItsOwn() {
        render(ReplySheet(to: "Desktop Dev", quote: "Should the notes mention the board?") { _ in })
    }

    func testTheReleaseSheetsRenderOnTheirOwn() {
        let release = Release(["id": "r", "name": "x", "display_version": "0.17.0", "status": "awaiting_owner",
                               "items": [["item_id": "H-1", "verdict": "pending"]], "plan": []])
        render(LeaveOutSheet(itemId: "H-1", title: "Board chips") { _ in })
        render(HoldReleaseSheet(version: "0.17.0") { _, _ in })
        render(RejectReleaseSheet(release: release) { _, _ in })
    }

    /// Board glance (0.20): the Projects tab and a card's pieces, at the default
    /// size and at an accessibility size, where the bar becomes rows (case 7).
    func testTheProjectsTabAndItsCardsRenderOnTheirOwn() {
        var row = HomeRow()
        row.projectID = "p"
        row.name = "PhD"
        row.bots = 3
        row.botsWorking = 1
        row.attention.count = 2
        row.columns = [("To do", "inbox", 9), ("Doing", "doing", 3), ("Review", "review", 0), ("Done", "done", 21)].map { name, category, count in
            var column = HomeColumn()
            column.name = name
            column.category = category
            column.count = UInt32(count)
            return column
        }
        row.staleSources = ["d-imac"]
        let card = HomeCard(row: row, computerId: "mac", staleNames: ["imac"], staleSince: Date(), offline: ["d-imac"])
        var ask = HomeAttentionRow()
        ask.kind = .ownerQuestion
        ask.title = "Which split for the evaluation?"
        let bots = [GlanceBot(id: "b", name: "ML Engineer", avatar: "", working: true)]
        for size in [DynamicTypeSize.large, .accessibility3] {
            render(ProjectCardBody(card: card, bots: bots).environment(\.dynamicTypeSize, size))
            render(AskRow(row: ask, action: "Answer", primary: true).environment(\.dynamicTypeSize, size))
            render(AskRow(row: ask, action: "Answer", unavailable: "Not connected to Mac").environment(\.dynamicTypeSize, size))
        }
        render(QuietRow(card: card))
        render(MiniBoardRows(segments: MiniBoard.segments(row.columns)))
        render(FilterChips(filter: .constant(.needsYou), counts: [.all: 7, .needsYou: 1]))
        render(NewProjectButton(prominent: true).environment(Fleet()))
        render(ProjectsHomeView().environment(Fleet()))
    }

    func testTheBotPickerRendersWithTheFleetItDeclares() {
        render(BotPicker { _ in }.environment(Fleet()))
    }
}
