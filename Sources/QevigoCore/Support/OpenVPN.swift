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

    /// Lists openvpn processes started with this configuration. Works without
    /// root, so it can be trusted even when the pid file is gone.
    public static func findProcessesSpec(config: String) -> ShortcutExecutionSpec {
        ShortcutExecutionSpec(executable: "/usr/bin/pgrep", arguments: ["-f", "--", config])
    }

    /// Stops the tunnel by matching the configuration path. Used when the pid
    /// file is missing, which is exactly when a stray tunnel is hardest to kill.
    public static func forceDisconnectSpec(config: String, interactive: Bool) -> ShortcutExecutionSpec {
        ShortcutExecutionSpec(
            executable: "/usr/bin/sudo",
            arguments: (interactive ? [] : ["-n"]) + ["/usr/bin/pkill", "-TERM", "-f", "--", config]
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
    /// openvpn runs as root, so `kill(pid, 0)` from the user's process answers
    /// EPERM for a live tunnel. Only ESRCH means the process is gone.
    public static func processExists(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    public static func isConnected(
        config: String,
        readPID: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) },
        isRunning: (Int32) -> Bool = processExists
    ) -> Bool {
        guard let raw = readPID(pidPath(forConfig: config)),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return isRunning(pid)
    }

    /// openvpn prints this once the tunnel is up and routes are in place.
    public static let readyMarker = "Initialization Sequence Completed"

    /// Lines worth showing when a connection fails; the rest of the log is noise.
    public static func failureSummary(log: String, limit: Int = 4) -> String {
        let interesting = log.split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { line in
                let lower = line.lowercased()
                return ["error", "fatal", "fail", "cannot", "denied", "refused", "timeout", "auth"]
                    .contains { lower.contains($0) }
            }
        let chosen = interesting.isEmpty
            ? log.split(whereSeparator: \.isNewline).suffix(limit).map(String.init)
            : Array(interesting.suffix(limit))
        // Timestamps add width without adding meaning in an alert.
        return chosen
            .map { $0.replacingOccurrences(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} "#, with: "", options: .regularExpression) }
            .joined(separator: "\n")
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
            for stop in [
                ["/usr/bin/pkill", "-TERM", "-F", pidPath(forConfig: config)],
                ["/usr/bin/pkill", "-TERM", "-f", "--", config]
            ] {
                lines.append("\(user) ALL=(root) NOPASSWD: \(stop.map(escapeForSudoers).joined(separator: " "))")
            }
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
