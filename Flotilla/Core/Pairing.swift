import Foundation

/// What a pairing code or link carries: where the Hermes service is and the
/// device token to use. `thehermes://pair?host=…&port=…&token=…`, optionally
/// with `name` and `kind` (mac or windows). The `gravity://pair?…` form from
/// before the rename is read the same way.
struct PairingLink: Equatable {
    static let schemes = ["thehermes", "gravity"]
    static let defaultPort = 49777

    var host: String
    var port: Int
    var token: String
    var name: String?
    var kind: ComputerKind?

    /// The first pairing link in `text`, which may be a bare link, a scanned
    /// code or a message the link was pasted from.
    static func parse(_ text: String) -> PairingLink? {
        let lower = text.lowercased()
        guard let start = schemes.compactMap({ lower.range(of: "\($0)://")?.lowerBound }).min() else { return nil }
        let candidate = text[start...].prefix { !$0.isWhitespace && $0 != "<" && $0 != ">" && $0 != "\"" }
        guard let components = URLComponents(string: String(candidate)),
              let scheme = components.scheme?.lowercased(), schemes.contains(scheme),
              components.host?.lowercased() == "pair" || components.path.lowercased().hasSuffix("pair")
        else { return nil }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] where values[item.name] == nil {
            values[item.name] = item.value?.trimmingCharacters(in: .whitespaces)
        }
        guard let host = values["host"], !host.isEmpty,
              let token = values["token"], !token.isEmpty else { return nil }
        let port: Int
        if let text = values["port"], !text.isEmpty {
            guard let value = Int(text), (1...65535).contains(value) else { return nil }
            port = value
        } else {
            port = defaultPort
        }
        let bareHost = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        let name = values["name"].flatMap { $0.isEmpty ? nil : $0 }
        let kind: ComputerKind? = switch values["kind"]?.lowercased() {
        case "mac": .mac
        case "windows": .windows
        default: nil
        }
        return PairingLink(host: bareHost, port: port, token: token, name: name, kind: kind)
    }
}

/// Why connecting a new computer failed, said next to the field to fix.
struct PairingFailure: Equatable {
    enum Field: Equatable { case address, token, version }

    let field: Field
    let message: String

    /// The failure a connection status means, or nil while it is connecting
    /// or once it is connected. `computer` names the computer in the message.
    static func from(_ status: ConnectionStatus, host: String, port: Int, computer: String) -> PairingFailure? {
        switch status {
        case .idle, .connecting, .connected:
            return nil
        case .authFailed:
            return PairingFailure(field: .token,
                                  message: "Token rejected — check it on \(computer) under Settings → Devices.")
        case .versionMismatch:
            return PairingFailure(field: .version,
                                  message: "Update needed — this iPhone and the Hermes service on \(computer) speak different versions. Update the older one.")
        case .disconnected:
            return unreachable(host: host, port: port)
        }
    }

    /// No answer at all: wrong address, the service not running, or not
    /// listening on that address.
    static func unreachable(host: String, port: Int) -> PairingFailure {
        PairingFailure(field: .address,
                       message: "Couldn’t reach \(host):\(port) — check the address, and that the Hermes service is running and lists it under bind in gravityd.toml.")
    }
}
