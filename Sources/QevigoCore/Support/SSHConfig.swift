import Foundation

public struct SSHHost: Identifiable, Equatable, Sendable {
    /// The alias as written after `Host`, which is what `ssh <alias>` takes.
    public let alias: String
    public let hostName: String?
    public let user: String?
    public let port: Int?

    public var id: String { alias }

    /// "user@example.com:22", or just the alias when the entry has no details.
    public var detail: String {
        var text = hostName ?? ""
        if let user, !text.isEmpty { text = "\(user)@\(text)" }
        if let port, port != 22, !text.isEmpty { text += ":\(port)" }
        return text
    }

    public init(alias: String, hostName: String? = nil, user: String? = nil, port: Int? = nil) {
        self.alias = alias
        self.hostName = hostName
        self.user = user
        self.port = port
    }
}

/// Reads host aliases out of an OpenSSH client config so they can be offered
/// as shortcut targets. Only the few keys shown in the picker are parsed;
/// everything else (keys, proxies, forwarding) stays with ssh itself.
public enum SSHConfig {
    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh/config")
    }

    public static func hosts(at url: URL = defaultURL) -> [SSHHost] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return hosts(parsing: text)
    }

    public static func hosts(parsing text: String) -> [SSHHost] {
        var hosts: [SSHHost] = []
        var aliases: [String] = []
        var hostName: String?
        var user: String?
        var port: Int?

        func flush() {
            for alias in aliases {
                hosts.append(SSHHost(alias: alias, hostName: hostName, user: user, port: port))
            }
            aliases = []
            hostName = nil
            user = nil
            port = nil
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            // "Key value", "Key=value" and extra spaces are all valid.
            let parts = line.replacingOccurrences(of: "=", with: " ")
                .split(separator: " ", omittingEmptySubsequences: true)
            guard let keyword = parts.first.map({ String($0).lowercased() }) else { continue }
            let values = parts.dropFirst().map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }

            switch keyword {
            case "host":
                flush()
                // Patterns and negations match many hosts; they are not connectable targets.
                aliases = values.filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
            case "hostname" where !aliases.isEmpty:
                hostName = values.first
            case "user" where !aliases.isEmpty:
                user = values.first
            case "port" where !aliases.isEmpty:
                port = values.first.flatMap(Int.init)
            case "match":
                // Conditional blocks are not plain targets; stop attributing keys to the previous Host.
                flush()
            default:
                continue
            }
        }
        flush()

        var seen = Set<String>()
        return hosts.filter { seen.insert($0.alias).inserted }
    }
}
