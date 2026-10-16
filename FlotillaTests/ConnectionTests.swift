import XCTest
@testable import Flotilla

/// Staying usable on a link that drops for a moment (a phone in a car).
@MainActor
final class ConnectionTests: XCTestCase {
    private func store() -> AppStore {
        let store = AppStore(defaults: ComputerDefaults(id: "test-connection"))
        store.troubleDelay = .milliseconds(100)
        return store
    }

    func testRetriesSoonAndNeverWaitLong() {
        let delays = (1...8).map(DaemonClient.reconnectDelay(attempt:))
        XCTAssertEqual(delays.first, .milliseconds(500))
        XCTAssertEqual(delays, delays.sorted())
        XCTAssertEqual(delays.max(), .seconds(5))
    }

    func testAShortDropShowsNoBanner() async throws {
        let store = store()
        store.client.onStatus?(.connected)
        store.client.onStatus?(.disconnected("Connection lost."))
        store.client.onStatus?(.connecting)
        XCTAssertFalse(store.connectionTrouble)
        store.client.onStatus?(.connected)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(store.connectionTrouble)
    }

    func testADropThatLastsIsShownUntilConnected() async throws {
        let store = store()
        store.client.onStatus?(.disconnected("Connection lost."))
        try await Task.sleep(for: .milliseconds(60))
        // Retries flip between these; the wait keeps counting from the drop.
        store.client.onStatus?(.connecting)
        store.client.onStatus?(.disconnected("Connection lost."))
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertTrue(store.connectionTrouble)
        store.client.onStatus?(.connecting)
        XCTAssertTrue(store.connectionTrouble)
        store.client.onStatus?(.connected)
        XCTAssertFalse(store.connectionTrouble)
    }

    func testARejectedTokenShowsAtOnce() {
        let store = store()
        store.client.onStatus?(.authFailed("The daemon rejected the token."))
        XCTAssertTrue(store.connectionTrouble)
    }
}
