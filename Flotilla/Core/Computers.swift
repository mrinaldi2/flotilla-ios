import Foundation
import Network
import Observation

/// What a computer runs: it decides the screen's keys and how it is named.
enum ComputerKind: String, Codable, CaseIterable {
    case mac
    case windows

    var label: String {
        switch self {
        case .mac: "Mac"
        case .windows: "Windows"
        }
    }

    var symbol: String {
        switch self {
        case .mac: "laptopcomputer"
        case .windows: "pc"
        }
    }
}

/// One computer running Gravity, as saved on the phone. Its token and screen
/// password are in the Keychain under its id.
struct ComputerRecord: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var kind: ComputerKind
    /// The daemon.
    var host: String
    var port: Int
    /// Gravity Lens; an empty host means the daemon's.
    var lensHost: String
    var lensPort: Int
    /// The screen (VNC); an empty host means the daemon's.
    var screenHost: String
    var screenPort: Int
    /// Empty on Windows, whose VNC servers ask for a password only.
    var screenUser: String

    init(id: String = UUID().uuidString, name: String, kind: ComputerKind, host: String, port: Int = 49777,
         lensHost: String = "", lensPort: Int = LensStore.defaultPort,
         screenHost: String = "", screenPort: Int = 5900, screenUser: String = "") {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port
        self.lensHost = lensHost
        self.lensPort = lensPort
        self.screenHost = screenHost
        self.screenPort = screenPort
        self.screenUser = screenUser
    }

    // Lenient, so a field added later does not lose the saved computers.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = (try? c.decode(ComputerKind.self, forKey: .kind)) ?? .mac
        host = try c.decode(String.self, forKey: .host)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 49777
        lensHost = try c.decodeIfPresent(String.self, forKey: .lensHost) ?? ""
        lensPort = try c.decodeIfPresent(Int.self, forKey: .lensPort) ?? LensStore.defaultPort
        screenHost = try c.decodeIfPresent(String.self, forKey: .screenHost) ?? ""
        screenPort = try c.decodeIfPresent(Int.self, forKey: .screenPort) ?? 5900
        screenUser = try c.decodeIfPresent(String.self, forKey: .screenUser) ?? ""
    }
}

/// UserDefaults keys that belong to one computer.
struct ComputerDefaults {
    let id: String
    func key(_ name: String) -> String { "computer.\(id).\(name)" }
}

/// One computer, live: its daemon connection, its Gravity Lens and its screen.
@MainActor
@Observable
final class Computer: Identifiable {
    let id: String
    private(set) var record: ComputerRecord
    let store: AppStore
    let lens: LensStore
    /// Outlives the screen tab, so coming back needs no new sign-in.
    let screen: ScreenSession

    var name: String { record.name }
    var kind: ComputerKind { record.kind }

    static func tokenAccount(_ id: String) -> String { "device-token.\(id)" }
    static func screenPasswordAccount(_ id: String) -> String { "screen-password.\(id)" }

    init(_ record: ComputerRecord, token: String?) {
        id = record.id
        self.record = record
        store = AppStore(defaults: ComputerDefaults(id: record.id))
        lens = LensStore(app: store)
        screen = ScreenSession(defaults: ComputerDefaults(id: record.id))
        apply()
        if let token { store.connect(Endpoint(host: record.host, port: record.port, token: token)) }
    }

    var screenSettings: ScreenSettings {
        ScreenSettings(host: record.screenHost.isEmpty ? record.host : record.screenHost,
                       port: record.screenPort, username: record.screenUser,
                       passwordAccount: Self.screenPasswordAccount(id))
    }

    func update(_ new: ComputerRecord) {
        let old = record
        record = new
        apply()
        if (new.host, new.port) != (old.host, old.port), let endpoint = store.endpoint {
            store.connect(Endpoint(host: new.host, port: new.port, token: endpoint.token))
        }
        if (new.screenHost, new.screenPort, new.screenUser) != (old.screenHost, old.screenPort, old.screenUser) {
            screen.disconnect()
        }
    }

    func setToken(_ token: String, save: Bool = true) {
        if save { saveToken(token) }
        store.connect(Endpoint(host: record.host, port: record.port, token: token))
    }

    /// Keeps the token without reconnecting: for a computer already connected.
    func saveToken(_ token: String) {
        Keychain.save(token, account: Self.tokenAccount(id), afterFirstUnlock: true)
    }

    func setScreenPassword(_ password: String) {
        Keychain.save(password, account: Self.screenPasswordAccount(id))
        screen.disconnect()
    }

    /// Disconnects and deletes everything kept for this computer.
    func forget() {
        store.disconnect()
        screen.disconnect()
        Keychain.delete(account: Self.tokenAccount(id))
        Keychain.delete(account: Self.screenPasswordAccount(id))
        let prefix = ComputerDefaults(id: id).key("")
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func apply() {
        store.computerName = record.name
        store.kind = record.kind
        lens.host = record.lensHost.isEmpty ? record.host : record.lensHost
        lens.port = record.lensPort
    }
}

/// Every computer the phone knows, all connected at once, and the one on screen.
@MainActor
@Observable
final class Fleet {
    private(set) var computers: [Computer] = []
    /// The projects home and Needs you, across every computer.
    let home = HomeFeed()
    /// Card ids this phone knows, and their previews (H-204).
    let cards = CardDirectory()
    /// A card to open, from a link that came from outside the app. Kept until
    /// the projects say where it lives: on a cold start they load after the link
    /// arrives (H-216).
    var openCard: String? {
        didSet { if openCard != openingCard { openingCard = nil } }
    }
    /// A card link from outside whose id no project uses, to say so.
    var missingCard: String?
    /// "Opening ZZ-404…": the link has waited a while for the projects (UX-044).
    private(set) var openingCard: String?
    /// A release approval waiting out its Undo, and how it ended (H-160 AC4).
    let rulings = RulingQueue()
    private(set) var selectedId: String?
    /// Launched with test arguments: nothing is saved.
    @ObservationIgnored private var ephemeral = false
    @ObservationIgnored private let network = NWPathMonitor()
    @ObservationIgnored private var lastPath: NWPath?

    /// The card `openCard` asks for, taken once its project is known; an id no
    /// project uses is dropped into `missingCard`. Nil while the projects load.
    func takeOpenCard() -> (id: String, home: CardDirectory.Home)? {
        guard let id = openCard else { return nil }
        switch cards.resolve(id) {
        case .found(let home):
            openCard = nil
            return (id, home)
        case .unknown:
            openCard = nil
            missingCard = id
            return nil
        case .waiting:
            return nil
        }
    }

    /// A waiting link never hangs (UX-044): "Opening…" after `showAfter`, and
    /// after `giveUpAfter` it is dropped and said, as an unknown id is.
    func watchOpenCard(showAfter: Duration = .seconds(3), giveUpAfter: Duration = .seconds(15)) async {
        guard let id = openCard else { return }
        do {
            try await Task.sleep(for: showAfter)
            guard openCard == id else { return }
            openingCard = id
            try await Task.sleep(for: giveUpAfter - showAfter)
        } catch { return }
        guard openCard == id else { return }
        openCard = nil
        missingCard = id
    }

    private static let recordsKey = "computers"
    private static let selectedKey = "selectedComputer"

    var selected: Computer? { computers.first { $0.id == selectedId } ?? computers.first }

    init() {
        watchNetwork()
        #if DEBUG
        let debug = Self.debugComputers()
        if !debug.isEmpty {
            ephemeral = true
            for (record, token) in debug { attach(Computer(record, token: token)) }
            selectedId = UserDefaults.standard.string(forKey: Self.selectedKey)
            return
        }
        #endif
        var records = Self.loadRecords()
        if records.isEmpty, let legacy = Self.migrateLegacy() {
            records = [legacy]
            Self.save(records)
        }
        for record in records {
            attach(Computer(record, token: Keychain.load(account: Computer.tokenAccount(record.id))))
        }
        selectedId = UserDefaults.standard.string(forKey: Self.selectedKey)
    }

    // MARK: Changes

    @discardableResult
    func add(_ record: ComputerRecord, token: String) -> Computer {
        let computer = Computer(record, token: nil)
        computer.setToken(token, save: !ephemeral)
        attach(computer)
        save()
        select(computer)
        return computer
    }

    /// Keeps a computer that was connected on its own first, as pairing does
    /// to check the address and token before anything is saved.
    func adopt(_ computer: Computer, token: String) {
        if !ephemeral { computer.saveToken(token) }
        attach(computer)
        save()
        select(computer)
    }

    func update(_ computer: Computer, _ record: ComputerRecord) {
        computer.update(record)
        save()
        retag()
    }

    func remove(_ computer: Computer) {
        computer.forget()
        home.forget(computer.id)
        computers.removeAll { $0.id == computer.id }
        if selectedId == computer.id { selectedId = computers.first?.id }
        save()
        retag()
        updateBadge()
    }

    func select(_ computer: Computer) {
        selectedId = computer.id
        if !ephemeral { UserDefaults.standard.set(computer.id, forKey: Self.selectedKey) }
    }

    // MARK: Connecting daemons

    /// `computer`'s peer row for `other`, if the two are paired: by daemon id
    /// when the daemons report it, else by the name the phone gave it.
    func peer(of computer: Computer, for other: Computer) -> Peer? {
        computer.store.peers.first { peer in
            guard peer.isActive else { return false }
            if let id = peer.daemonId, let otherId = other.store.daemonId { return id == otherId }
            return peer.name == other.name
        }
    }

    /// Pairs two of the phone's computers: `listener` makes an invite, and
    /// `dialer` adds it and keeps the link open. Each names the other as the
    /// phone does.
    func connect(_ dialer: Computer, to listener: Computer) async throws {
        let invite: String
        do {
            invite = try await listener.store.createPeerInvite(name: dialer.name)
        } catch {
            // The daemon offers no address of its own (it lists only localhost
            // under bind): the dialer is pointed where this phone reaches it.
            let host = listener.record.host.contains(":") ? "[\(listener.record.host)]" : listener.record.host
            invite = try await listener.store.createPeerInvite(
                name: dialer.name, url: "ws://\(host):\(listener.record.port)/peer")
        }
        try await dialer.store.addPeer(name: listener.name, invite: invite)
    }

    /// Unpairs two computers on both sides, so neither keeps trying the other.
    func disconnect(_ a: Computer, _ b: Computer) async throws {
        if let peer = peer(of: a, for: b) { try await a.store.revokePeer(peer.id) }
        if let peer = peer(of: b, for: a) { try await b.store.revokePeer(peer.id) }
    }

    // MARK: App lifecycle

    func setBackground(_ background: Bool) {
        for computer in computers {
            computer.store.inBackground = background
            if !background { computer.store.client.appBecameActive() }
        }
    }

    /// Cell to Wi-Fi, a new interface, signal back after a dead zone: every
    /// connection checks itself at once instead of waiting on its timers.
    private func watchNetwork() {
        network.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.networkChanged(path) }
        }
        network.start(queue: .main)
    }

    private func networkChanged(_ path: NWPath) {
        let previous = lastPath
        lastPath = path
        // The first path is where the connections started, not a change.
        guard let previous, path != previous, path.status == .satisfied else { return }
        for computer in computers { computer.store.client.networkChanged() }
    }

    /// Decisions waiting on every computer, for the app icon.
    var pendingTotal: Int { computers.reduce(0) { $0 + $1.store.decisionsBadge } }

    /// The first banner any computer wants to show, with its computer.
    var notice: (Computer, Notice)? {
        for computer in computers { if let notice = computer.store.notice { return (computer, notice) } }
        return nil
    }

    // MARK: Private

    private func attach(_ computer: Computer) {
        computer.store.onCountsChanged = { [weak self] in self?.updateBadge() }
        computer.store.onHomeChanged = { [weak self, weak computer] in
            if let computer { self?.home.changed(computer) }
        }
        computers.append(computer)
        retag()
    }

    /// With more than one computer, notifications say which one they are from.
    private func retag() {
        let many = computers.count > 1
        for computer in computers { computer.store.notificationTag = many ? computer.name : nil }
    }

    private func updateBadge() { Notifier.setBadge(pendingTotal) }

    private func save() {
        guard !ephemeral else { return }
        Self.save(computers.map(\.record))
    }

    private static func save(_ records: [ComputerRecord]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(records), forKey: recordsKey)
    }

    private static func loadRecords() -> [ComputerRecord] {
        guard let data = UserDefaults.standard.data(forKey: recordsKey) else { return [] }
        return (try? JSONDecoder().decode([ComputerRecord].self, from: data)) ?? []
    }

    /// The one Mac saved before there could be several: its settings move under
    /// a computer id, and the old keys go.
    private static func migrateLegacy() -> ComputerRecord? {
        let defaults = UserDefaults.standard
        guard let host = defaults.string(forKey: "host"), let token = Keychain.loadToken() else { return nil }
        let port = defaults.integer(forKey: "port")
        let lensPort = defaults.integer(forKey: "lensPort")
        let screenPort = defaults.integer(forKey: "macScreenPort")
        let record = ComputerRecord(
            name: "Mac", kind: .mac, host: host, port: port == 0 ? 49777 : port,
            lensPort: lensPort == 0 ? LensStore.defaultPort : lensPort,
            screenHost: defaults.string(forKey: "macScreenHost") ?? "",
            screenPort: screenPort == 0 ? 5900 : screenPort,
            screenUser: defaults.string(forKey: "macScreenUser") ?? "")
        Keychain.save(token, account: Computer.tokenAccount(record.id), afterFirstUnlock: true)
        if let password = Keychain.load(account: "mac-screen-password") {
            Keychain.save(password, account: Computer.screenPasswordAccount(record.id))
        }
        let scoped = ComputerDefaults(id: record.id)
        for name in ["lastSeen", "screenSize", "screenLayout", "screenFocus"] {
            if let value = defaults.object(forKey: name) { defaults.set(value, forKey: scoped.key(name)) }
        }
        // Gone only once the token is safe under its new name.
        guard Keychain.load(account: Computer.tokenAccount(record.id)) == token else { return record }
        Keychain.deleteToken()
        Keychain.delete(account: "mac-screen-password")
        for name in ["host", "port", "lensPort", "macScreenHost", "macScreenPort", "macScreenUser",
                     "lastSeen", "screenSize", "screenLayout", "screenFocus"] {
            defaults.removeObject(forKey: name)
        }
        return record
    }

    #if DEBUG
    /// Simulator runs against test daemons:
    /// -gravHost … -gravPort … -gravToken … [-lensHost … -lensPort … -screenHost … -screenPort … -screenUser …]
    /// and a second computer with -grav2Host … -grav2Port … -grav2Token … -lens2Port … [-grav2Kind windows].
    /// -selectedComputer debug2 opens on the second.
    private static func debugComputers() -> [(ComputerRecord, String)] {
        let defaults = UserDefaults.standard
        var result: [(ComputerRecord, String)] = []
        for suffix in ["", "2"] {
            guard let host = defaults.string(forKey: "grav\(suffix)Host"),
                  let token = defaults.string(forKey: "grav\(suffix)Token") else { continue }
            let port = defaults.integer(forKey: "grav\(suffix)Port")
            let lensPort = defaults.integer(forKey: "lens\(suffix)Port")
            let kind = ComputerKind(rawValue: defaults.string(forKey: "grav\(suffix)Kind") ?? "") ?? .mac
            let screenPort = defaults.integer(forKey: "screen\(suffix)Port")
            let record = ComputerRecord(
                id: "debug\(suffix)", name: defaults.string(forKey: "grav\(suffix)Name") ?? (suffix.isEmpty ? "Demo Mac" : "Demo PC"),
                kind: kind, host: host, port: port == 0 ? 49777 : port,
                lensHost: defaults.string(forKey: "lens\(suffix)Host") ?? "",
                lensPort: lensPort == 0 ? LensStore.defaultPort : lensPort,
                screenHost: defaults.string(forKey: "screen\(suffix)Host") ?? "",
                screenPort: screenPort == 0 ? 5900 : screenPort,
                screenUser: defaults.string(forKey: "screen\(suffix)User") ?? "")
            result.append((record, token))
        }
        return result
    }
    #endif
}
