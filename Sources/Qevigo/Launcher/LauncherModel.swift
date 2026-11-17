import AppKit
import QevigoCore
import SwiftUI

/// State of the full-screen grid: the arrangement (order and folders), what
/// a search shows, the open folder and a drag in progress. Positions are in
/// the launcher's own coordinate space, which is the screen it is on with
/// the origin at the top left.
@MainActor
final class LauncherModel: ObservableObject {
    @Published private(set) var items: [LauncherItem] = []
    /// What the grid shows: the arrangement, or matching apps while searching.
    @Published private(set) var results: [LauncherItem] = []
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            if isSearching { isEditing = false }
            refilter()
        }
    }
    @Published var page = 0
    /// Index into `results`. Nothing is highlighted until you type or use the arrows.
    @Published var selection: Int?
    @Published var appeared = false
    /// Bumped to put the cursor back in the search field.
    @Published var focusRequest = 0
    @Published private(set) var grid = AppGrid.Size(columns: 7, rows: 5)
    @Published private(set) var screen = CGSize(width: 1200, height: 800)
    @Published private(set) var openFolderID: String?
    @Published private(set) var draggingID: String?
    @Published private(set) var dragPoint: CGPoint = .zero
    /// The item a dragged app will join when released.
    @Published private(set) var mergeTargetID: String?
    /// A drag from an open folder that has left the folder.
    @Published private(set) var dragIsOutsideFolder = false
    /// Icons wiggle and removable apps show a delete badge.
    @Published private(set) var isEditing = false
    /// An app waiting for the user to confirm moving it to the Trash.
    @Published private(set) var pendingRemoval: PendingRemoval?

    struct PendingRemoval: Equatable {
        let app: AppEntry
        let isRunning: Bool
    }

    var onLaunch: (AppEntry) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    var onLayoutChange: (LauncherLayout) -> Void = { _ in }
    var onRemove: (AppEntry) -> Void = { _ in }
    var isRunning: (AppEntry) -> Bool = { _ in false }

    static let shuffle = Animation.spring(response: 0.32, dampingFraction: 0.86)
    static var folderName: String { tr("文件夹", "Folder") }

    private var installed: [AppEntry] = []
    /// A rescan that finished mid-drag, applied once the drag ends.
    private var pendingInstalled: [AppEntry]?
    private var layout = LauncherLayout()
    private var icons: [String: NSImage] = [:]
    private var pendingMergeTarget: String?
    private var mergeWork: DispatchWorkItem?
    private var pendingTurn = 0
    private var turnWork: DispatchWorkItem?
    private var pendingMove: Int?
    private var moveWork: DispatchWorkItem?
    /// Editing was entered by holding Option and ends when it is let go.
    private var editingByOption = false
    /// Set by a long press, so letting go does not also open the app.
    private var suppressNextTap = false

    var pageCount: Int { max(1, Int((Double(results.count) / Double(grid.perPage)).rounded(.up))) }
    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    var openFolder: LauncherFolder? {
        guard let openFolderID else { return nil }
        return items.first { $0.id == openFolderID }?.folder
    }

    // MARK: Geometry

    var searchTop: CGFloat { max(40, screen.height * 0.055) }
    var metrics: LauncherGridMetrics { Self.metrics(screen: screen, grid: grid) }
    var iconSide: CGFloat { min(metrics.cell.width * 0.55, metrics.cell.height * 0.62, 128) }

    static func metrics(screen: CGSize, grid: AppGrid.Size) -> LauncherGridMetrics {
        let top = max(40, screen.height * 0.055)
        let gridTop = top + 30 + 28
        let gridHeight = max(200, screen.height - gridTop - 72)
        let inset = max(40, screen.width * 0.09)
        return LauncherGridMetrics(
            origin: CGPoint(x: inset, y: gridTop),
            cell: CGSize(width: (screen.width - inset * 2) / CGFloat(grid.columns), height: gridHeight / CGFloat(grid.rows)),
            columns: grid.columns, rows: grid.rows, pageWidth: screen.width
        )
    }

    struct FolderGeometry {
        let frame: CGRect
        let metrics: LauncherGridMetrics
        let titleHeight: CGFloat
    }

    /// An open folder: a panel in the middle of the screen with its apps in
    /// cells the size of the main grid's.
    func folderGeometry(appCount: Int) -> FolderGeometry {
        let cell = metrics.cell
        let columns = min(grid.columns, 6, max(3, appCount))
        let maxRows = max(1, Int((screen.height * 0.72 - 90) / cell.height))
        let rows = min(maxRows, max(1, Int((Double(appCount) / Double(columns)).rounded(.up))))
        let padding: CGFloat = 24
        let titleHeight: CGFloat = 64
        let size = CGSize(width: CGFloat(columns) * cell.width + padding * 2, height: titleHeight + CGFloat(rows) * cell.height + padding)
        let frame = CGRect(x: (screen.width - size.width) / 2, y: (screen.height - size.height) / 2, width: size.width, height: size.height)
        let metrics = LauncherGridMetrics(
            origin: CGPoint(x: frame.minX + padding, y: frame.minY + titleHeight),
            cell: cell, columns: columns, rows: rows, pageWidth: screen.width
        )
        return FolderGeometry(frame: frame, metrics: metrics, titleHeight: titleHeight)
    }

    func updateScreen(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != screen else { return }
        screen = size
    }

    // MARK: Content

    func reset(grid: AppGrid.Size) {
        self.grid = grid
        page = 0
        openFolderID = nil
        draggingID = nil
        isEditing = false
        editingByOption = false
        pendingRemoval = nil
        cancelMerge()
        cancelTurn()
        cancelMove()
        query = ""
        refilter()
    }

    func setLayout(_ layout: LauncherLayout) {
        self.layout = layout
        items = layout.resolve(installed: installed)
        refilter()
    }

    func setApps(_ apps: [AppEntry]) {
        guard draggingID == nil else {
            pendingInstalled = apps
            return
        }
        guard apps != installed else { return }
        installed = apps
        items = layout.resolve(installed: apps)
        refilter()
    }

    func item(withID id: String) -> LauncherItem? {
        if let item = items.first(where: { $0.id == id }) { return item }
        for case .folder(let folder) in items {
            if let app = folder.apps.first(where: { LauncherItem.appID($0.path) == id }) { return .app(app) }
        }
        return nil
    }

    func icon(for entry: AppEntry) -> NSImage {
        if let icon = icons[entry.path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: entry.path)
        icon.size = NSSize(width: 256, height: 256)
        icons[entry.path] = icon
        return icon
    }

    // MARK: Opening

    func launch(_ entry: AppEntry) { onLaunch(entry) }

    func activate(_ item: LauncherItem) {
        switch item {
        case .app(let app): launch(app)
        case .folder(let folder): openFolder(folder.id)
        }
    }

    func activateSelection() {
        guard let index = selection ?? (isSearching && !results.isEmpty ? 0 : nil), results.indices.contains(index) else { return }
        activate(results[index])
    }

    func openFolder(_ id: String) {
        withAnimation(.easeOut(duration: 0.18)) { openFolderID = id }
    }

    func closeFolder() {
        guard openFolderID != nil else { return }
        withAnimation(.easeIn(duration: 0.15)) { openFolderID = nil }
    }

    func renameFolder(_ id: String, to name: String) {
        let before = items
        LauncherArrangement.rename(&items, folder: id, to: name, fallback: Self.folderName)
        guard items != before else { return }
        if !isSearching { results = items }
        persist()
    }

    // MARK: Editing and removing

    /// A tap that should open something; false right after a long press.
    func consumeTap() -> Bool {
        if suppressNextTap {
            suppressNextTap = false
            return false
        }
        return true
    }

    func longPressed() {
        suppressNextTap = true
        beginEditing()
    }

    func beginEditing() {
        guard !isEditing, !isSearching else { return }
        editingByOption = false
        withAnimation(.easeOut(duration: 0.15)) { isEditing = true }
    }

    func endEditing() {
        guard isEditing else { return }
        editingByOption = false
        withAnimation(.easeOut(duration: 0.15)) { isEditing = false }
    }

    /// Holding Option shows the delete badges until it is let go, as in Launchpad.
    func optionChanged(isDown: Bool) {
        if isDown, !isEditing, !isSearching {
            beginEditing()
            editingByOption = true
        } else if !isDown, editingByOption {
            endEditing()
        }
    }

    func canRemove(_ app: AppEntry) -> Bool {
        AppRemoval.isRemovable(path: app.path, protected: [Bundle.main.bundlePath])
    }

    func requestRemoval(_ app: AppEntry) {
        guard canRemove(app) else { return }
        // Clicking the badge is a decision; Option no longer needs holding.
        editingByOption = false
        withAnimation(.easeOut(duration: 0.15)) { pendingRemoval = PendingRemoval(app: app, isRunning: isRunning(app)) }
    }

    func cancelRemoval() {
        withAnimation(.easeIn(duration: 0.12)) { pendingRemoval = nil }
    }

    func confirmRemoval() {
        guard let removal = pendingRemoval else { return }
        pendingRemoval = nil
        onRemove(removal.app)
    }

    /// The app is in the Trash: take it off the grid and out of its folder.
    func didRemove(path: String) {
        installed.removeAll { $0.path == path }
        withAnimation(Self.shuffle) {
            LauncherArrangement.remove(&items, app: path)
            if isSearching {
                results.removeAll { $0.app?.path == path }
            } else {
                results = items
            }
        }
        page = min(page, pageCount - 1)
        persist()
    }

    /// A click on empty space backs out one step: the question, then editing,
    /// then the whole grid.
    func backgroundTapped() {
        if pendingRemoval != nil {
            cancelRemoval()
        } else if isEditing {
            endEditing()
        } else {
            onDismiss()
        }
    }

    // MARK: Keyboard

    func move(columns: Int, rows: Int) {
        guard !results.isEmpty else { return }
        guard let current = selection else {
            // The first arrow press highlights the first item on this page.
            select(min(page * grid.perPage, results.count - 1))
            return
        }
        select(min(max(current + columns + rows * grid.columns, 0), results.count - 1))
    }

    func turnPage(_ delta: Int) {
        let target = min(max(page + delta, 0), pageCount - 1)
        guard target != page else { return }
        page = target
        if selection != nil { selection = min(page * grid.perPage, results.count - 1) }
    }

    private func select(_ index: Int) {
        selection = index
        page = index / grid.perPage
    }

    // MARK: Dragging on the grid

    /// Called as an item is dragged. Over the side of another cell the item
    /// takes that place and the rest shift; held over the middle of another
    /// cell, an app is marked to join it; held at a screen edge, the page turns.
    func dragChanged(id: String, to point: CGPoint) {
        guard !isSearching, openFolderID == nil else { return }
        if draggingID == nil {
            draggingID = id
            selection = nil
            suppressNextTap = false
        }
        dragPoint = point

        let turn = metrics.pageTurn(at: point)
        if turn != 0 {
            cancelMerge()
            scheduleTurn(turn)
            return
        }
        cancelTurn()

        guard let dragged = items.first(where: { $0.id == id }) else { return }
        let hit = metrics.slot(at: point)
        // Nothing happens until the pointer rests, so crossing a neighbour on
        // the way to the middle of another app does not push that app away.
        switch LauncherDropAction.decide(
            ids: items.map(\.id), dragged: id, draggedIsApp: dragged.app != nil,
            hoveredIndex: page * grid.perPage + hit.index, zone: hit.zone
        ) {
        case .merge(let target):
            cancelMove()
            scheduleMerge(onto: target)
        case .move(let destination):
            cancelMerge()
            scheduleMove(id, to: destination)
        case .stay:
            cancelMerge()
            cancelMove()
        }
    }

    func dragEnded() {
        cancelTurn()
        if let id = draggingID, let target = mergeTargetID {
            withAnimation(Self.shuffle) {
                LauncherArrangement.merge(&items, dragged: id, onto: target, folderName: Self.folderName)
                results = items
            }
        } else if let id = draggingID, let destination = pendingMove {
            // Let go over a cell before the rest had moved: it goes there anyway.
            withAnimation(Self.shuffle) {
                LauncherArrangement.move(&items, id: id, to: destination)
                results = items
            }
        }
        cancelMerge()
        cancelMove()
        finishDrag()
    }

    // MARK: Dragging in an open folder

    func folderDragChanged(path: String, to point: CGPoint) {
        guard let folder = openFolder else { return }
        if draggingID == nil { draggingID = LauncherItem.appID(path) }
        dragPoint = point
        let geometry = folderGeometry(appCount: folder.apps.count)
        dragIsOutsideFolder = !geometry.frame.contains(point)
        guard !dragIsOutsideFolder, let from = folder.apps.firstIndex(where: { $0.path == path }) else { return }
        let destination = min(geometry.metrics.slot(at: point).index, folder.apps.count - 1)
        guard destination != from else { return }
        withAnimation(Self.shuffle) {
            LauncherArrangement.moveInFolder(&items, folder: folder.id, app: path, to: destination)
            results = items
        }
    }

    /// Released outside the folder, the app leaves it and lands on the grid
    /// where it was dropped.
    func folderDragEnded(path: String) {
        if dragIsOutsideFolder, let folder = openFolder {
            let slot = metrics.slot(at: dragPoint).index
            withAnimation(Self.shuffle) {
                openFolderID = nil
                LauncherArrangement.takeOut(&items, folder: folder.id, app: path, to: page * grid.perPage + slot)
                results = items
            }
        }
        finishDrag()
    }

    // MARK: Screenshots

    /// Puts the second and third items into a folder with the first, without
    /// saving, so the screenshot tool can show one.
    @discardableResult
    func makeDemoFolder(open: Bool) -> String? {
        guard items.count >= 3, items[0].app != nil, items[1].app != nil, items[2].app != nil else { return nil }
        let first = items[0].id
        guard let folder = LauncherArrangement.merge(&items, dragged: items[1].id, onto: first, folderName: Self.folderName) else { return nil }
        LauncherArrangement.merge(&items, dragged: items[1].id, onto: folder, folderName: Self.folderName)
        results = items
        if open { openFolderID = folder }
        return folder
    }

    /// For screenshots: editing on, and optionally the question for the
    /// first removable app.
    func demoEditing(askToRemove: Bool) {
        beginEditing()
        guard askToRemove, let app = LauncherArrangement.allApps(items).first(where: canRemove) else { return }
        pendingRemoval = PendingRemoval(app: app, isRunning: false)
    }

    // MARK: Private

    private func finishDrag() {
        draggingID = nil
        dragIsOutsideFolder = false
        persist()
        if let pending = pendingInstalled {
            pendingInstalled = nil
            setApps(pending)
        }
    }

    private func persist() {
        layout = LauncherLayout(items: items)
        onLayoutChange(layout)
    }

    private func refilter() {
        if isSearching {
            results = AppGrid.search(LauncherArrangement.allApps(items), query: query).map { .app($0) }
            // Return opens the best match, and results start on the first page.
            selection = results.isEmpty ? nil : 0
            page = 0
        } else {
            results = items
            selection = nil
        }
        page = min(page, pageCount - 1)
    }

    private func scheduleMerge(onto target: String) {
        guard pendingMergeTarget != target else { return }
        cancelMerge()
        pendingMergeTarget = target
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pendingMergeTarget == target else { return }
                withAnimation(.easeOut(duration: 0.15)) { self.mergeTargetID = target }
            }
        }
        mergeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func cancelMerge() {
        mergeWork?.cancel()
        mergeWork = nil
        pendingMergeTarget = nil
        if mergeTargetID != nil { mergeTargetID = nil }
    }

    private func scheduleTurn(_ direction: Int) {
        guard pendingTurn != direction else { return }
        cancelTurn()
        pendingTurn = direction
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pendingTurn == direction else { return }
                self.turnPage(direction)
                // Moving again while still at the edge turns another page.
                self.pendingTurn = 0
            }
        }
        turnWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
    }

    private func cancelTurn() {
        turnWork?.cancel()
        turnWork = nil
        pendingTurn = 0
    }

    private func scheduleMove(_ id: String, to destination: Int) {
        guard pendingMove != destination else { return }
        cancelMove()
        pendingMove = destination
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.draggingID == id, self.pendingMove == destination else { return }
                self.pendingMove = nil
                withAnimation(Self.shuffle) {
                    LauncherArrangement.move(&self.items, id: id, to: destination)
                    self.results = self.items
                }
            }
        }
        moveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func cancelMove() {
        moveWork?.cancel()
        moveWork = nil
        pendingMove = nil
    }
}
