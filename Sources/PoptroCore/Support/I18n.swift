import Foundation

public enum InterfaceLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case chinese
    case english

    public var id: String { rawValue }

    public var nativeName: String {
        switch self {
        case .chinese: return "中文"
        case .english: return "English"
        }
    }
}

/// Process-wide UI language. Views re-render through `SettingsStore`; this only
/// lets non-UI code (errors, menus) pick the right string.
public enum I18n {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedLanguage: InterfaceLanguage = .chinese

    public static var current: InterfaceLanguage {
        get { lock.withLock { storedLanguage } }
        set { lock.withLock { storedLanguage = newValue } }
    }
}

public func tr(_ chinese: String, _ english: String) -> String {
    I18n.current == .chinese ? chinese : english
}
