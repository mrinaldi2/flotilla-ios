import Foundation

/// What this build is, from its Info.plist (set in Config/Version.xcconfig).
enum AppInfo {
    static var version: String { string("CFBundleShortVersionString") ?? "?" }
    static var build: String { string("CFBundleVersion") ?? "?" }
    /// "0.2.0 (2)": two installs of the same version still differ by build.
    static var label: String { "\(version) (\(build))" }
    /// The commit it was built from; nil for builds made in Xcode.
    static var commit: String? { string("FlotillaCommit").flatMap { $0.isEmpty ? nil : $0 } }

    static let sourceURL = URL(string: "https://github.com/mrinaldi2/gravity_os")!
    static let noticesURL = URL(string: "https://github.com/mrinaldi2/gravity_os/blob/main/THIRD_PARTY_NOTICES.md")!

    private static func string(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
