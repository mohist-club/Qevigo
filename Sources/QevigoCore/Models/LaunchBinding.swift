import Foundation

public enum ShortcutActionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case application, shortcut, system, script, ssh

    public var id: String { rawValue }
}

/// Where an SSH session is opened.
public enum SSHOpener: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A new window of Terminal.app running `ssh <alias>`.
    case terminal
    /// VS Code's Remote-SSH, which opens a window attached to the server.
    case visualStudioCode

    public var id: String { rawValue }

    public var localizedName: String {
        switch self {
        case .terminal: return tr("终端", "Terminal")
        case .visualStudioCode: return "VS Code"
        }
    }
}

public enum SystemShortcutAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case lockScreen, sleep, emptyTrash, logOut, restart, shutDown

    public var id: String { rawValue }

    public var requiresConfirmation: Bool {
        [.emptyTrash, .logOut, .restart, .shutDown].contains(self)
    }
}

public enum ShortcutScriptKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case shell, appleScript, javaScript

    public var id: String { rawValue }
}

/// One global-shortcut binding. Field names are kept from the legacy app
/// so existing `launch_bindings.json` files import without changes.
public struct LaunchBinding: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    /// App path, Shortcuts name, system action raw value, or script source.
    public var payload: String
    public var isEnabled: Bool
    public var kind: ShortcutActionKind
    public var scriptKind: ShortcutScriptKind?
    /// `.ssh` bindings only: which app opens the session.
    public var sshOpener: SSHOpener?
    /// `.ssh` bindings opened in VS Code: the remote folder to open.
    public var sshRemotePath: String?

    public var hotkeyName: String { "launch_\(id.uuidString)" }

    public init(
        id: UUID = UUID(), name: String, payload: String, isEnabled: Bool = true,
        kind: ShortcutActionKind, scriptKind: ShortcutScriptKind? = nil,
        sshOpener: SSHOpener? = nil, sshRemotePath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.payload = payload
        self.isEnabled = isEnabled
        self.kind = kind
        self.scriptKind = scriptKind
        self.sshOpener = sshOpener
        self.sshRemotePath = sshRemotePath
    }

    private enum CodingKeys: String, CodingKey {
        case id, isEnabled, scriptKind, sshOpener, sshRemotePath
        case name = "appName"
        case payload = "appBundlePath"
        case kind = "actionKind"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        payload = try c.decode(String.self, forKey: .payload)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        kind = try c.decodeIfPresent(ShortcutActionKind.self, forKey: .kind) ?? .application
        scriptKind = try c.decodeIfPresent(ShortcutScriptKind.self, forKey: .scriptKind)
        sshOpener = try c.decodeIfPresent(SSHOpener.self, forKey: .sshOpener)
        sshRemotePath = try c.decodeIfPresent(String.self, forKey: .sshRemotePath)
    }
}

public struct ShortcutExecutionSpec: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public extension LaunchBinding {
    /// Command-line invocation for shortcut and script bindings; nil for the
    /// kinds that are handled in-process (apps and system actions).
    var executionSpec: ShortcutExecutionSpec? {
        switch kind {
        case .application, .system:
            return nil
        case .ssh:
            return sshSpec
        case .shortcut:
            return ShortcutExecutionSpec(executable: "/usr/bin/shortcuts", arguments: ["run", payload])
        case .script:
            switch scriptKind ?? .shell {
            case .shell:
                return ShortcutExecutionSpec(executable: "/bin/zsh", arguments: ["-lc", payload])
            case .appleScript:
                return ShortcutExecutionSpec(executable: "/usr/bin/osascript", arguments: ["-e", payload])
            case .javaScript:
                return ShortcutExecutionSpec(executable: "/usr/bin/osascript", arguments: ["-l", "JavaScript", "-e", payload])
            }
        }
    }

    /// VS Code's CLI lives inside the app bundle and is often not on PATH.
    static let vsCodeBinary = "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"

    private var sshSpec: ShortcutExecutionSpec? {
        let alias = payload.trimmingCharacters(in: .whitespaces)
        guard !alias.isEmpty else { return nil }
        switch sshOpener ?? .terminal {
        case .terminal:
            return ShortcutExecutionSpec(executable: "/usr/bin/osascript", arguments: ["-e", Self.terminalScript(alias: alias)])
        case .visualStudioCode:
            let path = (sshRemotePath?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? "~"
            return ShortcutExecutionSpec(
                executable: Self.vsCodeBinary,
                arguments: ["--remote", "ssh-remote+\(alias)", path]
            )
        }
    }

    /// AppleScript that opens a new Terminal window and runs ssh in it.
    /// An alias is a shell word here, so anything that is not a plain host
    /// token is rejected rather than quoted into the script.
    static func terminalScript(alias: String) -> String {
        """
        tell application "Terminal"
        \tactivate
        \tdo script "ssh \(alias)"
        end tell
        """
    }

    /// Host aliases come from the user's ssh config or are typed by hand;
    /// keep them to characters that cannot break out of the AppleScript string
    /// or add ssh options.
    static func isValidHostAlias(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 255, !trimmed.hasPrefix("-") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_@")
        return trimmed.unicodeScalars.allSatisfy(allowed.contains)
    }
}
