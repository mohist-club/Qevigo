import CoreGraphics
import Foundation

/// A folder of apps in the full-screen grid.
public struct LauncherFolder: Equatable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var apps: [AppEntry]

    public init(id: String = "folder:" + UUID().uuidString, name: String, apps: [AppEntry]) {
        self.id = id
        self.name = name
        self.apps = apps
    }
}

/// One cell of the top-level grid: an app or a folder.
public enum LauncherItem: Equatable, Sendable, Identifiable {
    case app(AppEntry)
    case folder(LauncherFolder)

    public var id: String {
        switch self {
        case .app(let app): return LauncherItem.appID(app.path)
        case .folder(let folder): return folder.id
        }
    }

    public var name: String {
        switch self {
        case .app(let app): return app.name
        case .folder(let folder): return folder.name
        }
    }

    public var app: AppEntry? {
        if case .app(let app) = self { return app }
        return nil
    }

    public var folder: LauncherFolder? {
        if case .folder(let folder) = self { return folder }
        return nil
    }

    public static func appID(_ path: String) -> String { "app:" + path }
}

/// What is saved: the order of the grid and what each folder holds, by app
/// path. Apps that are gone are dropped when it is resolved, and apps that
/// are new are added at the end.
public struct LauncherLayout: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        /// Set for an app.
        public var app: String?
        /// Set for a folder.
        public var folderID: String?
        public var name: String?
        public var apps: [String]?

        public static func app(_ path: String) -> Entry { Entry(app: path) }
        public static func folder(id: String, name: String, apps: [String]) -> Entry {
            Entry(folderID: id, name: name, apps: apps)
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public init(items: [LauncherItem]) {
        entries = items.map { item in
            switch item {
            case .app(let app): return .app(app.path)
            case .folder(let folder): return .folder(id: folder.id, name: folder.name, apps: folder.apps.map(\.path))
            }
        }
    }

    /// The grid for the apps installed now. `installed` is expected in the
    /// order new apps should be added (alphabetical).
    public func resolve(installed: [AppEntry]) -> [LauncherItem] {
        let byPath = Dictionary(installed.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var placed = Set<String>()
        var items: [LauncherItem] = []
        for entry in entries {
            if let path = entry.app {
                guard let app = byPath[path], placed.insert(path).inserted else { continue }
                items.append(.app(app))
            } else if let id = entry.folderID {
                let apps = (entry.apps ?? []).compactMap { path -> AppEntry? in
                    guard let app = byPath[path], placed.insert(path).inserted else { return nil }
                    return app
                }
                // A folder whose apps were all removed goes with them.
                guard !apps.isEmpty else { continue }
                items.append(.folder(LauncherFolder(id: id, name: entry.name ?? "", apps: apps)))
            }
        }
        for app in installed where !placed.contains(app.path) {
            items.append(.app(app))
        }
        return items
    }
}

/// Edits to the grid. Each one leaves no empty folder behind.
public enum LauncherArrangement {
    /// Moves a top-level item to `index` (its position after the move).
    public static func move(_ items: inout [LauncherItem], id: String, to index: Int) {
        guard let from = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: from)
        items.insert(item, at: min(max(index, 0), items.count))
    }

    /// Drops an app onto another app (making a folder in the target's place)
    /// or onto a folder (adding it at the end). Folders cannot go into
    /// folders. Returns the folder's id, or nil when nothing changed.
    @discardableResult
    public static func merge(_ items: inout [LauncherItem], dragged: String, onto target: String, folderName: String) -> String? {
        guard dragged != target,
              let draggedIndex = items.firstIndex(where: { $0.id == dragged }),
              let app = items[draggedIndex].app,
              items.contains(where: { $0.id == target }) else { return nil }
        items.remove(at: draggedIndex)
        let targetIndex = items.firstIndex { $0.id == target }!
        switch items[targetIndex] {
        case .app(let existing):
            let folder = LauncherFolder(name: folderName, apps: [existing, app])
            items[targetIndex] = .folder(folder)
            return folder.id
        case .folder(var folder):
            folder.apps.append(app)
            items[targetIndex] = .folder(folder)
            return folder.id
        }
    }

    /// Reorders an app inside a folder.
    public static func moveInFolder(_ items: inout [LauncherItem], folder id: String, app path: String, to index: Int) {
        update(&items, folder: id) { folder in
            guard let from = folder.apps.firstIndex(where: { $0.path == path }) else { return }
            let app = folder.apps.remove(at: from)
            folder.apps.insert(app, at: min(max(index, 0), folder.apps.count))
        }
    }

    /// Takes an app out of a folder and puts it on the grid at `index`,
    /// counted after the folder is removed if that left it empty.
    public static func takeOut(_ items: inout [LauncherItem], folder id: String, app path: String, to index: Int) {
        guard let folderIndex = items.firstIndex(where: { $0.id == id }),
              var folder = items[folderIndex].folder,
              let appIndex = folder.apps.firstIndex(where: { $0.path == path }) else { return }
        let app = folder.apps.remove(at: appIndex)
        if folder.apps.isEmpty {
            items.remove(at: folderIndex)
        } else {
            items[folderIndex] = .folder(folder)
        }
        items.insert(.app(app), at: min(max(index, 0), items.count))
    }

    public static func rename(_ items: inout [LauncherItem], folder id: String, to name: String, fallback: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        update(&items, folder: id) { $0.name = trimmed.isEmpty ? fallback : trimmed }
    }

    /// Every app, folders opened up, in grid order. What search runs over.
    public static func allApps(_ items: [LauncherItem]) -> [AppEntry] {
        items.flatMap { item -> [AppEntry] in
            switch item {
            case .app(let app): return [app]
            case .folder(let folder): return folder.apps
            }
        }
    }

    private static func update(_ items: inout [LauncherItem], folder id: String, _ change: (inout LauncherFolder) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }), var folder = items[index].folder else { return }
        change(&folder)
        items[index] = .folder(folder)
    }
}

/// Where the cells of one page sit on screen, and what a point over them means.
public struct LauncherGridMetrics: Equatable, Sendable {
    public enum Zone: Equatable, Sendable {
        /// Over the middle of a cell: dropping here merges into it.
        case center
        /// Over a cell but off its middle: dropping here takes its place.
        case side
    }

    /// Top-left corner of the first cell.
    public var origin: CGPoint
    public var cell: CGSize
    public var columns: Int
    public var rows: Int
    /// Width of the whole page; the strips at either side turn the page.
    public var pageWidth: CGFloat

    public init(origin: CGPoint, cell: CGSize, columns: Int, rows: Int, pageWidth: CGFloat) {
        self.origin = origin
        self.cell = cell
        self.columns = columns
        self.rows = rows
        self.pageWidth = pageWidth
    }

    public static let zero = LauncherGridMetrics(origin: .zero, cell: CGSize(width: 1, height: 1), columns: 1, rows: 1, pageWidth: 1)

    /// The slot on the page (0 ..< columns * rows) under a point, clamped to
    /// the grid, and whether the point is over the middle of that cell.
    public func slot(at point: CGPoint) -> (index: Int, zone: Zone) {
        let x = (point.x - origin.x) / cell.width
        let y = (point.y - origin.y) / cell.height
        let column = min(max(Int(x.rounded(.down)), 0), columns - 1)
        let row = min(max(Int(y.rounded(.down)), 0), rows - 1)
        let fx = x - CGFloat(column)
        let fy = y - CGFloat(row)
        let inside = x >= 0 && y >= 0 && x < CGFloat(columns) && y < CGFloat(rows)
        let center = inside && abs(fx - 0.5) < 0.24 && abs(fy - 0.45) < 0.3
        return (row * columns + column, center ? .center : .side)
    }

    /// -1 or 1 when the point is in the strip that turns the page that way.
    public func pageTurn(at point: CGPoint) -> Int {
        let strip = max(36, origin.x * 0.7)
        if point.x < strip { return -1 }
        if point.x > pageWidth - strip { return 1 }
        return 0
    }

    /// The centre of a slot, for drawing.
    public func center(of slot: Int) -> CGPoint {
        let column = slot % columns
        let row = slot / columns
        return CGPoint(
            x: origin.x + (CGFloat(column) + 0.5) * cell.width,
            y: origin.y + (CGFloat(row) + 0.5) * cell.height
        )
    }
}

/// What letting go of a dragged item over a point would do. The grid only
/// acts on it after the pointer rests there briefly, so passing over a
/// neighbour on the way to another cell does not push it aside.
public enum LauncherDropAction: Equatable, Sendable {
    case stay
    /// Take the place at this index; the rest shift.
    case move(to: Int)
    /// Join this app or folder (making a folder when it is an app).
    case merge(into: String)

    /// `hoveredIndex` counts across pages and may point past the last item.
    public static func decide(
        ids: [String], dragged: String, draggedIsApp: Bool,
        hoveredIndex: Int, zone: LauncherGridMetrics.Zone
    ) -> LauncherDropAction {
        guard let from = ids.firstIndex(of: dragged) else { return .stay }
        if zone == .center, draggedIsApp, ids.indices.contains(hoveredIndex), ids[hoveredIndex] != dragged {
            return .merge(into: ids[hoveredIndex])
        }
        let destination = min(max(hoveredIndex, 0), ids.count - 1)
        return destination == from ? .stay : .move(to: destination)
    }
}

public extension LauncherArrangement {
    /// Drops an app that was uninstalled, wherever it is; a folder it leaves
    /// empty goes too.
    static func remove(_ items: inout [LauncherItem], app path: String) {
        items = items.compactMap { item in
            switch item {
            case .app(let app):
                return app.path == path ? nil : item
            case .folder(var folder):
                folder.apps.removeAll { $0.path == path }
                return folder.apps.isEmpty ? nil : .folder(folder)
            }
        }
    }
}

/// Which apps the grid offers to move to the Trash.
public enum AppRemoval {
    /// Apps that are part of macOS (under /System, including Safari, which
    /// /Applications only links to) cannot be removed, nor can `protected`
    /// ones such as Qevigo itself.
    public static func isRemovable(path: String, protected: Set<String> = []) -> Bool {
        guard path.hasSuffix(".app") else { return false }
        let resolved = (path as NSString).resolvingSymlinksInPath
        if resolved.hasPrefix("/System/") || path.hasPrefix("/System/") { return false }
        let standardized = Set(protected.map { ($0 as NSString).resolvingSymlinksInPath })
        return !standardized.contains(resolved)
    }
}
