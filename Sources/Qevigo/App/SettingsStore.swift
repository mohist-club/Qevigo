import AppKit
import Combine
import QevigoCore

/// Single source of truth for everything the user can configure. Views and
/// services read and write through this object, so two screens can never
/// overwrite each other with stale copies.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var preferences: AppPreferences {
        didSet {
            guard preferences != oldValue else { return }
            I18n.current = preferences.interfaceLanguage
            scheduleSave(StoreFile.preferences) { [files, preferences] in files.save(preferences, to: StoreFile.preferences) }
        }
    }

    @Published var translation: TranslationSettings {
        didSet {
            guard translation != oldValue else { return }
            scheduleSave(StoreFile.translation) { [files, translation] in files.save(translation, to: StoreFile.translation) }
        }
    }

    @Published var bindings: [LaunchBinding] {
        didSet {
            guard bindings != oldValue else { return }
            scheduleSave(StoreFile.bindings) { [files, bindings] in files.save(bindings, to: StoreFile.bindings) }
            onBindingsChanged?()
        }
    }

    @Published private(set) var benchmarks: [ProviderID: BenchmarkResult]
    /// Bumped whenever an API key changes so views re-evaluate availability.
    @Published private(set) var credentialRevision = 0

    let files: JSONFileStore
    let secrets: SecretStoring
    var onBindingsChanged: (() -> Void)?
    var onCredentialsChanged: ((ProviderID) -> Void)?

    private var pendingSaves: [String: (task: Task<Void, Never>, action: () -> Void)] = [:]

    init(files: JSONFileStore, secrets: SecretStoring) {
        self.files = files
        self.secrets = secrets
        preferences = files.load(AppPreferences.self, from: StoreFile.preferences) ?? AppPreferences()
        translation = files.load(TranslationSettings.self, from: StoreFile.translation) ?? TranslationSettings()
        bindings = files.load([LaunchBinding].self, from: StoreFile.bindings) ?? []
        let saved = files.load([BenchmarkResult].self, from: StoreFile.benchmarks) ?? []
        benchmarks = Dictionary(saved.map { ($0.provider, $0) }, uniquingKeysWith: { _, latest in latest })
        I18n.current = preferences.interfaceLanguage
    }

    // MARK: Providers

    func apiKey(for id: ProviderID) -> String { secrets.secret(for: id) ?? "" }

    func setAPIKey(_ value: String, for id: ProviderID) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let hadKey = !apiKey(for: id).isEmpty
        secrets.setSecret(trimmed, for: id)
        // Entering a key for the first time switches the service on.
        if !hadKey, !trimmed.isEmpty {
            translation.update(id) { $0.isEnabled = true }
        }
        credentialRevision += 1
        onCredentialsChanged?(id)
    }

    func isAvailable(_ id: ProviderID) -> Bool {
        _ = credentialRevision
        return translation.isAvailable(id, secrets: secrets)
    }

    var availableProviders: [ProviderID] {
        _ = credentialRevision
        return translation.availableProviders(secrets: secrets)
    }

    /// The service to use right now: the saved default if usable, else the
    /// first usable one by priority.
    var effectiveProvider: ProviderID? {
        let available = availableProviders
        if available.contains(translation.defaultProvider) { return translation.defaultProvider }
        return translation.failover.order.first { available.contains($0) } ?? available.first
    }

    func record(_ result: BenchmarkResult) {
        benchmarks[result.provider] = result
        files.save(Array(benchmarks.values), to: StoreFile.benchmarks)
    }

    // MARK: Import from the legacy app

    struct ImportSummary {
        var services = 0
        var keys = 0
        var shortcuts = 0
    }

    func importLegacy(_ snapshot: LegacyImport.Snapshot) -> ImportSummary {
        var summary = ImportSummary()
        if let imported = snapshot.translation {
            translation = imported
            summary.services = ProviderID.allCases.filter { imported.settings(for: $0).isEnabled }.count
        }
        if var imported = snapshot.preferences {
            imported.translateShortcutEnabled = preferences.translateShortcutEnabled
            preferences = imported
        }
        for (id, key) in snapshot.apiKeys {
            setAPIKey(key, for: id)
            summary.keys += 1
        }
        for binding in snapshot.bindings where !bindings.contains(where: { $0.id == binding.id }) {
            bindings.append(binding)
            summary.shortcuts += 1
        }
        for (key, value) in snapshot.shortcuts { UserDefaults.standard.set(value, forKey: key) }
        onBindingsChanged?()
        return summary
    }

    // MARK: Persistence

    private func scheduleSave(_ key: String, action: @escaping () -> Void) {
        pendingSaves[key]?.task.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            action()
            self?.pendingSaves[key] = nil
        }
        pendingSaves[key] = (task, action)
    }

    /// Writes any debounced changes immediately (called on quit).
    func flush() {
        for (_, pending) in pendingSaves {
            pending.task.cancel()
            pending.action()
        }
        pendingSaves.removeAll()
    }

    func resetAll() {
        pendingSaves.values.forEach { $0.task.cancel() }
        pendingSaves.removeAll()
        for id in ProviderID.allCases { secrets.setSecret(nil, for: id) }
        files.removeAll()
        preferences = AppPreferences()
        translation = TranslationSettings()
        bindings = []
        benchmarks = [:]
        credentialRevision += 1
        files.save(preferences, to: StoreFile.preferences)
        files.save(translation, to: StoreFile.translation)
    }
}
