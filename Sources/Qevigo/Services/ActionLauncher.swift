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
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: binding.payload), configuration: .init()) { _, error in
                if let error { Task { @MainActor in present(error) } }
            }
        case .system:
            guard let action = SystemShortcutAction(rawValue: binding.payload) else { return }
            executeSystem(action, displayName: binding.name)
        case .shortcut, .script:
            guard let spec = binding.executionSpec else { return }
            Task {
                do { _ = try await run(spec) } catch { present(error) }
            }
        }
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
