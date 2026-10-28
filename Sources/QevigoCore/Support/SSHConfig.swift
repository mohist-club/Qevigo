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

/// A public key file in ~/.ssh, described well enough to tell several apart.
public struct SSHPublicKey: Identifiable, Equatable, Sendable {
    public let path: String
    /// "ED25519", "RSA", … taken from the key's own type field.
    public let algorithm: String
    /// Trailing comment, usually "user@host" or whatever was passed to ssh-keygen.
    public let comment: String

    public var id: String { path }
    public var fileName: String { (path as NSString).lastPathComponent }

    /// "id_ed25519.pub · wayne@mac". The comment identifies a key better than
    /// its algorithm, so the algorithm only fills in when there is no comment.
    public var label: String {
        fileName + " · " + (comment.isEmpty ? algorithm : comment)
    }

    /// Names ssh tries on its own. Installing any other key also needs an
    /// `IdentityFile` line in ~/.ssh/config before ssh will offer it.
    public var isDefaultIdentity: Bool {
        ["id_ed25519.pub", "id_ecdsa.pub", "id_ecdsa_sk.pub", "id_ed25519_sk.pub", "id_rsa.pub"].contains(fileName)
    }

    public init(path: String, algorithm: String, comment: String) {
        self.path = path
        self.algorithm = algorithm
        self.comment = comment
    }

    /// Parses "<type> <base64> <comment>"; the comment may contain spaces.
    public init?(path: String, contents: String) {
        let fields = contents.split(whereSeparator: \.isNewline).first?
            .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true) ?? []
        guard fields.count >= 2 else { return nil }
        self.path = path
        self.algorithm = Self.algorithmName(String(fields[0]))
        self.comment = fields.count > 2 ? String(fields[2]).trimmingCharacters(in: .whitespaces) : ""
    }

    static func algorithmName(_ type: String) -> String {
        if type.hasPrefix("sk-") { return algorithmName(String(type.dropFirst(3))) + tr("（安全密钥）", " (security key)") }
        if type.contains("ed25519") { return "ED25519" }
        if type.contains("rsa") { return "RSA" }
        if type.contains("ecdsa") { return "ECDSA" }
        if type.contains("dss") { return "DSA" }
        return type
    }

    /// Every readable public key in ~/.ssh. ssh's own default identities come
    /// first because they work without further configuration; the rest follow,
    /// newest first.
    public static func available(in directory: String = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh")) -> [SSHPublicKey] {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: directory))?.filter { $0.hasSuffix(".pub") } ?? []
        return names.compactMap { name -> (SSHPublicKey, Date)? in
            let path = (directory as NSString).appendingPathComponent(name)
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8),
                  let key = SSHPublicKey(path: path, contents: contents) else { return nil }
            let created = (try? manager.attributesOfItem(atPath: path)[.creationDate] as? Date) ?? nil
            return (key, created ?? .distantPast)
        }
        .sorted {
            $0.0.isDefaultIdentity == $1.0.isDefaultIdentity ? $0.1 > $1.1 : $0.0.isDefaultIdentity
        }
        .map(\.0)
    }
}
