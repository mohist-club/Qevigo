import CryptoKit
import Foundation
import IOKit

public protocol SecretStoring: AnyObject, Sendable {
    func secret(for provider: ProviderID) -> String?
    func setSecret(_ value: String?, for provider: ProviderID)
}

public final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private var values: [ProviderID: String] = [:]
    private let lock = NSLock()

    public init(_ initial: [ProviderID: String] = [:]) { values = initial }

    public func secret(for provider: ProviderID) -> String? { lock.withLock { values[provider] } }

    public func setSecret(_ value: String?, for provider: ProviderID) {
        lock.withLock { values[provider] = value }
    }
}

/// API keys are stored in a 0600 file, AES-GCM encrypted with a key derived
/// from this Mac's hardware UUID. This keeps keys out of plain-text config and
/// avoids the repeated Keychain prompts ad-hoc signed builds trigger. It is not
/// a substitute for the Keychain or a hardware security module.
public final class EncryptedFileSecretStore: SecretStoring, @unchecked Sendable {
    private let store: JSONFileStore
    private let lock = NSLock()
    private var cache: [String: String]

    public init(store: JSONFileStore) {
        self.store = store
        self.cache = store.load([String: String].self, from: StoreFile.secrets) ?? [:]
    }

    public func secret(for provider: ProviderID) -> String? {
        lock.withLock {
            guard let stored = cache[provider.rawValue] else { return nil }
            return Self.decrypt(stored)
        }
    }

    public func setSecret(_ value: String?, for provider: ProviderID) {
        lock.withLock {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty {
                cache.removeValue(forKey: provider.rawValue)
            } else if let encrypted = Self.encrypt(trimmed) {
                cache[provider.rawValue] = encrypted
            }
            store.save(cache, to: StoreFile.secrets)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: store.url(for: StoreFile.secrets).path
            )
        }
    }

    static func encrypt(_ value: String) -> String? {
        guard let sealed = try? AES.GCM.seal(Data(value.utf8), using: key(salt: "qevigo.v1")),
              let combined = sealed.combined else { return nil }
        return "q1:" + combined.base64EncodedString()
    }

    static func decrypt(_ value: String, salt: String = "qevigo.v1", prefix: String = "q1:") -> String? {
        guard value.hasPrefix(prefix),
              let data = Data(base64Encoded: String(value.dropFirst(prefix.count))),
              let box = try? AES.GCM.SealedBox(combined: data),
              let clear = try? AES.GCM.open(box, using: key(salt: salt)) else { return nil }
        return String(data: clear, encoding: .utf8)
    }

    /// Also used to read keys written by the legacy app (`legacy` salt).
    static func key(salt: String) -> SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: Data("\(salt)|\(machineIdentifier())".utf8)))
    }

    static func machineIdentifier() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { if service != 0 { IOObjectRelease(service) } }
        guard service != 0,
              let value = IORegistryEntryCreateCFProperty(
                service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0
              )?.takeRetainedValue() as? String else {
            return Host.current().localizedName ?? "unknown-mac"
        }
        return value
    }
}
