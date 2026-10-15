import XCTest
@testable import Flotilla

/// QA-004 on 0.17: thread previews read as plain text without the bus
/// envelope, Reports shows each message once, and the hello asks for
/// terminal requests (shown read-only).
final class OwnerTextTests: XCTestCase {
    func testAPreviewDropsMarkdownMarks() {
        XCTAssertEqual(OwnerText.preview("Done: **sync-conflicts.md** is in the `artifacts`."),
                       "Done: sync-conflicts.md is in the artifacts.")
        XCTAssertEqual(OwnerText.preview("Line one\nline two"), "Line one line two")
    }

    func testAnEnvelopeIsStripped() {
        let full = "[decision 37bce901-0c1d-4e7a-9a43-5d2f7b1c9e10 from USER · settled · re \"Let DevOps install?\" · tags release] Grant both\nRaised by Team Lead."
        XCTAssertEqual(OwnerText.preview(full), "Grant both Raised by Team Lead.")
    }

    func testAnEnvelopeCutByTheDaemonSaysWhatItIsAbout() {
        XCTAssertEqual(OwnerText.preview("[decision 37bce901-… from USER · settled · re \"Let DevOps install 0.17.1 and Desk…"),
                       "Ruling on “Let DevOps install 0.17.1 and Desk…”")
        XCTAssertEqual(OwnerText.preview("[decision 37bce901-0c1d from USER · settled"), "A ruling")
    }

    func testOrdinaryBracketsStay() {
        XCTAssertEqual(OwnerText.preview("[WIP] the board chips"), "[WIP] the board chips")
        XCTAssertEqual(OwnerText.preview("[note to self] check"), "[note to self] check")
    }

    func testReportsShowEachMessageOnce() {
        let question = ThreadEntry(id: "q", fromOwner: false, text: "Should the release notes mention the new board?",
                                   at: nil, asks: true, open: true)
        let sections = ReportSections([question])
        XCTAssertNil(sections.latest, "an open question is not also the latest report")
        XCTAssertEqual(sections.questions.map(\.id), ["q"])
        XCTAssertTrue(sections.shows("Should the release notes mention the new…"), "Doing now would repeat it")
        XCTAssertFalse(sections.shows("Building the board chips"))
    }

    func testReportsSplitLatestAndEarlier() {
        let entries = ["3", "2", "1"].map { ThreadEntry(id: $0, fromOwner: false, text: "Report \($0)", at: nil, asks: false, open: false) }
        let answered = ThreadEntry(id: "q", fromOwner: false, text: "Old question", at: nil, asks: true, open: false)
        let sections = ReportSections(entries + [answered])
        XCTAssertEqual(sections.latest?.id, "3")
        XCTAssertEqual(sections.earlier.map(\.id), ["2", "1", "q"])
        XCTAssertTrue(sections.questions.isEmpty)
    }

    func testTheHelloAsksForTerminalRequests() {
        XCTAssertTrue(DaemonClient.features.contains("terminal_card"))
        XCTAssertTrue(DaemonClient.features.contains("permission_cards"), "0.17 sends terminal requests only with permission cards")
    }
}
