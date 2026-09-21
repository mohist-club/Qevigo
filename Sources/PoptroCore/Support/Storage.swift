import Foundation

public enum AppPaths {
    /// `~/Library/Application Support/Poptro`
    public static var legacySupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Poptro", isDirectory: true)
    }

    /// Data of this app lives in a `v2` subfolder so it never overwrites the
    /// files of the original Poptro if both are installed.
    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["POPTRO_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return legacySupportDirectory.appendingPathComponent("v2", isDirectory: true)
    }
}

/// Small atomic JSON persistence used for settings, bindings and benchmarks.
public final class JSONFileStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()

    public init(directory: URL = AppPaths.supportDirectory) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func url(for filename: String) -> URL {
        directory.appendingPathComponent(filename)
    }

    public func load<T: Decodable>(_ type: T.Type, from filename: String) -> T? {
        lock.withLock {
            guard let data = try? Data(contentsOf: url(for: filename)) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
    }

    public func save<T: Encodable>(_ value: T, to filename: String) {
        lock.withLock {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(value) else { return }
            try? data.write(to: url(for: filename), options: .atomic)
        }
    }

    public func remove(_ filename: String) {
        lock.withLock { try? FileManager.default.removeItem(at: url(for: filename)) }
    }

    public func removeAll() {
        lock.withLock {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }
}

public enum StoreFile {
    public static let preferences = "app_preferences.json"
    public static let translation = "translation_settings.json"
    public static let bindings = "launch_bindings.json"
    public static let benchmarks = "provider_benchmarks.json"
    public static let panelFrame = "panel_frame.json"
    public static let secrets = "secrets.json"
}
