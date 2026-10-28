import AppKit
import QevigoCore

@MainActor
enum ActionLauncher {
    static func installedApplications() -> [(name: String, path: String)] {
        let fileManager = FileManager.default
        let directories = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                           (NSHomeDirectory() as NSString).appendingPathComponent("Applications")]
        var results: [(String, String)] = []
        for directory in directories {
            guard let items = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            for item in items where item.hasSuffix(".app") {
                results.append(((item as NSString).deletingPathExtension, (directory as NSString).appendingPathComponent(item)))
            }
        }
        return results.sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    static func shortcutNames() async throws -> [String] {
        let output = try await run(ShortcutExecutionSpec(executable: "/usr/bin/shortcuts", arguments: ["list"]))
        return output.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }

    static func execute(_ binding: LaunchBinding) {
        switch binding.kind {
        case .application:
            toggleApplication(at: URL(fileURLWithPath: binding.payload))
        case .system:
            guard let action = SystemShortcutAction(rawValue: binding.payload) else { return }
            executeSystem(action, displayName: binding.name)
        case .shortcut, .script:
            guard let spec = binding.executionSpec else { return }
            Task {
                do { _ = try await run(spec) } catch { present(error) }
            }
        case .ssh:
            connect(binding)
        }
    }

    /// Opens an SSH session in Terminal or VS Code. Authentication is left to
    /// ssh itself: with a key installed the session opens straight away, and
    /// otherwise the terminal prompts. Qevigo never handles the password.
    private static func connect(_ binding: LaunchBinding) {
        guard LaunchBinding.isValidHostAlias(binding.payload) else {
            present(NSError(domain: "Qevigo.SSH", code: 1, userInfo: [
                NSLocalizedDescriptionKey: tr(
                    "主机别名无效：“\(binding.payload)”。请使用 ~/.ssh/config 里的 Host 名称，或 user@host 形式。",
                    "Invalid host alias “\(binding.payload)”. Use a Host from ~/.ssh/config, or user@host."
                )
            ]))
            return
        }
        if binding.sshOpener == .visualStudioCode, !FileManager.default.isExecutableFile(atPath: LaunchBinding.vsCodeBinary) {
            present(NSError(domain: "Qevigo.SSH", code: 2, userInfo: [
                NSLocalizedDescriptionKey: tr(
                    "找不到 VS Code。请把 Visual Studio Code 安装到「应用程序」，并确认已安装 Remote-SSH 扩展。",
                    "VS Code was not found. Install it in /Applications and make sure the Remote-SSH extension is present."
                )
            ]))
            return
        }
        Task {
            guard let spec = await executionSpec(for: binding) else { return }
            do { _ = try await run(spec) } catch { present(error) }
        }
    }

    /// VS Code needs an absolute remote path, so `~` and relative paths are
    /// resolved against the home directory the server reports.
    private static func executionSpec(for binding: LaunchBinding) async -> ShortcutExecutionSpec? {
        guard binding.needsRemoteHome else { return binding.executionSpec }
        guard let home = await remoteHome(of: binding.payload),
              let path = LaunchBinding.resolvedRemotePath(binding.sshRemotePath, home: home) else {
            present(NSError(domain: "Qevigo.SSH", code: 3, userInfo: [
                NSLocalizedDescriptionKey: tr(
                    "无法读取服务器上的家目录，可能是还没配置免密登录。请先用「安装密钥…」配置密钥，或在「远程目录」里填写绝对路径，例如 /root。",
                    "Could not read the home directory on the server, probably because key-based login is not set up yet. Use “Install Key…” first, or enter an absolute path such as /root in “Remote Folder”."
                )
            ]))
            return nil
        }
        return LaunchBinding.vsCodeSpec(alias: binding.payload, remotePath: path)
    }

    /// Asks the server where the user's home directory is. VS Code needs an
    /// absolute remote path, and only the server knows it.
    private static func remoteHome(of alias: String) async -> String? {
        let spec = ShortcutExecutionSpec(
            executable: "/usr/bin/ssh",
            arguments: ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", alias, "echo $HOME"]
        )
        guard let output = try? await run(spec) else { return nil }
        let home = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return home.hasPrefix("/") ? home : nil
    }

    /// Opens Terminal and runs ssh-copy-id so the user types their password
    /// once; afterwards the key handles authentication. The password is typed
    /// into Terminal by the user and never passes through Qevigo.
    static func installSSHKey(alias: String, publicKey: String) {
        guard LaunchBinding.isValidHostAlias(alias) else { return }
        let command = "ssh-copy-id -i \(publicKey) \(alias)"
        let script = """
        tell application "Terminal"
        \tactivate
        \tdo script "\(command)"
        end tell
        """
        Task {
            do {
                _ = try await run(ShortcutExecutionSpec(executable: "/usr/bin/osascript", arguments: ["-e", script]))
            } catch { present(error) }
        }
    }

    /// Hides the app when it is already frontmost; otherwise launches it or
    /// brings it forward (unhiding it and reopening a window if it has none).
    static func toggleApplication(at url: URL) {
        if let frontmost = NSWorkspace.shared.frontmostApplication, isSameApp(frontmost, url) {
            frontmost.hide()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error { Task { @MainActor in present(error) } }
        }
    }

    private static func isSameApp(_ running: NSRunningApplication, _ url: URL) -> Bool {
        if let id = Bundle(url: url)?.bundleIdentifier, let runningID = running.bundleIdentifier {
            return id == runningID
        }
        return running.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func executeSystem(_ action: SystemShortcutAction, displayName: String) {
        if action.requiresConfirmation {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = displayName
            alert.informativeText = tr("此系统操作会立即生效，是否继续？", "This system action takes effect immediately. Continue?")
            alert.addButton(withTitle: tr("继续", "Continue"))
            alert.addButton(withTitle: tr("取消", "Cancel"))
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let source: String
        switch action {
        case .lockScreen: source = #"tell application "System Events" to keystroke "q" using {control down, command down}"#
        case .sleep: source = #"tell application "System Events" to sleep"#
        case .emptyTrash: source = #"tell application "Finder" to empty trash"#
        case .logOut: source = #"tell application "System Events" to log out"#
        case .restart: source = #"tell application "System Events" to restart"#
        case .shutDown: source = #"tell application "System Events" to shut down"#
        }
        var info: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&info)
        if let info {
            present(NSError(domain: "Qevigo.SystemAction", code: info[NSAppleScript.errorNumber] as? Int ?? 1, userInfo: [
                NSLocalizedDescriptionKey: info[NSAppleScript.errorMessage] as? String ?? tr("系统操作失败", "System action failed")
            ]))
        }
    }

    private static func run(_ spec: ShortcutExecutionSpec) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: spec.executable)
                process.arguments = spec.arguments
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: output)
                    } else {
                        continuation.resume(throwing: NSError(domain: "Qevigo.Action", code: Int(process.terminationStatus), userInfo: [
                            NSLocalizedDescriptionKey: output.isEmpty ? tr("操作执行失败", "The action failed") : output
                        ]))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func present(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        NSAlert(error: error).runModal()
    }
}
