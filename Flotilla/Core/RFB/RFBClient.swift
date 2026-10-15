import CoreGraphics
import Foundation
import Network

/// A VNC (RFB 3.8) client for macOS Screen Sharing: signs in, keeps a
/// framebuffer current and sends pointer, key and clipboard events.
/// Reading and decoding run off the main actor; callbacks come back on it.
final class RFBClient: @unchecked Sendable {
    enum State: Equatable {
        case connecting
        case signingIn
        case connected(name: String, width: Int, height: Int)
        case failed(String)
        case closed
    }

    /// How the connection is doing, for the timing readout.
    struct Stats: Equatable {
        var signIn: TimeInterval = 0
        var firstPicture: TimeInterval?
        var bytes = 0
        var encodings: Set<Int32> = []
    }

    struct Credentials {
        var username: String
        var password: String
    }

    var onState: (@MainActor (State) -> Void)?
    var onImage: (@MainActor (CGImage) -> Void)?
    var onClipboard: (@MainActor (String) -> Void)?
    var onStats: (@MainActor (Stats) -> Void)?

    private let connection: NWConnection
    private let credentials: Credentials
    private let queue = DispatchQueue(label: "thehermes.rfb")
    private var buffer: [UInt8] = []
    private var bufferOffset = 0
    private var task: Task<Void, Never>?
    private var framebuffer = Framebuffer(width: 1, height: 1)
    private var inflater: Inflater?
    private let pixelBytes: Int
    private var stats = Stats()
    private var started = Date()

    // Shared with the main actor: which part of the screen to keep current,
    // and whether anyone is looking.
    private let lock = NSLock()
    private var _region: CGRect?
    private var _paused = false
    private var waitingForUpdate = false
    /// Set once the pixel format and encodings are sent; asking for pictures
    /// before that would get them in the Mac's own format.
    private var ready = false
    private var lastRequest = Date.distantPast
    private var lastPublish = Date.distantPast
    /// The framebuffer changed since the last picture handed to the phone.
    private var unpublished = false

    /// How often to ask the Mac for changes. macOS drops a request when
    /// nothing has changed at that moment instead of holding it, so asking
    /// once and waiting would freeze the picture.
    private static let pollInterval: TimeInterval = 0.07
    /// At most this often a new picture is copied out for the phone; the
    /// newest one always wins, so nothing queues up behind the screen.
    private static let publishInterval: TimeInterval = 0.04

    // Encodings, in the order the Mac should prefer them.
    private static let encodings: [Int32] = [16, 5, 1, 0, -223]  // ZRLE, Hextile, CopyRect, Raw, DesktopSize

    init(host: String, port: Int, credentials: Credentials, fastColours: Bool = false) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 20
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port)) ?? 5900,
                                  using: NWParameters(tls: nil, tcp: tcp))
        self.credentials = credentials
        pixelBytes = fastColours ? 2 : 4
    }

    // MARK: What to keep current (any thread)

    /// Only this part of the screen is asked for and pictured; nil means all.
    /// Changing it shows what the client already has, then refreshes it.
    func setRegion(_ region: CGRect?) {
        lock.lock()
        let changed = _region != region
        _region = region
        let paused = _paused, ready = self.ready
        lock.unlock()
        guard changed, !paused, ready else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.publish()
            self.requestUpdate(incremental: false)
        }
    }

    /// While paused nothing new is asked for, so the Mac sends nothing; the
    /// connection stays signed in for when the screen is looked at again.
    func setPaused(_ paused: Bool) {
        lock.lock()
        let wasPaused = _paused
        _paused = paused
        let ready = self.ready
        lock.unlock()
        guard wasPaused, !paused, ready else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.publish()
            self.requestUpdate(incremental: true)
        }
    }

    private var region: CGRect? { lock.lock(); defer { lock.unlock() }; return _region }
    private var paused: Bool { lock.lock(); defer { lock.unlock() }; return _paused }

    func start() {
        task = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        task?.cancel()
        connection.cancel()
    }

    // MARK: Session

    private func run() async {
        do {
            await report(.connecting)
            try await waitUntilReady()
            started = Date()
            try await handshake()
            stats.signIn = Date().timeIntervalSince(started)
            try await sendFormatAndEncodings()
            lock.lock(); ready = true; lock.unlock()
            requestUpdate(incremental: false)
            let ticker = Task.detached(priority: .userInitiated) { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(35))
                    self?.tick()
                }
            }
            defer { ticker.cancel() }
            try await messageLoop()
        } catch is CancellationError {
            await report(.closed)
        } catch {
            connection.cancel()
            await report(.failed(error.localizedDescription))
        }
    }

    private func report(_ state: State) async {
        await MainActor.run { [onState] in onState?(state) }
    }

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // State updates arrive on `queue` only, one at a time.
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            connection.stateUpdateHandler = { state in
                guard !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    continuation.resume()
                case .failed(let error), .waiting(let error):
                    once.done = true
                    continuation.resume(throwing: RFBError.protocolError(
                        "Couldn’t reach the screen-sharing server. Is it turned on?\n\(error.localizedDescription)"))
                case .cancelled:
                    once.done = true
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func handshake() async throws {
        let version = String(decoding: try await read(12), as: UTF8.self)
        guard version.hasPrefix("RFB ") else { throw RFBError.protocolError("That port is not a screen-sharing server.") }
        let minor = Int(version.dropFirst(8).prefix(3)) ?? 3
        let modern = minor >= 7
        send(Array((modern ? "RFB 003.008\n" : "RFB 003.003\n").utf8))

        await report(.signingIn)
        var type: UInt8
        if modern {
            let count = Int(try await u8())
            if count == 0 { throw RFBError.auth(try await reason()) }
            let offered = try await read(count)
            if offered.contains(30), !credentials.username.isEmpty {
                type = 30
            } else if offered.contains(2) {
                type = 2
            } else if offered.contains(1) {
                type = 1
            } else if offered.contains(30) {
                throw RFBError.auth("Enter the Mac's user name and password in Settings.")
            } else {
                throw RFBError.auth("The Mac asked for a sign-in method Hermes does not support (\(offered)).")
            }
            send([type])
        } else {
            type = UInt8(truncatingIfNeeded: try await u32())
            if type == 0 { throw RFBError.auth(try await reason()) }
        }

        switch type {
        case 30:
            let generator = try await read(2)
            let length = Int(try await u16())
            let prime = try await read(length)
            let serverKey = try await read(length)
            send(try RFBCrypto.appleResponse(generator: generator, prime: prime, serverKey: serverKey,
                                             username: credentials.username, password: credentials.password))
        case 2:
            let challenge = try await read(16)
            send(try RFBCrypto.vncResponse(challenge: challenge, password: credentials.password))
        default:
            break
        }
        if modern || type != 1 {
            if try await u32() != 0 {
                let why = modern ? (try? await reason()) : nil
                throw RFBError.auth(why.flatMap { $0.isEmpty ? nil : "The Mac refused the sign-in: \($0)" }
                                    ?? "The Mac refused the user name or password.")
            }
        }

        send([1])  // ClientInit: share the session with anyone else watching
        let width = Int(try await u16())
        let height = Int(try await u16())
        _ = try await read(16)  // the server's pixel format; ours replaces it
        let name = String(decoding: try await read(Int(try await u32())), as: UTF8.self)
        framebuffer = Framebuffer(width: width, height: height)
        await report(.connected(name: name, width: width, height: height))
    }

    private func sendFormatAndEncodings() async throws {
        send([0, 0, 0, 0] + (pixelBytes == 2 ? PixelFormat.fast : PixelFormat.full))
        var message: [UInt8] = [2, 0] + be16(Self.encodings.count)
        for encoding in Self.encodings { message += be32(UInt32(bitPattern: encoding)) }
        send(message)
    }

    private func messageLoop() async throws {
        while !Task.isCancelled {
            switch try await u8() {
            case 0:
                try await framebufferUpdate()
                lock.lock(); waitingForUpdate = false; unpublished = true; lock.unlock()
                if stats.firstPicture == nil {
                    stats.firstPicture = Date().timeIntervalSince(started)
                    let snapshot = stats
                    await MainActor.run { [onStats] in onStats?(snapshot) }
                }
                if !paused {
                    publishIfDue()
                    requestUpdate(incremental: true)
                }
            case 1:
                _ = try await read(3)
                let count = Int(try await u16())
                _ = try await read(count * 6)
            case 2:
                break  // bell
            case 3:
                _ = try await read(3)
                let text = String(decoding: try await read(Int(try await u32())), as: UTF8.self)
                await MainActor.run { [onClipboard] in onClipboard?(text) }
            case let other:
                throw RFBError.protocolError("The Mac sent a message Hermes does not understand (\(other)).")
            }
        }
    }

    private func framebufferUpdate() async throws {
        _ = try await u8()
        let count = Int(try await u16())
        for _ in 0..<count {
            let x = Int(try await u16()), y = Int(try await u16())
            let w = Int(try await u16()), h = Int(try await u16())
            let encoding = Int32(bitPattern: try await u32())
            stats.encodings.insert(encoding)
            switch encoding {
            case 0:
                let bytes = try await read(w * h * pixelBytes)
                let size = pixelBytes
                bytes.withUnsafeBufferPointer { raw in
                    framebuffer.withRect(x: x, y: y, w: w, h: h) { out in
                        for i in Swift.stride(from: 0, to: raw.count, by: size) {
                            out.put(PixelFormat.pixel(raw, at: i, size: size))
                        }
                    }
                }
            case 1:
                let sx = Int(try await u16()), sy = Int(try await u16())
                framebuffer.copy(fromX: sx, fromY: sy, toX: x, toY: y, w: w, h: h)
            case 5:
                try await hextile(x: x, y: y, w: w, h: h)
            case 16:
                let length = Int(try await u32())
                let compressed = try await read(length)
                if inflater == nil { inflater = try Inflater() }
                try ZRLE.decode(try inflater!.inflate(compressed), x: x, y: y, w: w, h: h,
                                pixelBytes: pixelBytes == 2 ? 2 : 3, into: framebuffer)
            case -223:
                framebuffer.resize(width: w, height: h)
            default:
                throw RFBError.protocolError("The Mac used a screen encoding Hermes does not support (\(encoding)).")
            }
        }
    }

    private func hextile(x: Int, y: Int, w: Int, h: Int) async throws {
        var background: UInt32 = 0, foreground: UInt32 = 0
        for ty in Swift.stride(from: y, to: y + h, by: 16) {
            let th = min(16, y + h - ty)
            for tx in Swift.stride(from: x, to: x + w, by: 16) {
                let tw = min(16, x + w - tx)
                let flags = try await u8()
                if flags & 1 != 0 {
                    let bytes = try await read(tw * th * pixelBytes)
                    let size = pixelBytes
                    bytes.withUnsafeBufferPointer { raw in
                        framebuffer.withRect(x: tx, y: ty, w: tw, h: th) { out in
                            for i in Swift.stride(from: 0, to: raw.count, by: size) {
                                out.put(PixelFormat.pixel(raw, at: i, size: size))
                            }
                        }
                    }
                    continue
                }
                if flags & 2 != 0 { background = try await pixel() }
                framebuffer.fill(x: tx, y: ty, w: tw, h: th, color: background)
                if flags & 4 != 0 { foreground = try await pixel() }
                guard flags & 8 != 0 else { continue }
                let subrects = Int(try await u8())
                for _ in 0..<subrects {
                    let color = flags & 16 != 0 ? try await pixel() : foreground
                    let position = try await u8(), size = try await u8()
                    framebuffer.fill(x: tx + Int(position >> 4), y: ty + Int(position & 15),
                                     w: Int(size >> 4) + 1, h: Int(size & 15) + 1, color: color)
                }
            }
        }
    }

    // MARK: Input (any thread)

    func pointer(x: Int, y: Int, buttons: UInt8) {
        send([5, buttons] + be16(max(0, x)) + be16(max(0, y)))
    }

    func key(_ keysym: UInt32, down: Bool) {
        send([4, down ? 1 : 0, 0, 0] + be32(keysym))
    }

    /// The Mac's clipboard is Latin-1 in RFB; other characters are dropped.
    func sendClipboard(_ text: String) {
        let bytes = text.unicodeScalars.compactMap { $0.value < 256 ? UInt8($0.value) : nil }
        send([6, 0, 0, 0] + be32(UInt32(bytes.count)) + bytes)
    }

    /// Runs every few milliseconds: keeps asking for changes and hands over
    /// any picture that was held back.
    private func tick() {
        lock.lock()
        let active = ready && !_paused
        let due = Date().timeIntervalSince(lastRequest) >= Self.pollInterval
        lock.unlock()
        guard active else { return }
        if due { requestUpdate(incremental: true, force: true) }
        publishIfDue()
    }

    private func publishIfDue() {
        lock.lock()
        let due = unpublished && Date().timeIntervalSince(lastPublish) >= Self.publishInterval
        if due {
            unpublished = false
            lastPublish = Date()
        }
        lock.unlock()
        if due { publish() }
    }

    /// Asks for the region in view. `force` sends even with a request
    /// already out, since the Mac may have dropped it.
    private func requestUpdate(incremental: Bool, force: Bool = false) {
        lock.lock()
        let busy = incremental && waitingForUpdate && !force
        waitingForUpdate = true
        if !busy { lastRequest = Date() }
        lock.unlock()
        if busy { return }
        let whole = CGRect(x: 0, y: 0, width: framebuffer.width, height: framebuffer.height)
        let area = (region ?? whole).intersection(whole).integral
        guard area.width >= 1, area.height >= 1 else { return }
        send([3, incremental ? 1 : 0] + be16(Int(area.minX)) + be16(Int(area.minY))
             + be16(Int(area.width)) + be16(Int(area.height)))
    }

    /// Hands the main actor a picture of the region in view.
    private func publish() {
        guard let image = framebuffer.image(of: region) else { return }
        Task { @MainActor [onImage] in onImage?(image) }
    }

    // MARK: Wire

    private func send(_ bytes: [UInt8]) {
        connection.send(content: Data(bytes), completion: .idempotent)
    }

    /// Reads exactly `count` bytes, refilling from the socket in large chunks
    /// so that byte-at-a-time parsing stays cheap.
    private func read(_ count: Int) async throws -> [UInt8] {
        while buffer.count - bufferOffset < count {
            if bufferOffset > 0 {
                buffer.removeFirst(bufferOffset)
                bufferOffset = 0
            }
            let chunk = try await receive(atLeast: count - buffer.count)
            stats.bytes += chunk.count
            buffer.append(contentsOf: chunk)
        }
        let out = Array(buffer[bufferOffset..<bufferOffset + count])
        bufferOffset += count
        return out
    }

    private func receive(atLeast minimum: Int) async throws -> [UInt8] {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max(minimum, 1 << 20)) { data, _, complete, error in
                if let error {
                    continuation.resume(throwing: RFBError.protocolError(error.localizedDescription))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: [UInt8](data))
                } else if complete {
                    continuation.resume(throwing: RFBError.closed)
                } else {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    // Small reads come straight from the buffer when the bytes are there,
    // without allocating: Hextile reads a few bytes at a time.

    private var available: Int { buffer.count - bufferOffset }

    private func u8() async throws -> UInt8 {
        if available >= 1 {
            defer { bufferOffset += 1 }
            return buffer[bufferOffset]
        }
        return try await read(1)[0]
    }

    private func u16() async throws -> UInt16 {
        if available < 2 { return try await read(2).withUnsafeBufferPointer { UInt16($0[0]) << 8 | UInt16($0[1]) } }
        defer { bufferOffset += 2 }
        return UInt16(buffer[bufferOffset]) << 8 | UInt16(buffer[bufferOffset + 1])
    }

    private func u32() async throws -> UInt32 {
        if available < 4 {
            let b = try await read(4)
            return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
        }
        defer { bufferOffset += 4 }
        let i = bufferOffset
        return UInt32(buffer[i]) << 24 | UInt32(buffer[i + 1]) << 16 | UInt32(buffer[i + 2]) << 8 | UInt32(buffer[i + 3])
    }

    private func pixel() async throws -> UInt32 {
        if available >= pixelBytes {
            defer { bufferOffset += pixelBytes }
            return buffer.withUnsafeBufferPointer { PixelFormat.pixel($0, at: bufferOffset, size: pixelBytes) }
        }
        let b = try await read(pixelBytes)
        return b.withUnsafeBufferPointer { PixelFormat.pixel($0, at: 0, size: pixelBytes) }
    }

    private func reason() async throws -> String {
        String(decoding: try await read(Int(try await u32())), as: UTF8.self)
    }

    private func be16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
    private func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }
}
