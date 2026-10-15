import Foundation

/// Frames are read leniently as dictionaries: the daemon adds fields between
/// releases, and a strict decoder would drop a whole frame over one of them.
typealias JSONDict = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func str(_ key: String) -> String { self[key] as? String ?? "" }

    func optStr(_ key: String) -> String? {
        guard let value = self[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    func int(_ key: String) -> Int { (self[key] as? NSNumber)?.intValue ?? 0 }

    func optInt(_ key: String) -> Int? { (self[key] as? NSNumber)?.intValue }

    func bool(_ key: String) -> Bool { self[key] as? Bool ?? false }

    func dict(_ key: String) -> JSONDict? { self[key] as? JSONDict }

    func list(_ key: String) -> [JSONDict] { self[key] as? [JSONDict] ?? [] }

    func strings(_ key: String) -> [String] { self[key] as? [String] ?? [] }

    func date(_ key: String) -> Date? { optStr(key).flatMap(WireDate.parse) }
}

/// Timestamps are RFC 3339 UTC, with or without fractional seconds.
enum WireDate {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ text: String) -> Date? {
        fractional.date(from: text) ?? plain.date(from: text)
    }

    static func string(_ date: Date) -> String { plain.string(from: date) }
}

enum JSONText {
    static func encode(_ value: JSONDict) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ text: String) -> JSONDict? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? JSONDict
    }
}
