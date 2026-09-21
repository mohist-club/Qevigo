import Foundation

public enum AppearanceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case light, system, dark

    public var id: String { rawValue }

    public var localizedName: String {
        switch self {
        case .light: return tr("浅色", "Light")
        case .system: return tr("自动", "Auto")
        case .dark: return tr("深色", "Dark")
        }
    }
}

public struct AppPreferences: Codable, Equatable, Sendable {
    public var interfaceLanguage: InterfaceLanguage = .chinese
    public var appearance: AppearanceMode = .system
    public var glassEffectEnabled = true
    /// 0 is more solid, 1 is more transparent.
    public var glassTransparency = 0.56
    public var translateShortcutEnabled = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        interfaceLanguage = try c.decodeIfPresent(InterfaceLanguage.self, forKey: .interfaceLanguage) ?? .chinese
        appearance = try c.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? .system
        glassEffectEnabled = try c.decodeIfPresent(Bool.self, forKey: .glassEffectEnabled) ?? true
        let transparency = try c.decodeIfPresent(Double.self, forKey: .glassTransparency) ?? 0.56
        glassTransparency = min(max(transparency, 0.15), 0.85)
        translateShortcutEnabled = try c.decodeIfPresent(Bool.self, forKey: .translateShortcutEnabled) ?? true
    }
}

public struct ProviderSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var model: String
    /// Empty means "use the catalog default".
    public var baseURL: String

    public init(isEnabled: Bool = false, model: String, baseURL: String = "") {
        self.isEnabled = isEnabled
        self.model = model
        self.baseURL = baseURL
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
    }
}

public struct FailoverSettings: Codable, Equatable, Sendable {
    public var isEnabled = true
    /// Priority order. The service the user picked is always tried first; the
    /// rest follow in this order.
    public var order: [ProviderID] = ProviderID.allCases
    /// Overrides every provider's first-token timeout when set.
    public var firstTokenTimeoutOverride: Double?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        let rawOrder = try c.decodeIfPresent([String].self, forKey: .order) ?? []
        var seen = Set<ProviderID>()
        var order = rawOrder.compactMap(ProviderID.init(rawValue:)).filter { seen.insert($0).inserted }
        // Providers added in newer versions land at the end of a saved order.
        order.append(contentsOf: ProviderID.allCases.filter { !seen.contains($0) })
        self.order = order
        firstTokenTimeoutOverride = try c.decodeIfPresent(Double.self, forKey: .firstTokenTimeoutOverride)
    }
}

public struct TranslationSettings: Codable, Equatable, Sendable {
    public var defaultProvider: ProviderID = .zhipu
    public var failover = FailoverSettings()
    public var primaryLanguageCode = "ZH"
    public var secondaryLanguageCode = "EN-US"
    public var systemPrompt = PromptBuilder.defaultSystemPrompt
    private var providerTable: [String: ProviderSettings] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case defaultProvider, failover, primaryLanguageCode, secondaryLanguageCode, systemPrompt
        case providerTable = "providers"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawDefault = try c.decodeIfPresent(String.self, forKey: .defaultProvider) ?? ""
        defaultProvider = ProviderID(rawValue: rawDefault) ?? .zhipu
        failover = try c.decodeIfPresent(FailoverSettings.self, forKey: .failover) ?? FailoverSettings()
        primaryLanguageCode = try c.decodeIfPresent(String.self, forKey: .primaryLanguageCode) ?? "ZH"
        secondaryLanguageCode = try c.decodeIfPresent(String.self, forKey: .secondaryLanguageCode) ?? "EN-US"
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? PromptBuilder.defaultSystemPrompt
        providerTable = try c.decodeIfPresent([String: ProviderSettings].self, forKey: .providerTable) ?? [:]
    }

    public func settings(for id: ProviderID) -> ProviderSettings {
        providerTable[id.rawValue]
            ?? ProviderSettings(model: ProviderCatalog.descriptor(for: id).defaultModel)
    }

    public mutating func update(_ id: ProviderID, _ change: (inout ProviderSettings) -> Void) {
        var value = settings(for: id)
        change(&value)
        providerTable[id.rawValue] = value
    }

    public func model(for id: ProviderID) -> String {
        let stored = settings(for: id).model.trimmingCharacters(in: .whitespacesAndNewlines)
        return stored.isEmpty ? ProviderCatalog.descriptor(for: id).defaultModel : stored
    }

    public func baseURL(for id: ProviderID) -> String {
        let stored = settings(for: id).baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return stored.isEmpty ? ProviderCatalog.descriptor(for: id).defaultBaseURL : stored
    }

    /// A provider can serve translations when it is switched on and has the
    /// credentials or endpoint it needs.
    public func isAvailable(_ id: ProviderID, secrets: SecretStoring) -> Bool {
        guard settings(for: id).isEnabled else { return false }
        return hasRequiredConfiguration(id, secrets: secrets)
    }

    public func hasRequiredConfiguration(_ id: ProviderID, secrets: SecretStoring) -> Bool {
        let descriptor = ProviderCatalog.descriptor(for: id)
        if descriptor.requiresAPIKey {
            let key = secrets.secret(for: id)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if key.isEmpty { return false }
        }
        if descriptor.wire != .deepL, descriptor.wire != .gemini {
            if baseURL(for: id).isEmpty { return false }
        }
        if descriptor.wire != .deepL, model(for: id).isEmpty { return false }
        return true
    }

    public func availableProviders(secrets: SecretStoring) -> [ProviderID] {
        ProviderID.allCases.filter { isAvailable($0, secrets: secrets) }
    }
}
