import Foundation

// Installing an approved iOS release on this iPhone or iPad (H-230, UX-043 iOS
// part; the daemon side is H-229, hermes.home.v1 ReleaseInstall* / InstallOffer*
// as JSON with the proto field names).

/// What a package offers for install on a phone (`release_install`).
struct ReleaseInstallInfo: Equatable {
    let releaseId: String
    let version: String
    /// The iOS build's version, e.g. "12"; empty = no build.
    let build: String
    let state: String
    let installable: Bool
    let forTesting: Bool
    let pageURL: URL?
    /// The itms-services link: the only thing the app ever opens (CE M1).
    let installURL: URL?
    let computer: String
    /// Whether the build site answered when the daemon checked; nil = not checked.
    let siteServing: Bool?

    init(_ d: JSONDict) {
        releaseId = d.str("release_id")
        version = d.str("version")
        build = d.str("build")
        state = d.str("state")
        installable = d.bool("installable")
        forTesting = d.bool("for_testing")
        pageURL = d.optStr("page_url").flatMap { $0.isEmpty ? nil : URL(string: $0) }
        installURL = d.optStr("install_url").flatMap { $0.isEmpty ? nil : URL(string: $0) }
        computer = d.str("computer")
        siteServing = d.dict("site").map { $0.bool("serving") }
    }
}

/// This device's waiting offer (`install_offers`, or the `install_offer` push).
struct InstallOffer: Equatable {
    let releaseId: String
    let projectId: String
    let version: String
    let build: String
    let installURL: URL?
    let pageURL: URL?
    let forTesting: Bool

    init(_ d: JSONDict) {
        releaseId = d.str("release_id")
        projectId = d.str("project_id")
        version = d.str("version")
        build = d.str("build")
        installURL = d.optStr("install_url").flatMap { $0.isEmpty ? nil : URL(string: $0) }
        pageURL = d.optStr("page_url").flatMap { $0.isEmpty ? nil : URL(string: $0) }
        forTesting = d.bool("for_testing")
    }
}

/// What the release screen shows for install (UX-043 §1, §4).
enum InstallState: Equatable {
    /// Rejected, held, cancelled: nothing.
    case hidden
    case notPublished
    /// The daemon found the build site not serving.
    case siteOff(computer: String)
    case ready(forTesting: Bool)
    /// This device already runs that version and build.
    case sameVersion
    /// This device runs a newer version.
    case newerInstalled(String)

    static let shownStates: Set = ["awaiting_owner", "approved", "deploying", "deployed"]
    static let unpublishedStates: Set = ["planned", "assembling", "built"]

    static func of(_ info: ReleaseInstallInfo, installed: (version: String, build: String)) -> InstallState {
        if unpublishedStates.contains(info.state) { return .notPublished }
        guard shownStates.contains(info.state), info.installable else { return .hidden }
        // Install info the daemon couldn't derive is empty, and a link that doesn't
        // check out is never offered: not published (CE M1, CE review).
        guard InstallLink.isSafe(info.installURL, page: info.pageURL), !info.build.isEmpty else { return .notPublished }
        if info.siteServing == false { return .siteOff(computer: info.computer) }
        switch AppVersion.compare(installed, (info.version, info.build)) {
        case .orderedSame: return .sameVersion
        case .orderedDescending: return .newerInstalled(installed.version)
        case .orderedAscending: return .ready(forTesting: info.forTesting)
        }
    }
}

/// What the app agrees to open (CE review): an itms-services link whose
/// manifest `url=` is HTTPS on the same host as the HTTPS install page.
enum InstallLink {
    static func isSafe(_ install: URL?, page: URL?) -> Bool {
        guard let install, install.scheme?.lowercased() == "itms-services",
              let page, page.scheme?.lowercased() == "https", let pageHost = page.host?.lowercased(),
              let manifest = URLComponents(url: install, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "url" })?.value.flatMap(URL.init(string:)),
              manifest.scheme?.lowercased() == "https", manifest.host?.lowercased() == pageHost
        else { return false }
        return true
    }
}

/// Versions as "0.6.1" plus a build number.
enum AppVersion {
    static func compare(_ a: (version: String, build: String), _ b: (version: String, build: String)) -> ComparisonResult {
        let byVersion = a.version.compare(b.version, options: .numeric)
        if byVersion != .orderedSame { return byVersion }
        return a.build.compare(b.build, options: .numeric)
    }
}

/// UX-043's words. `device` is "iPhone" or "iPad", the device's own type.
enum InstallWords {
    static func button(device: String, forTesting: Bool) -> String {
        forTesting ? "Install on this \(device) to test" : "Install on this \(device)"
    }

    static let opensSafari = "Opens the install page in Safari. The Hermes closes while it updates."
    static let profile = "If iOS says it can't install, this device may not be in the build's profile. Ask DevOps."

    static func hint(_ version: String) -> String { "Opens Safari to install The Hermes \(version)." }

    static func siteOff(computer: String) -> String {
        "The build site on \(computer.isEmpty ? "its computer" : computer) isn't serving. Ask DevOps to start it, then try again."
    }

    /// The same on every device (UX-047).
    static let notPublished = "This package has no iPhone or iPad build to install yet. DevOps publishes it after building."

    static func sameVersion(device: String, version: String, build: String) -> String {
        "✓ This \(device) has The Hermes \(version) (\(build))."
    }

    static let reinstall = "Reinstall"

    static func newer(device: String, version: String) -> String { "This \(device) has a newer version (\(version))." }

    static func anyway(_ version: String) -> String { "Install \(version) anyway" }

    static func unreachable(device: String) -> String {
        "Can't reach the build site from this \(device). Turn on Tailscale, then try again."
    }

    static let tryAgain = "Try again"

    static func banner(_ version: String) -> String { "The Hermes \(version) is ready to install" }

    static let install = "Install"
    static let notNow = "Not now"

    static func updated(_ version: String) -> String { "Updated to The Hermes \(version)." }
}

/// Install on this device: check the page answers from here, then hand the
/// itms-services link to iOS (UX-043 §3, §4). No Face ID: iOS asks itself.
@MainActor
enum InstallAction {
    enum Outcome: Equatable {
        case opened(URL)
        /// The build site can't be reached from this device (Tailscale off).
        case unreachable
        case notPublished
    }

    static func install(_ info: ReleaseInstallInfo,
                        reachable: (URL) async -> Bool = InstallAction.reachable,
                        open: (URL) -> Void) async -> Outcome {
        guard let url = info.installURL, let page = info.pageURL, InstallLink.isSafe(url, page: page) else { return .notPublished }
        if !(await reachable(page)) { return .unreachable }
        open(url)
        return .opened(url)
    }

    static func install(_ offer: InstallOffer,
                        reachable: (URL) async -> Bool = InstallAction.reachable,
                        open: (URL) -> Void) async -> Outcome {
        guard let url = offer.installURL, let page = offer.pageURL, InstallLink.isSafe(url, page: page) else { return .notPublished }
        if !(await reachable(page)) { return .unreachable }
        open(url)
        return .opened(url)
    }

    /// The install page answers over HTTPS from this device.
    /// Only an HTTPS page is ever probed (CE review).
    nonisolated static func reachable(_ page: URL) async -> Bool {
        guard page.scheme?.lowercased() == "https" else { return false }
        var request = URLRequest(url: page, timeoutInterval: 4)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2
    }
}

/// "Updated to The Hermes 0.6.1.", once per new version (UX-043 §5). The new
/// version counts as announced only once the toast was seen (QA-013: a cold
/// launch can stay blank for seconds, and a toast shown then was lost).
enum UpdateNotice {
    static let key = "lastLaunchedVersion"
    /// How long the toast stays on screen, counted while the app runs.
    static let visible: Duration = .seconds(4)

    /// The toast this launch owes, if the version changed since the last one
    /// announced. A first launch says nothing, and records the version.
    static func pending(_ defaults: UserDefaults = .standard, version: String = AppInfo.version,
                        build: String = AppInfo.build) -> String? {
        let label = "\(version) (\(build))"
        guard let last = defaults.string(forKey: key) else {
            defaults.set(label, forKey: key)
            return nil
        }
        return last == label ? nil : InstallWords.updated(version)
    }

    /// After the toast has been on screen.
    static func markShown(_ defaults: UserDefaults = .standard, version: String = AppInfo.version,
                          build: String = AppInfo.build) {
        defaults.set("\(version) (\(build))", forKey: key)
    }
}

#if DEBUG
/// QA captures (H-230): the demo can't seed an approved iOS package without
/// owner proof, so Debug builds take the daemon's replies from launch arguments.
/// Only the data is stubbed: InstallLink.isSafe still checks every URL.
///   -installStub <json>       the `release_install` reply, {"install": {...}}
///   -installOfferStub <json>  the `install_offers` reply, {"offers": [{...}]}, also
///                             delivered as an `install_offer` push
///   -releaseStub <json>       the `get_release` reply, {"release": {...}}: that release
///                             opens at launch (Needs you), for the install section to render in
enum InstallStubs {
    static let installKey = "installStub"
    static let offerKey = "installOfferStub"
    static let releaseKey = "releaseStub"

    /// The stubbed release's id, to open at launch.
    static var releaseId: String? {
        reply(releaseKey)?.dict("release").map { $0.str("id") }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Bare JSON straight from the launch arguments (the argument domain can't
    /// parse `{…}`), else a quoted plist string through UserDefaults.
    static func reply(_ key: String, _ defaults: UserDefaults = .standard,
                      arguments: [String] = ProcessInfo.processInfo.arguments) -> JSONDict? {
        if let flag = arguments.firstIndex(of: "-" + key), flag + 1 < arguments.count,
           let bare = JSONText.decode(arguments[flag + 1]) {
            return bare
        }
        return defaults.string(forKey: key).flatMap(JSONText.decode)
    }
}
#endif

extension AppStore {
    /// What this package offers for install here; nil on a service without it (before 0.17.5).
    func releaseInstall(_ releaseId: String, checkSite: Bool = true) async throws -> ReleaseInstallInfo? {
        #if DEBUG
        if let stub = InstallStubs.reply(InstallStubs.installKey) { return stub.dict("install").map(ReleaseInstallInfo.init) }
        #endif
        let reply = try await client.request("release_install", ["release_id": releaseId, "check_site": checkSite])
        return reply.dict("install").map(ReleaseInstallInfo.init)
    }

    /// This device's waiting offer, if any. A service without offers says nothing.
    func refreshInstallOffer() async {
        #if DEBUG
        if let stub = InstallStubs.reply(InstallStubs.offerKey) {
            installOffer = stub.list("offers").first.map(InstallOffer.init)
            // And as the push a sent offer arrives as.
            if let offer = stub.list("offers").first { pushReceived("install_offer", ["type": "install_offer", "offer": offer]) }
            return
        }
        #endif
        guard let reply = try? await client.request("install_offers") else { return }
        installOffer = reply.list("offers").first.map(InstallOffer.init)
    }

    /// Not now: hidden until the next package.
    func dismissInstallOffer() async {
        guard let offer = installOffer else { return }
        installOffer = nil
        #if DEBUG
        if InstallStubs.reply(InstallStubs.offerKey) != nil { return }
        #endif
        _ = try? await client.request("install_offer_dismiss", ["release_id": offer.releaseId])
    }
}
