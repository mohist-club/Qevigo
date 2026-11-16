import CoreGraphics
import Foundation

/// One application shown in the full-screen app grid.
public struct AppEntry: Identifiable, Equatable, Sendable {
    public let path: String
    /// What Finder shows, in the system language ("计算器", not "Calculator").
    public let name: String
    /// Lowercased strings a query is matched against: the shown name, the
    /// bundle's file name, its pinyin and the pinyin initials.
    public let searchKeys: [String]

    public var id: String { path }

    public init(path: String, name: String, fileName: String? = nil) {
        self.path = path
        self.name = name
        let file = fileName ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        searchKeys = AppGrid.searchKeys(name: name, fileName: file)
    }
}

public enum AppGrid {
    public struct Size: Equatable, Sendable {
        public let columns: Int
        public let rows: Int
        public var perPage: Int { columns * rows }

        public init(columns: Int, rows: Int) {
            self.columns = columns
            self.rows = rows
        }
    }

    /// Seven by five, as Launchpad laid it out, with fewer cells on small screens.
    public static func size(for screen: CGSize) -> Size {
        Size(columns: screen.width >= 1100 ? 7 : 5, rows: screen.height >= 760 ? 5 : 4)
    }

    public static func pages<T>(_ items: [T], perPage: Int) -> [[T]] {
        guard perPage > 0 else { return [] }
        return stride(from: 0, to: items.count, by: perPage).map { Array(items[$0..<min($0 + perPage, items.count)]) }
    }

    /// Apps whose name, file name, pinyin or initials contain the query.
    /// Prefix matches come first; otherwise the original order is kept.
    public static func search(_ apps: [AppEntry], query: String) -> [AppEntry] {
        let needle = normalized(query)
        guard !needle.isEmpty else { return apps }
        var prefix: [AppEntry] = []
        var contains: [AppEntry] = []
        for app in apps {
            if app.searchKeys.contains(where: { $0.hasPrefix(needle) }) {
                prefix.append(app)
            } else if app.searchKeys.contains(where: { $0.contains(needle) }) {
                contains.append(app)
            }
        }
        return prefix + contains
    }

    static func searchKeys(name: String, fileName: String) -> [String] {
        var keys: [String] = []
        func add(_ key: String) {
            let key = normalized(key)
            if !key.isEmpty, !keys.contains(key) { keys.append(key) }
        }
        add(name)
        add(fileName)
        for source in [name, fileName] {
            // "计算器" -> "ji suan qi"; Latin names pass through unchanged, so
            // "Visual Studio Code" also gets the initials "vsc".
            let latin = source.applyingTransform(.toLatin, reverse: false)?
                .applyingTransform(.stripDiacritics, reverse: false) ?? source
            let words = latin.lowercased().split { !$0.isLetter && !$0.isNumber }
            add(words.joined())
            if words.count > 1 { add(String(words.compactMap(\.first))) }
        }
        return keys
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }
}

/// Finds installed applications the way Launchpad did: the Applications
/// folders and one level of vendor folders inside them.
public enum AppCatalog {
    public static let defaultDirectories = [
        "/Applications", "/Applications/Utilities",
        "/System/Applications", "/System/Applications/Utilities",
        "~/Applications",
    ]

    public static func scan(directories: [String] = defaultDirectories) -> [AppEntry] {
        let fileManager = FileManager.default
        var seenPaths = Set<String>()
        var seenBundles = Set<String>()
        var entries: [AppEntry] = []

        func consider(_ path: String) {
            let resolved = (path as NSString).resolvingSymlinksInPath
            guard seenPaths.insert(resolved).inserted else { return }
            if let id = Bundle(path: path)?.bundleIdentifier, !seenBundles.insert(id).inserted { return }
            var name = fileManager.displayName(atPath: path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            entries.append(AppEntry(path: path, name: name))
        }

        for directory in directories {
            let base = (directory as NSString).expandingTildeInPath
            guard let items = try? fileManager.contentsOfDirectory(atPath: base) else { continue }
            for item in items where !item.hasPrefix(".") {
                let path = (base as NSString).appendingPathComponent(item)
                if item.hasSuffix(".app") {
                    consider(path)
                    continue
                }
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
                      let nested = try? fileManager.contentsOfDirectory(atPath: path) else { continue }
                for child in nested where child.hasSuffix(".app") && !child.hasPrefix(".") {
                    consider((path as NSString).appendingPathComponent(child))
                }
            }
        }
        return entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
