import Foundation
import QevigoCore

@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let files = JSONFileStore()
    let secrets: EncryptedFileSecretStore
    let settings: SettingsStore
    let translation: TranslationService

    private init() {
        secrets = EncryptedFileSecretStore(store: files)
        settings = SettingsStore(files: files, secrets: secrets)
        translation = TranslationService(secrets: secrets)
        settings.onCredentialsChanged = { [translation] id in translation.health.reset(id) }
    }
}
