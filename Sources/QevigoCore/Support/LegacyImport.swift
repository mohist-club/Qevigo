import Foundation

/// Reads the configuration of the original Poptro (v1.x) so users can carry
/// their services, API keys, shortcuts and preferences over.
public enum LegacyImport {
    public static let legacyBundleID = "com.menubartranslator.app"

    public struct Snapshot {
        public var translation: TranslationSettings?
        public var preferences: AppPreferences?
        public var bindings: [LaunchBinding] = []
        public var apiKeys: [ProviderID: String] = [:]
        /// `KeyboardShortcuts_*` values (JSON strings) keyed by their UserDefaults key.
        public var shortcuts: [String: String] = [:]

        public var isEmpty: Bool {
            translation == nil && preferences == nil && bindings.isEmpty && apiKeys.isEmpty
        }
    }

    public static func load(
        supportDirectory: URL = AppPaths.poptroSupportDirectory,
        defaults: [String: Any]? = UserDefaults.standard.persistentDomain(forName: legacyBundleID)
    ) -> Snapshot {
        var snapshot = Snapshot()
        snapshot.translation = read(supportDirectory, "translation_settings.json").flatMap(translation(fromLegacyJSON:))
        snapshot.preferences = read(supportDirectory, "app_preferences.json").flatMap(preferences(fromLegacyJSON:))
        snapshot.bindings = read(supportDirectory, "launch_bindings.json")
            .flatMap { try? JSONDecoder().decode([LaunchBinding].self, from: $0) } ?? []

        guard let defaults else { return snapshot }
        for provider in ProviderID.allCases {
            let key = "com.menubartranslator.local.\(provider.rawValue)-api-key"
            guard let stored = defaults[key] as? String else { continue }
            let clear = EncryptedFileSecretStore.decrypt(stored, salt: "com.menubartranslator.local.v1", prefix: "v1:") ?? stored
            if !clear.isEmpty { snapshot.apiKeys[provider] = clear }
        }
        for (key, value) in defaults where key.hasPrefix("KeyboardShortcuts_") {
            if let text = value as? String { snapshot.shortcuts[key] = text }
        }
        return snapshot
    }

    static func translation(fromLegacyJSON data: Data) -> TranslationSettings? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var settings = TranslationSettings()

        let configured = Set((json["configuredProviders"] as? [String] ?? []).compactMap(ProviderID.init(rawValue:)))
        if let raw = json["provider"] as? String, let provider = ProviderID(rawValue: raw) {
            settings.defaultProvider = provider
        }

        let models: [ProviderID: String?] = [
            .openai: json["model"] as? String,
            .zhipu: json["zhipuModel"] as? String,
            .groq: json["groqModel"] as? String,
            .google: json["googleModel"] as? String,
            .ollama: json["ollamaModel"] as? String
        ]
        let defaultProvider = settings.defaultProvider
        for provider in [ProviderID.zhipu, .openai, .deepl, .groq, .google, .ollama] {
            settings.update(provider) { value in
                // The original treated a default Ollama as configured.
                value.isEnabled = configured.contains(provider) || (provider == defaultProvider && provider == .ollama)
                if let model = models[provider] ?? nil, !model.isEmpty { value.model = model }
                if provider == .ollama, let url = json["ollamaBaseURL"] as? String { value.baseURL = url }
            }
        }
        if let prompt = json["customSystemPrompt"] as? String, !prompt.isEmpty { settings.systemPrompt = prompt }
        if let primary = json["primaryLanguageCode"] as? String { settings.primaryLanguageCode = primary }
        if let secondary = json["secondaryLanguageCode"] as? String { settings.secondaryLanguageCode = secondary }
        return settings
    }

    static func preferences(fromLegacyJSON data: Data) -> AppPreferences? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var preferences = AppPreferences()
        if let raw = json["interfaceLanguage"] as? String, let language = InterfaceLanguage(rawValue: raw) {
            preferences.interfaceLanguage = language
        }
        if let raw = json["appearanceMode"] as? String, let mode = AppearanceMode(rawValue: raw) {
            preferences.appearance = mode
        }
        if let glass = json["glassEffectEnabled"] as? Bool { preferences.glassEffectEnabled = glass }
        if let value = json["glassTransparency"] as? Double {
            preferences.glassTransparency = min(max(value, 0.15), 0.85)
        }
        if let updates = json["automaticUpdateChecks"] as? Bool { preferences.automaticUpdateChecks = updates }
        return preferences
    }

    private static func read(_ directory: URL, _ name: String) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(name))
    }
}
