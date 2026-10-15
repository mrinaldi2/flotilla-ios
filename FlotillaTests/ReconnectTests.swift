import XCTest
@testable import Flotilla

/// H-217: a short drop is ridden out quietly. Requests wait for a reconnect,
/// a slow Mac isn't taken for a dead link, and the owner hears only after a
/// real outage.
@MainActor
final class ReconnectTests: XCTestCase {
    func testOnlyAComingConnectionIsWaitedFor() {
        XCTAssertTrue(DaemonClient.waitsForConnection(.connecting, wanted: true))
        XCTAssertTrue(DaemonClient.waitsForConnection(.disconnected("lost"), wanted: true))
        XCTAssertFalse(DaemonClient.waitsForConnection(.connected, wanted: true))
        XCTAssertFalse(DaemonClient.waitsForConnection(.idle, wanted: true))
        XCTAssertFalse(DaemonClient.waitsForConnection(.authFailed("no"), wanted: true), "a refused token won't come back")
        XCTAssertFalse(DaemonClient.waitsForConnection(.connecting, wanted: false), "not connecting on purpose")
    }

    func testARequestDuringAReconnectWaitsBeforeFailing() async {
        let client = DaemonClient()
        client.connectWait = .milliseconds(400)
        client.setForTests(status: .connecting, wanted: true)
        let started = ContinuousClock.now
        do {
            _ = try await client.request("list_bots")
            XCTFail("no socket here, so it still fails in the end")
        } catch {
            XCTAssertEqual((error as? DaemonError)?.code, "not_connected")
        }
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(350), "it waited for the reconnect")
    }

    func testACancelledRequestStopsWaitingAtOnce() async {
        // Architect M1: leaving a screen mid-reconnect must not spin the main
        // thread until the 12 s deadline.
        let client = DaemonClient()
        client.connectWait = .seconds(5)
        client.setForTests(status: .connecting, wanted: true)
        let started = ContinuousClock.now
        let request = Task { try await client.request("list_bots") }
        try? await Task.sleep(for: .milliseconds(150))
        request.cancel()
        _ = try? await request.value
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1), "it returned soon after the cancel")
        XCTAssertEqual(client.status, .connecting, "nothing else changed")
    }

    func testARequestWhenNotConnectingFailsAtOnce() async {
        let client = DaemonClient()
        client.connectWait = .seconds(5)
        client.setForTests(status: .idle, wanted: false)
        let started = ContinuousClock.now
        _ = try? await client.request("list_bots")
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(300))
    }

    func testTheGraceTimes() {
        XCTAssertEqual(DaemonClient.probeTimeout, .seconds(10), "a slow pong isn't a dead link")
        XCTAssertEqual(DaemonClient().connectWait, .seconds(12))
        XCTAssertEqual(AppStore(defaults: ComputerDefaults(id: "test-reconnect")).troubleDelay, .seconds(8),
                       "the banner waits for a real outage")
    }

    func testEachConnectionIsCountedForScreensToReload() {
        let store = AppStore(defaults: ComputerDefaults(id: "test-reconnect-count"))
        XCTAssertEqual(store.reconnects, 0)
        store.client.setForTests(status: .connected, wanted: true)
        XCTAssertEqual(store.reconnects, 1)
        store.client.setForTests(status: .connecting, wanted: true)
        store.client.setForTests(status: .connected, wanted: true)
        XCTAssertEqual(store.reconnects, 2)
    }
}
