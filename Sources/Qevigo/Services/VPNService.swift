import AppKit
import QevigoCore

/// Connects and disconnects OpenVPN tunnels through the `openvpn` CLI.
///
/// openvpn needs root, so every command runs through sudo. Once the user
/// installs the sudoers rules (from the VPN settings sheet) it runs silently;
/// before that, each command opens Terminal so the password is typed there and
/// never passes through Qevigo.
@MainActor
enum VPNService {
    enum Status: Equatable {
        case connected
        case disconnected
        case notInstalled
        case missingConfig
    }

    /// The binary the user pointed at, if any.
    static var preferredBinary: String? {
        let path = AppEnvironment.shared.settings.preferences.openvpnPath
        return path.isEmpty ? nil : path
    }

    static func binary() -> String? { OpenVPN.installedBinary(preferred: preferredBinary) }

    static func status(configPath: String) -> Status {
        guard binary() != nil else { return .notInstalled }
        guard FileManager.default.fileExists(atPath: configPath) else { return .missingConfig }
        return OpenVPN.isConnected(config: configPath) ? .connected : .disconnected
    }

    /// True when sudo will run the tunnel commands without asking for a password.
    static var hasPasswordlessRules: Bool {
        FileManager.default.fileExists(atPath: OpenVPN.sudoersPath)
    }

    /// Rules name exact configuration paths, so a renamed or newly added VPN
    /// is not covered by rules written earlier.
    static func rulesCover(bindings: [LaunchBinding]) -> Bool {
        guard hasPasswordlessRules, let binary = binary() else { return false }
        let marker = try? String(contentsOfFile: OpenVPN.rulesMarkerPath, encoding: .utf8)
        return OpenVPN.rulesCover(
            binary: binary,
            configs: VPNConfigStore.managedConfigs(in: bindings),
            marker: marker
        )
    }

    /// One hotkey connects and disconnects: pressing it again takes the tunnel down.
    static func toggle(_ binding: LaunchBinding) {
        Task { await toggleChecked(binding) }
    }

    /// Asks the system for running tunnels before deciding. Starting a second
    /// openvpn for the same configuration would add a second set of default
    /// routes and take the whole machine offline, so a tunnel that is running
    /// is always stopped rather than started again.
    private static func toggleChecked(_ binding: LaunchBinding) async {
        let config = binding.payload
        if await isRunning(config: config), status(configPath: config) != .notInstalled {
            disconnect(binding)
            return
        }
        switch status(configPath: config) {
        case .notInstalled:
            present(tr(
                "没有找到 openvpn。请在设置 → 快捷键里打开这个 VPN 配置，用「安装 openvpn」按钮装好后再试。",
                "openvpn was not found. Open this VPN in Settings → Shortcuts and use the “Install openvpn” button first."
            ))
        case .missingConfig:
            present(tr(
                "找不到配置文件：\(config)。请在设置 → 快捷键里重新添加这个 VPN。",
                "Configuration file not found: \(config). Add the VPN again in Settings → Shortcuts."
            ))
        case .connected:
            disconnect(binding)
        case .disconnected:
            guard let binary = binary() else { return }
            prepareOutputFiles(config: config)
            run(OpenVPN.connectSpec(binary: binary, config: config, interactive: false),
                fallback: OpenVPN.connectSpec(binary: binary, config: config, interactive: true),
                describing: tr("连接 \(binding.name)", "Connecting \(binding.name)"),
                waitForTunnel: config)
        }
    }

    /// True when any openvpn process is using this configuration, pid file or not.
    static func isRunning(config: String) async -> Bool {
        guard let output = try? await ActionLauncher.runSpec(OpenVPN.findProcessesSpec(config: config)) else {
            // pgrep exits non-zero when nothing matches.
            return OpenVPN.isConnected(config: config)
        }
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Stops the tunnel, falling back to matching the configuration path when
    /// the pid file is missing — otherwise a stray tunnel could not be stopped
    /// from the app at all.
    private static func disconnect(_ binding: LaunchBinding) {
        let config = binding.payload
        let action = tr("断开 \(binding.name)", "Disconnecting \(binding.name)")
        Task {
            do {
                _ = try await ActionLauncher.runSpec(OpenVPN.disconnectSpec(config: config, interactive: false))
            } catch {
                if (try? await ActionLauncher.runSpec(OpenVPN.forceDisconnectSpec(config: config, interactive: false))) == nil {
                    // The same grant installs the rules, so this is the last
                    // time stopping a tunnel asks for anything.
                    await authorizeAndRun(OpenVPN.forceDisconnectSpec(config: config, interactive: true), describing: action)
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if await isRunning(config: config) {
                _ = try? await ActionLauncher.runSpec(OpenVPN.forceDisconnectSpec(config: config, interactive: false))
            }
        }
    }

    /// Creates the log and pid files up front, owned by the user. openvpn runs
    /// as root and would otherwise create them root-only, leaving the user
    /// unable to read why a connection failed.
    private static func prepareOutputFiles(config: String) {
        let manager = FileManager.default
        for path in [OpenVPN.logPath(forConfig: config), OpenVPN.pidPath(forConfig: config)] {
            try? manager.removeItem(atPath: path)
            manager.createFile(atPath: path, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
    }

    /// Tries the silent command first. When sudo needs a password, the same
    /// command is handed to Terminal so the user can type it.
    private static func run(
        _ spec: ShortcutExecutionSpec,
        fallback: ShortcutExecutionSpec,
        describing action: String,
        waitForTunnel config: String? = nil
    ) {
        Task {
            do {
                _ = try await ActionLauncher.runSpec(spec)
                if let config { await reportOutcome(config: config, action: action) }
            } catch {
                await authorizeAndRun(fallback, describing: action)
                if let config { await reportOutcome(config: config, action: action) }
            }
        }
    }

    /// Asks for authorisation once and, while it is granted, also installs the
    /// passwordless rules so later connects and disconnects need nothing.
    private static func authorizeAndRun(_ spec: ShortcutExecutionSpec, describing action: String) async {
        let command = ([spec.executable] + spec.arguments.filter { $0 != "-n" }).map(quoteForShell).joined(separator: " ")
        let bindings = AppEnvironment.shared.settings.bindings
        var full = command
        if !rulesCover(bindings: bindings), let install = VPNConfigStore.sudoersInstallCommand(for: bindings) {
            // Separated by ';' so the action still runs if the rules fail.
            // ';' so the action still runs if installing the rules fails.
            full = install + " ; " + command
        }
        await runAsAdministrator(command: full, describing: action)
    }

    /// openvpn daemonises immediately, so success is judged by the log: it
    /// prints a known line once the tunnel and its routes are up.
    private static func reportOutcome(config: String, action: String) async {
        let logPath = OpenVPN.logPath(forConfig: config)
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
            if log.contains(OpenVPN.readyMarker) { return }
            // The daemon exits on a fatal error, so a dead process means failure.
            if !log.isEmpty, !OpenVPN.isConnected(config: config) {
                present(tr(
                    "\(action)失败：\n\n\(OpenVPN.failureSummary(log: log))",
                    "\(action) failed:\n\n\(OpenVPN.failureSummary(log: log))"
                ))
                return
            }
        }
        present(tr(
            "\(action)超时（20 秒内没有建立隧道）。日志：\(logPath)",
            "\(action) timed out after 20s. Log: \(logPath)"
        ))
    }

    /// Runs a command as root behind the system's own authorisation dialog.
    /// The password is typed into that dialog, so it never reaches Qevigo, and
    /// no Terminal window — nor permission to control Terminal — is involved.
    /// Returns false when the user cancels or the command fails.
    @discardableResult
    static func runAsAdministrator(command: String, describing action: String) async -> Bool {
        let script = "do shell script \(appleScriptString(command)) with administrator privileges"
        // The dialog blocks, so it runs off the main actor; only the plain
        // values come back.
        let outcome: (code: Int, message: String)? = await Task.detached {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            guard let error else { return nil }
            return (error[NSAppleScript.errorNumber] as? Int ?? 0,
                    error[NSAppleScript.errorMessage] as? String ?? "")
        }.value
        guard let outcome else { return true }
        // -128 is the user dismissing the dialog, which needs no explanation.
        if outcome.code == -128 { return false }
        present(tr("\(action)失败：\(outcome.message)", "\(action) failed: \(outcome.message)"))
        return false
    }

    /// Runs a command in Terminal, where sudo can prompt for a password.
    static func openInTerminal(_ spec: ShortcutExecutionSpec, note: String? = nil) {
        let command = ([spec.executable] + spec.arguments).map(quoteForShell).joined(separator: " ")
        openInTerminal(command: command, note: note)
    }

    static func openInTerminal(command: String, note: String? = nil) {
        var shellCommand = command
        if let note { shellCommand = "echo \(quoteForShell(note)); " + command }
        let script = """
        tell application "Terminal"
        \tactivate
        \tdo script \(appleScriptString(shellCommand))
        end tell
        """
        var info: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&info)
        guard let info else { return }
        // Controlling Terminal needs the user's permission, and a refusal here
        // used to leave no way to run the command at all.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        let reason = info[NSAppleScript.errorMessage] as? String ?? ""
        present(tr(
            "Qevigo 无法打开终端（\(reason)）。命令已复制到剪贴板，请自己打开终端粘贴执行。\n\n如果是权限问题，可到 系统设置 → 隐私与安全性 → 自动化 中允许 Qevigo 控制「终端」。",
            "Qevigo could not open Terminal (\(reason)). The command is on the clipboard; paste it into Terminal yourself.\n\nIf this is a permission problem, allow Qevigo to control Terminal in System Settings → Privacy & Security → Automation."
        ))
    }

    private static func quoteForShell(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func present(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Qevigo"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// Stores the .ovpn files Qevigo manages, private to the user.
@MainActor
enum VPNConfigStore {
    /// Copies a chosen .ovpn into Qevigo's own directory so the path stays
    /// valid and the file keeps 0600 permissions (it contains a private key).
    static func install(source: URL, name: String) throws -> String {
        let manager = FileManager.default
        try manager.createDirectory(atPath: OpenVPN.configDirectory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let destination = OpenVPN.configPath(name: name)
        if manager.fileExists(atPath: destination) { try manager.removeItem(atPath: destination) }
        try manager.copyItem(atPath: source.path, toPath: destination)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination)
        return destination
    }

    static func remove(configPath: String) {
        for path in [configPath, OpenVPN.pidPath(forConfig: configPath), OpenVPN.logPath(forConfig: configPath)] {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    static func managedConfigs(in bindings: [LaunchBinding]) -> [String] {
        bindings.filter { $0.kind == .vpn }.map(\.payload).filter {
            $0.hasPrefix(OpenVPN.configDirectory)
        }
    }

    /// Writes the rules to a temporary file and returns the Terminal command
    /// that validates and installs them. Qevigo never writes to /etc itself.
    static func sudoersInstallCommand(for bindings: [LaunchBinding]) -> String? {
        guard let binary = VPNService.binary() else { return nil }
        let configs = managedConfigs(in: bindings)
        guard !configs.isEmpty else { return nil }
        let contents = OpenVPN.sudoersFile(user: NSUserName(), binary: binary, configs: configs)
        let staged = (NSTemporaryDirectory() as NSString).appendingPathComponent("qevigo-openvpn.sudoers")
        let stagedMarker = (NSTemporaryDirectory() as NSString).appendingPathComponent("qevigo-openvpn.marker")
        let marker = OpenVPN.rulesMarker(binary: binary, configs: configs)
        guard (try? contents.write(toFile: staged, atomically: true, encoding: .utf8)) != nil,
              (try? marker.write(toFile: stagedMarker, atomically: true, encoding: .utf8)) != nil else { return nil }
        return OpenVPN.installSudoersCommand(stagedFile: staged, marker: stagedMarker)
    }
}
