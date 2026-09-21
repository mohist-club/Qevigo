import Foundation

public enum ShortcutActionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case application, shortcut, system, script

    public var id: String { rawValue }
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

    public var hotkeyName: String { "launch_\(id.uuidString)" }

    public init(
        id: UUID = UUID(), name: String, payload: String, isEnabled: Bool = true,
        kind: ShortcutActionKind, scriptKind: ShortcutScriptKind? = nil
    ) {
        self.id = id
        self.name = name
        self.payload = payload
        self.isEnabled = isEnabled
        self.kind = kind
        self.scriptKind = scriptKind
    }

    private enum CodingKeys: String, CodingKey {
        case id, isEnabled, scriptKind
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
}
