import Foundation

/// Drives the `openvpn` command-line client, which is the full OpenVPN client
/// without a GUI. Creating the tunnel interface and editing routes needs root,
/// so every command goes through sudo: either silently, once a sudoers rule is
/// installed, or by asking for the password in Terminal.
public enum OpenVPN {
    /// Where Homebrew puts the binary, Intel and Apple Silicon.
    public static let binaryCandidates = [
        "/opt/homebrew/sbin/openvpn",
        "/usr/local/sbin/openvpn",
        "/opt/homebrew/bin/openvpn",
        "/usr/local/bin/openvpn"
    ]

    public static func installedBinary(
        checking exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        binaryCandidates.first(where: exists)
    }

    /// Configurations live outside Application Support because that path
    /// contains a space, which sudoers rules cannot express safely.
    public static var configDirectory: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".qevigo/vpn")
    }

    public static func configPath(name: String) -> String {
        (configDirectory as NSString).appendingPathComponent(name + ".ovpn")
    }

    public static func pidPath(forConfig config: String) -> String {
        (config as NSString).deletingPathExtension + ".pid"
    }

    public static func logPath(forConfig config: String) -> String {
        (config as NSString).deletingPathExtension + ".log"
    }

    /// A sudoers rule has to match the command exactly, so the argument list is
    /// fixed here and used verbatim by both the rule and the launch.
    public static func connectArguments(binary: String, config: String) -> [String] {
        [
            binary,
            "--config", config,
            // Placed after --config so a modified configuration cannot raise it:
            // level 1 keeps openvpn from running scripts named in the file.
            "--script-security", "1",
            "--daemon",
            "--writepid", pidPath(forConfig: config),
            "--log", logPath(forConfig: config)
        ]
    }

    public static func connectSpec(binary: String, config: String, interactive: Bool) -> ShortcutExecutionSpec {
        let sudo = interactive ? ["/usr/bin/sudo"] : ["/usr/bin/sudo", "-n"]
        return ShortcutExecutionSpec(
            executable: "/usr/bin/sudo",
            arguments: Array((sudo + connectArguments(binary: binary, config: config)).dropFirst())
        )
    }

    public static func disconnectSpec(config: String, interactive: Bool) -> ShortcutExecutionSpec {
        let arguments = ["/usr/bin/pkill", "-TERM", "-F", pidPath(forConfig: config)]
        return ShortcutExecutionSpec(
            executable: "/usr/bin/sudo",
            arguments: (interactive ? [] : ["-n"]) + arguments
        )
    }

    /// True when the pid file names a process that is still alive.
    public static func isConnected(
        config: String,
        readPID: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) },
        isRunning: (Int32) -> Bool = { kill($0, 0) == 0 }
    ) -> Bool {
        guard let raw = readPID(pidPath(forConfig: config)),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return isRunning(pid)
    }

    public static let sudoersPath = "/etc/sudoers.d/qevigo-openvpn"

    /// Rules that let the current user start and stop exactly these tunnels
    /// without a password. Anyone able to edit a listed .ovpn file can make
    /// openvpn run as root, so the files are kept private to the user.
    public static func sudoersFile(user: String, binary: String, configs: [String]) -> String {
        var lines = [
            "# Written by Qevigo. Lets \(user) start and stop the OpenVPN",
            "# configurations below without typing a password.",
            "# Remove this file to require a password again."
        ]
        for config in configs.sorted() {
            let connect = connectArguments(binary: binary, config: config)
                .map(escapeForSudoers)
                .joined(separator: " ")
            lines.append("\(user) ALL=(root) NOPASSWD: \(connect)")
            let disconnect = ["/usr/bin/pkill", "-TERM", "-F", pidPath(forConfig: config)]
                .map(escapeForSudoers)
                .joined(separator: " ")
            lines.append("\(user) ALL=(root) NOPASSWD: \(disconnect)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// sudoers treats these characters specially; a path containing one cannot
    /// be written as a plain word.
    static func escapeForSudoers(_ value: String) -> String {
        var escaped = ""
        for character in value {
            if ", :\\=#\"".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    /// A config name becomes a file name and part of a sudoers rule, so it is
    /// restricted to characters that are safe in both.
    public static func isValidConfigName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 60, !trimmed.hasPrefix(".") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return trimmed.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// Shell command that validates the generated rules and installs them.
    /// Run in Terminal so the user types their password once, in a window they
    /// can see, rather than into Qevigo.
    public static func installSudoersCommand(stagedFile: String) -> String {
        "sudo visudo -cf \(stagedFile) && sudo install -o root -g wheel -m 440 \(stagedFile) \(sudoersPath)"
            + " && rm -f \(stagedFile) && echo '✅ 免密配置完成，可以关闭这个窗口'"
    }

    public static func removeSudoersCommand() -> String {
        "sudo rm -f \(sudoersPath) && echo '✅ 已恢复为每次询问密码'"
    }
}
