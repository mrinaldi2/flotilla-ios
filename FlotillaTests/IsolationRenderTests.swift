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

    func testTheBotPickerRendersWithTheFleetItDeclares() {
        render(BotPicker { _ in }.environment(Fleet()))
    }
}
