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
        "/usr/local/bin/openvpn",
        "/opt/local/sbin/openvpn",   // MacPorts
        "/usr/sbin/openvpn"
    ]

    /// A path the user pointed at explicitly wins; otherwise the usual
    /// locations are searched, including MacPorts.
    public static func installedBinary(
        preferred: String? = nil,
        checking exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        bundled: () -> [String] = { bundledBinaries() }
    ) -> String? {
        if let preferred = preferred?.trimmingCharacters(in: .whitespaces), !preferred.isEmpty, exists(preferred) {
            return preferred
        }
        if let installed = binaryCandidates.first(where: exists) { return installed }
        if exists(managedBinaryPath) { return managedBinaryPath }
        // Tunnelblick ships openvpn builds; reuse one rather than installing a second copy.
        return bundled().first(where: exists)
    }

    /// openvpn binaries that come with VPN apps the user may already have.
    /// Tunnelblick keeps one directory per version, so the newest is picked.
    public static func bundledBinaries(
        listing: (String) -> [String] = { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }
    ) -> [String] {
        let root = "/Applications/Tunnelblick.app/Contents/Resources/openvpn"
        return listing(root)
            .filter { $0.hasPrefix("openvpn-") }
            .sorted { $0.localizedStandardCompare($1) == .orderedDescending }
            .map { "\(root)/\($0)/openvpn" }
    }

    /// Homebrew, Intel and Apple Silicon.
    public static let brewCandidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    public static func installedBrew(
        checking exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        brewCandidates.first(where: exists)
    }

    /// What to run in Terminal to get openvpn. Without Homebrew it has to be
    /// installed first, so both steps are handed over at once.
    public static func installCommand(brew: String?) -> String {
        guard let brew else {
            return homebrewInstallCommand + " && " + brewCandidates[0] + " install openvpn"
        }
        return "\(brew) install openvpn"
    }

    /// Homebrew's documented installer.
    public static let homebrewInstallCommand =
        #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#

    /// Checks that a hand-picked file really is an openvpn client.
    public static func versionSpec(binary: String) -> ShortcutExecutionSpec {
        ShortcutExecutionSpec(executable: binary, arguments: ["--version"])
    }

    public static func isOpenVPNVersionOutput(_ output: String) -> Bool {
        output.hasPrefix("OpenVPN ") || output.contains("OpenVPN 2.")
    }

    /// The engine Qevigo downloads for users who have no openvpn at all.
    /// Pinning the digest in the app means a replaced download is refused.
    public struct Engine: Sendable {
        public let version: String
        public let url: URL
        public let sha256: String
        public let approximateSize: String

        public init(version: String, url: URL, sha256: String, approximateSize: String) {
            self.version = version
            self.url = url
            self.sha256 = sha256
            self.approximateSize = approximateSize
        }
    }

    /// Built by .github/workflows/openvpn-engine.yml from pinned sources.
    public static let downloadableEngine = Engine(
        version: "2.7.8",
        url: URL(string: "https://github.com/mohist-club/Qevigo/releases/download/openvpn-2.7.8/openvpn-universal")!,
        sha256: "PENDING",
        approximateSize: "3 MB"
    )

    /// Where a downloaded engine lives. Beside the configurations, so one
    /// directory holds everything Qevigo manages for VPNs.
    public static var managedBinaryPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".qevigo/bin/openvpn")
    }

    public static var isEngineDownloadable: Bool { downloadableEngine.sha256 != "PENDING" }

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

    /// A rule names one exact configuration, so renaming or re-adding a VPN
    /// leaves the old rule behind and the new one unauthorised. The rules are
    /// root-readable only, so coverage is judged by the marker file Qevigo
    /// writes next to its configurations when it installs them.
    public static var rulesMarkerPath: String {
        (configDirectory as NSString).appendingPathComponent(".authorized")
    }

    public static func rulesMarker(binary: String, configs: [String]) -> String {
        ([binary] + configs.sorted()).joined(separator: "\n") + "\n"
    }

    /// True when the installed rules were written for exactly these
    /// configurations and this binary.
    public static func rulesCover(
        binary: String,
        configs: [String],
        marker: String?
    ) -> Bool {
        guard let marker, !configs.isEmpty else { return false }
        return marker == rulesMarker(binary: binary, configs: configs)
    }

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
    public static func installSudoersCommand(stagedFile: String, marker: String? = nil) -> String {
        var command = "sudo visudo -cf \(stagedFile) && sudo install -o root -g wheel -m 440 \(stagedFile) \(sudoersPath)"
        if let marker { command += " && cp \(marker) \(rulesMarkerPath)" }
        return command + " && rm -f \(stagedFile) \(marker ?? "") && echo '✅ 免密配置完成，可以关闭这个窗口'"
    }

    public static func removeSudoersCommand() -> String {
        "sudo rm -f \(sudoersPath) && rm -f \(rulesMarkerPath) && echo '✅ 已恢复为每次询问密码'"
    }
}
