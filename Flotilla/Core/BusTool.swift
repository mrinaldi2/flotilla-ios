import Foundation

/// The tools bots use to talk on the bus. The server was "gravity-bus" and
/// is "hermes-bus" from The Hermes 0.14; transcripts hold both, so both count.
enum BusTool {
    static let prefixes = ["mcp__hermes-bus__", "mcp__gravity-bus__"]

    static func isBus(_ tool: String) -> Bool {
        prefixes.contains { tool.hasPrefix($0) }
    }
}
