import Foundation
import SwiftProtobuf

/// A protocol `error` reply, or a locally generated failure with the same shape.
struct DaemonError: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

struct Endpoint: Equatable {
    var host: String
    var port: Int
    var token: String
}

enum ConnectionStatus: Equatable {
    case idle
    case connecting
    case connected
    case disconnected(String)
    /// Sticky: retrying cannot fix a rejected or revoked token.
    case authFailed(String)
    /// Sticky: the daemon speaks a different protocol version.
    case versionMismatch(String)

    var label: String {
        switch self {
        case .idle: "Not connected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .disconnected: "Disconnected"
        case .authFailed: "Token rejected"
        case .versionMismatch: "Update needed"
        }
    }
}

/// WebSocket client for the gravityd control plane: handshake, `req_id`
/// request/reply, pushes, keepalive and reconnect with backoff.
@MainActor
final class DaemonClient {
    static let protocolVersion = 2
    static let clientId = "gravitios/\(AppInfo.version)"
    /// What this app can do for the daemon: it shows bots' permission prompts
    /// and answers them, so the daemon holds a prompt for it instead of
    /// leaving it in the bot's terminal. It shows what a decision option
    /// grants, so it may rule on one (H-118).
    /// It also takes terminal requests (T4), shown read-only (H-108).
    static let features = ["permission_cards", "decision_grants", "terminal_card"]
    /// The typed surfaces (ADR-001) and the highest version of each this app speaks.
    static let contracts = ["board": 1, "home": 1]

    private(set) var status: ConnectionStatus = .idle {
        didSet { if status != oldValue { onStatus?(status) } }
    }

    var onStatus: ((ConnectionStatus) -> Void)?
    /// How long the last ping took to come back.
    var onLatency: ((Duration) -> Void)?
    /// `hello_ok`, delivered before the status turns `connected`.
    var onHello: ((JSONDict) -> Void)?
    /// Every frame without a pending request, plus `attached` replies: those
    /// must be seen in wire order with the `term` pushes that follow them.
    var onPush: ((String, JSONDict) -> Void)?
    /// Binary pushes (`req_id` 0): typed `hermes.wire.v1.Envelope`s, e.g. `board_push`.
    var onEnvelopePush: ((Hermes_Wire_V1_Envelope) -> Void)?

    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var endpoint: Endpoint?
    private var pending: [String: CheckedContinuation<JSONDict, Error>] = [:]
    private var nextRequestId = 1
    /// Typed requests in binary frames (ADR-001), by their numeric `req_id`.
    private var pendingEnvelopes: [UInt64: CheckedContinuation<Hermes_Wire_V1_Envelope, Error>] = [:]
    private var nextEnvelopeId: UInt64 = 1
    /// Bumped on every open/stop so a stale socket's callbacks are ignored.
    private var generation = 0
    private var wantConnected = false
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?
    /// When the daemon was last heard from: any frame or pong.
    private var lastHeard = ContinuousClock.now

    /// A moving phone (cell handovers, tunnels) loses its link without the
    /// socket failing: a dead link just goes quiet. These turn quiet into a
    /// reconnect within seconds instead of the minutes TCP takes to give up.
    private static let pingInterval: Duration = .seconds(10)
    /// Silence this long, with pings going out every `pingInterval`, means the link is dead.
    private static let silenceLimit: Duration = .seconds(25)
    /// The same while a reply is awaited. Only whole messages count as heard
    /// (a WebSocket task reports no bytes until a message is complete), and a
    /// large reply on a slow link holds back everything behind it, pongs too.
    private static let busySilenceLimit: Duration = .seconds(45)
    /// How long a check of a link that may have broken waits for an answer.
    /// A loaded Mac over a relayed Tailscale path easily takes 4 s; replacing
    /// a healthy socket fails everything in flight (H-217).
    static let probeTimeout: Duration = .seconds(10)
    /// How long a request made while (re)connecting waits for the connection
    /// instead of failing at once (H-217).
    var connectWait: Duration = .seconds(12)
    /// A socket that opens but never answers the hello is given up on.
    private static let handshakeTimeout: Duration = .seconds(10)

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func start(_ endpoint: Endpoint) {
        self.endpoint = endpoint
        wantConnected = true
        reconnectAttempt = 0
        open()
    }

    func stop() {
        wantConnected = false
        teardown()
        status = .idle
    }

    /// Skip the backoff wait (the banner's Retry).
    func reconnectNow() {
        guard wantConnected else { return }
        switch status {
        case .connected, .connecting: return
        default: reconnectAttempt = 0; open()
        }
    }

    /// Back in the foreground: iOS may have closed the socket while the app
    /// was suspended without the app hearing of it.
    func appBecameActive() {
        guard wantConnected else { return }
        switch status {
        case .connected:
            // Time spent suspended is not silence: the probe decides.
            lastHeard = .now
            probe()
        case .connecting: return
        default: reconnectNow()
        }
    }

    /// The phone moved to another network (a new interface, signal back): an
    /// open socket may be stuck on the old path, and so may an attempt under
    /// way, whose retransmits back off for many seconds.
    func networkChanged() {
        guard wantConnected else { return }
        switch status {
        case .connected: probe()
        case .connecting, .disconnected: reconnectAttempt = 0; open()
        case .idle, .authFailed, .versionMismatch: return
        }
    }

    // MARK: Requests

    func request(_ type: String, _ fields: JSONDict = [:]) async throws -> JSONDict {
        await awaitConnection()
        guard status == .connected, let task else {
            throw DaemonError(code: "not_connected", message: "Not connected to the Hermes service.")
        }
        let id = newRequestId()
        var body = fields
        body["type"] = type
        body["req_id"] = id
        guard let text = JSONText.encode(body) else {
            throw DaemonError(code: "invalid_request", message: "Could not encode \(type).")
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            task.send(.string(text)) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in self?.fail(id, error) }
            }
            // Long enough for a page to crawl in over a weak mobile link.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(30))
                self?.fail(id, DaemonError(code: "timeout", message: "The Hermes service did not answer \(type)."))
            }
        }
    }

    /// A typed request in a binary frame (ADR-001): one `Envelope` out, the
    /// one under the same `req_id` back. An `Error` body throws.
    func request(_ body: Hermes_Wire_V1_Envelope.OneOf_Body, name: String) async throws -> Hermes_Wire_V1_Envelope {
        await awaitConnection()
        guard status == .connected, let task else {
            throw DaemonError(code: "not_connected", message: "Not connected to the Hermes service.")
        }
        let id = nextEnvelopeId
        nextEnvelopeId += 1
        var envelope = Hermes_Wire_V1_Envelope()
        envelope.reqID = id
        envelope.body = body
        let data: Data = try envelope.serializedData()
        return try await withCheckedThrowingContinuation { continuation in
            pendingEnvelopes[id] = continuation
            task.send(.data(data)) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in self?.failEnvelope(id, error) }
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(30))
                self?.failEnvelope(id, DaemonError(code: "timeout", message: "The Hermes service did not answer \(name)."))
            }
        }
    }

    /// Fire-and-forget frames (`input`, `resize`): the daemon sends no reply.
    func send(_ type: String, _ fields: JSONDict) {
        guard status == .connected, let task else { return }
        var body = fields
        body["type"] = type
        body["req_id"] = newRequestId()
        guard let text = JSONText.encode(body) else { return }
        task.send(.string(text)) { _ in }
    }

    // MARK: Connection

    /// A request during a reconnect waits for it (H-217): only these states
    /// are on their way back. Not connecting on purpose, or refused, fails now.
    static func waitsForConnection(_ status: ConnectionStatus, wanted: Bool) -> Bool {
        guard wanted else { return false }
        switch status {
        case .connecting, .disconnected: return true
        case .connected, .idle, .authFailed, .versionMismatch: return false
        }
    }

    /// Waits up to `connectWait` for the connection to come back. A cancelled
    /// caller (the owner left the screen) stops waiting at once: a cancelled
    /// sleep returns immediately, so `try?` would spin this loop on the main
    /// thread until the deadline (Architect M1 on H-217).
    func awaitConnection() async {
        let deadline = ContinuousClock.now + connectWait
        while Self.waitsForConnection(status, wanted: wantConnected), ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
        }
    }

    #if DEBUG
    /// Tests: a client in a given state, without a socket.
    func setForTests(status: ConnectionStatus, wanted: Bool) {
        wantConnected = wanted
        self.status = status
    }
    #endif

    private func open() {
        teardown()
        guard let endpoint else { return }
        let host = endpoint.host.contains(":") && !endpoint.host.hasPrefix("[")
            ? "[\(endpoint.host)]" : endpoint.host
        guard let url = URL(string: "ws://\(host):\(endpoint.port)/ws") else {
            status = .disconnected("Invalid host or port.")
            return
        }
        status = .connecting
        let socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 8 * 1024 * 1024
        task = socket
        let current = generation
        socket.resume()
        Task { await run(socket, generation: current, token: endpoint.token) }
        Task { [weak self] in
            try? await Task.sleep(for: Self.handshakeTimeout)
            guard let self, current == self.generation, self.status == .connecting else { return }
            // The receive loop throws and the reconnect path takes over.
            socket.cancel(with: .abnormalClosure, reason: nil)
        }
    }

    private func teardown() {
        generation += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        pingTask?.cancel()
        pingTask = nil
        probeTask?.cancel()
        probeTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        failAll(DaemonError(code: "not_connected", message: "Connection closed."))
    }

    /// The first frame. It carries this app's version and build on every
    /// connection, so the computer knows what runs here after an update
    /// (H-230; fills InstallDevice.app_version, feeds H-176). Older services ignore it.
    static func hello(token: String, requestId: String,
                      version: String = AppInfo.version, build: String = AppInfo.build) -> JSONDict {
        [
            "type": "hello", "req_id": requestId,
            "protocol_version": protocolVersion,
            "token": token, "client": clientId,
            "features": features,
            "contracts": contracts,
            "app_version": version, "app_build": build,
        ]
    }

    private func run(_ socket: URLSessionWebSocketTask, generation current: Int, token: String) async {
        do {
            let hello = Self.hello(token: token, requestId: newRequestId())
            try await socket.send(.string(JSONText.encode(hello) ?? "{}"))
            let first = try await receive(socket)
            guard current == generation else { return }
            guard first.str("type") == "hello_ok" else {
                rejectHandshake(first)
                return
            }
            reconnectAttempt = 0
            lastHeard = .now
            onHello?(first)
            status = .connected
            startPing(socket, generation: current)
            while true {
                let frame = try await socket.receive()
                guard current == generation else { return }
                lastHeard = .now
                switch frame {
                case .string(let text):
                    if let json = JSONText.decode(text) { handle(json) }
                case .data(let data):
                    handle(data)
                @unknown default:
                    continue
                }
            }
        } catch {
            guard current == generation else { return }
            failAll(DaemonError(code: "not_connected", message: "Connection lost."))
            status = .disconnected(error.localizedDescription)
            scheduleReconnect()
        }
    }

    private func rejectHandshake(_ frame: JSONDict) {
        let message = frame.str("message")
        wantConnected = false
        teardown()
        switch frame.str("code") {
        case "unsupported_version": status = .versionMismatch(message)
        default: status = .authFailed(message.isEmpty ? "The Hermes service rejected the token." : message)
        }
    }

    private func receive(_ socket: URLSessionWebSocketTask) async throws -> JSONDict {
        while true {
            let text: String
            switch try await socket.receive() {
            case .string(let value): text = value
            case .data(let data): text = String(decoding: data, as: UTF8.self)
            @unknown default: continue
            }
            if let frame = JSONText.decode(text) { return frame }
        }
    }

    private func handle(_ frame: JSONDict) {
        let type = frame.str("type")
        guard let id = frame["req_id"] as? String, let continuation = pending.removeValue(forKey: id) else {
            onPush?(type, frame)
            return
        }
        if type == "error" {
            continuation.resume(throwing: DaemonError(code: frame.str("code"), message: frame.str("message")))
            return
        }
        if type == "attached" { onPush?(type, frame) }
        continuation.resume(returning: frame)
    }

    /// A binary frame: a reply to a typed request, or a push (`req_id` 0).
    private func handle(_ data: Data) {
        guard let envelope = try? Hermes_Wire_V1_Envelope(serializedBytes: data) else { return }
        guard envelope.reqID != 0, let continuation = pendingEnvelopes.removeValue(forKey: envelope.reqID) else {
            onEnvelopePush?(envelope)
            return
        }
        if case .error(let error)? = envelope.body {
            continuation.resume(throwing: DaemonError(code: error.code, message: error.message))
        } else {
            continuation.resume(returning: envelope)
        }
    }

    private func startPing(_ socket: URLSessionWebSocketTask, generation current: Int) {
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pingInterval)
                guard let self, current == self.generation else { return }
                // A dead link never fails a ping, it only never answers one:
                // silence is the signal.
                let limit = self.pending.isEmpty && self.pendingEnvelopes.isEmpty ? Self.silenceLimit : Self.busySilenceLimit
                if ContinuousClock.now - self.lastHeard > limit {
                    self.restart()
                    return
                }
                self.ping(socket, generation: current)
            }
        }
    }

    private func ping(_ socket: URLSessionWebSocketTask, generation current: Int) {
        let sent = ContinuousClock.now
        socket.sendPing { [weak self] error in
            Task { @MainActor in
                guard let self, current == self.generation else { return }
                if error == nil {
                    self.lastHeard = .now
                    self.onLatency?(ContinuousClock.now - sent)
                } else {
                    self.restart()
                }
            }
        }
    }

    /// Checks at once that a connection which looks open still answers;
    /// one that does not is replaced.
    private func probe() {
        guard probeTask == nil, status == .connected, let socket = task else { return }
        let current = generation
        let asked = ContinuousClock.now
        ping(socket, generation: current)
        probeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.probeTimeout)
            guard !Task.isCancelled, let self, current == self.generation else { return }
            self.probeTask = nil
            // Anything at all since asking (a push, a reply, the pong) will do.
            if self.lastHeard <= asked { self.restart() }
        }
    }

    /// The link stopped answering: start over on a fresh socket now rather
    /// than wait for the stuck one to fail.
    private func restart() {
        guard wantConnected else { return }
        reconnectAttempt = 0
        open()
    }

    private func scheduleReconnect() {
        guard wantConnected else { return }
        reconnectAttempt += 1
        let delay = Self.reconnectDelay(attempt: reconnectAttempt)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.wantConnected else { return }
            self.open()
        }
    }

    /// Short waits: on the move the link is usually back within seconds, and
    /// a network change or returning to the app skips the wait anyway.
    static func reconnectDelay(attempt: Int) -> Duration {
        let steps: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4)]
        return steps.indices.contains(attempt - 1) ? steps[attempt - 1] : .seconds(5)
    }

    private func newRequestId() -> String {
        defer { nextRequestId += 1 }
        return String(nextRequestId)
    }

    private func fail(_ id: String, _ error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failAll(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: error) }
        let typed = pendingEnvelopes
        pendingEnvelopes.removeAll()
        for continuation in typed.values { continuation.resume(throwing: error) }
    }

    private func failEnvelope(_ id: UInt64, _ error: Error) {
        pendingEnvelopes.removeValue(forKey: id)?.resume(throwing: error)
    }
}
