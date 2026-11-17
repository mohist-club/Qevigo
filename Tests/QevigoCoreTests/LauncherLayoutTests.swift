import XCTest
@testable import QevigoCore

final class LauncherLayoutTests: XCTestCase {
    private let a = AppEntry(path: "/Applications/A.app", name: "A")
    private let b = AppEntry(path: "/Applications/B.app", name: "B")
    private let c = AppEntry(path: "/Applications/C.app", name: "C")
    private let d = AppEntry(path: "/Applications/D.app", name: "D")

    private func ids(_ items: [LauncherItem]) -> [String] {
        items.map { item in
            switch item {
            case .app(let app): return app.name
            case .folder(let folder): return "[" + folder.apps.map(\.name).joined() + "]"
            }
        }
    }

    func testEmptyLayoutKeepsInstalledOrder() {
        XCTAssertEqual(ids(LauncherLayout().resolve(installed: [a, b, c])), ["A", "B", "C"])
    }

    func testResolveKeepsOrderDropsGoneAppsAndAppendsNewOnes() {
        let layout = LauncherLayout(entries: [
            .app(c.path),
            .folder(id: "folder:1", name: "Tools", apps: [b.path, "/Applications/Gone.app"]),
            .app("/Applications/AlsoGone.app"),
            .app(c.path), // a duplicate is ignored
        ])
        let items = layout.resolve(installed: [a, b, c, d])
        XCTAssertEqual(ids(items), ["C", "[B]", "A", "D"])
        XCTAssertEqual(items[1].folder?.name, "Tools")
        XCTAssertEqual(items[1].id, "folder:1")
    }

    func testFolderWithOnlyRemovedAppsDisappears() {
        let layout = LauncherLayout(entries: [.folder(id: "folder:1", name: "Old", apps: ["/Applications/Gone.app"]), .app(a.path)])
        XCTAssertEqual(ids(layout.resolve(installed: [a])), ["A"])
    }

    func testLayoutRoundTripsThroughItemsAndJSON() throws {
        var items = LauncherLayout().resolve(installed: [a, b, c])
        LauncherArrangement.merge(&items, dragged: LauncherItem.appID(c.path), onto: LauncherItem.appID(a.path), folderName: "F")
        let layout = LauncherLayout(items: items)
        let decoded = try JSONDecoder().decode(LauncherLayout.self, from: JSONEncoder().encode(layout))
        XCTAssertEqual(decoded, layout)
        XCTAssertEqual(decoded.resolve(installed: [a, b, c]), items)
    }

    func testMove() {
        var items = LauncherLayout().resolve(installed: [a, b, c, d])
        LauncherArrangement.move(&items, id: LauncherItem.appID(a.path), to: 2)
        XCTAssertEqual(ids(items), ["B", "C", "A", "D"])
        LauncherArrangement.move(&items, id: LauncherItem.appID(d.path), to: 0)
        XCTAssertEqual(ids(items), ["D", "B", "C", "A"])
        LauncherArrangement.move(&items, id: LauncherItem.appID(b.path), to: 99)
        XCTAssertEqual(ids(items), ["D", "C", "A", "B"])
    }

    func testMergeTwoAppsMakesAFolderWhereTheTargetWas() {
        var items = LauncherLayout().resolve(installed: [a, b, c, d])
        let id = LauncherArrangement.merge(&items, dragged: LauncherItem.appID(d.path), onto: LauncherItem.appID(b.path), folderName: "Folder")
        XCTAssertNotNil(id)
        XCTAssertEqual(ids(items), ["A", "[BD]", "C"])
        XCTAssertEqual(items[1].folder?.name, "Folder")
        XCTAssertEqual(items[1].id, id)
    }

    func testMergeIntoExistingFolderAppends() {
        var items = LauncherLayout().resolve(installed: [a, b, c, d])
        let folder = LauncherArrangement.merge(&items, dragged: LauncherItem.appID(b.path), onto: LauncherItem.appID(a.path), folderName: "F")!
        LauncherArrangement.merge(&items, dragged: LauncherItem.appID(d.path), onto: folder, folderName: "ignored")
        XCTAssertEqual(ids(items), ["[ABD]", "C"])
        XCTAssertEqual(items[0].folder?.name, "F")
    }

    func testFoldersDoNotGoIntoAnythingAndSelfMergeIsIgnored() {
        var items = LauncherLayout().resolve(installed: [a, b, c])
        let folder = LauncherArrangement.merge(&items, dragged: LauncherItem.appID(b.path), onto: LauncherItem.appID(a.path), folderName: "F")!
        let before = items
        XCTAssertNil(LauncherArrangement.merge(&items, dragged: folder, onto: LauncherItem.appID(c.path), folderName: "X"))
        XCTAssertNil(LauncherArrangement.merge(&items, dragged: LauncherItem.appID(c.path), onto: LauncherItem.appID(c.path), folderName: "X"))
        XCTAssertEqual(items, before)
    }

    func testMoveInFolderAndTakeOut() {
        var items = LauncherLayout().resolve(installed: [a, b, c, d])
        let folder = LauncherArrangement.merge(&items, dragged: LauncherItem.appID(b.path), onto: LauncherItem.appID(a.path), folderName: "F")!
        LauncherArrangement.merge(&items, dragged: LauncherItem.appID(c.path), onto: folder, folderName: "F")
        XCTAssertEqual(ids(items), ["[ABC]", "D"])

        LauncherArrangement.moveInFolder(&items, folder: folder, app: c.path, to: 0)
        XCTAssertEqual(ids(items), ["[CAB]", "D"])

        LauncherArrangement.takeOut(&items, folder: folder, app: a.path, to: 2)
        XCTAssertEqual(ids(items), ["[CB]", "D", "A"])
    }

    func testTakingOutTheLastAppRemovesTheFolder() {
        var items = LauncherLayout().resolve(installed: [a, b, c])
        let folder = LauncherArrangement.merge(&items, dragged: LauncherItem.appID(b.path), onto: LauncherItem.appID(a.path), folderName: "F")!
        LauncherArrangement.takeOut(&items, folder: folder, app: a.path, to: 0)
        LauncherArrangement.takeOut(&items, folder: folder, app: b.path, to: 1)
        XCTAssertEqual(ids(items), ["A", "B", "C"])
    }

    func testRenameFallsBackWhenEmpty() {
        var items = LauncherLayout().resolve(installed: [a, b])
        let folder = LauncherArrangement.merge(&items, dragged: LauncherItem.appID(b.path), onto: LauncherItem.appID(a.path), folderName: "F")!
        LauncherArrangement.rename(&items, folder: folder, to: "  工具  ", fallback: "文件夹")
        XCTAssertEqual(items[0].folder?.name, "工具")
        LauncherArrangement.rename(&items, folder: folder, to: "   ", fallback: "文件夹")
        XCTAssertEqual(items[0].folder?.name, "文件夹")
    }

    func testAllAppsOpensFolders() {
        var items = LauncherLayout().resolve(installed: [a, b, c])
        LauncherArrangement.merge(&items, dragged: LauncherItem.appID(c.path), onto: LauncherItem.appID(a.path), folderName: "F")
        XCTAssertEqual(LauncherArrangement.allApps(items).map(\.name), ["A", "C", "B"])
    }

    func testGridMetricsSlotsZonesAndPageTurns() {
        let metrics = LauncherGridMetrics(
            origin: CGPoint(x: 100, y: 50), cell: CGSize(width: 100, height: 100),
            columns: 7, rows: 5, pageWidth: 900
        )
        // Middle of the first cell.
        XCTAssertEqual(metrics.slot(at: CGPoint(x: 150, y: 95)).index, 0)
        XCTAssertEqual(metrics.slot(at: CGPoint(x: 150, y: 95)).zone, .center)
        // Edge of the second cell in the second row.
        XCTAssertEqual(metrics.slot(at: CGPoint(x: 205, y: 160)).index, 8)
        XCTAssertEqual(metrics.slot(at: CGPoint(x: 205, y: 160)).zone, .side)
        // Outside the grid clamps to the nearest cell and never merges.
        XCTAssertEqual(metrics.slot(at: CGPoint(x: 5000, y: 5000)).index, 34)
        XCTAssertEqual(metrics.slot(at: CGPoint(x: 5000, y: 5000)).zone, .side)
        XCTAssertEqual(metrics.slot(at: CGPoint(x: -10, y: -10)).index, 0)

        XCTAssertEqual(metrics.pageTurn(at: CGPoint(x: 10, y: 300)), -1)
        XCTAssertEqual(metrics.pageTurn(at: CGPoint(x: 890, y: 300)), 1)
        XCTAssertEqual(metrics.pageTurn(at: CGPoint(x: 450, y: 300)), 0)

        XCTAssertEqual(metrics.center(of: 8), CGPoint(x: 250, y: 200))
    }
}

final class LauncherDropAndRemovalTests: XCTestCase {
    private let ids = ["app:A", "app:B", "folder:F", "app:D"]

    func testPassingOverANeighboursEdgeMovesOnlyThere() {
        // Over the side of B: take B's place (once the pointer rests).
        XCTAssertEqual(LauncherDropAction.decide(ids: ids, dragged: "app:A", draggedIsApp: true, hoveredIndex: 1, zone: .side), .move(to: 1))
    }

    func testOverTheMiddleOfAnotherAppOrFolderMerges() {
        XCTAssertEqual(LauncherDropAction.decide(ids: ids, dragged: "app:A", draggedIsApp: true, hoveredIndex: 1, zone: .center), .merge(into: "app:B"))
        XCTAssertEqual(LauncherDropAction.decide(ids: ids, dragged: "app:D", draggedIsApp: true, hoveredIndex: 2, zone: .center), .merge(into: "folder:F"))
    }

    func testOwnCellStays() {
        XCTAssertEqual(LauncherDropAction.decide(ids: ids, dragged: "app:B", draggedIsApp: true, hoveredIndex: 1, zone: .center), .stay)
        XCTAssertEqual(LauncherDropAction.decide(ids: ids, dragged: "app:B", draggedIsApp: true, hoveredIndex: 1, zone: .side), .stay)
    }

    func testFoldersOnlyMoveAndPastTheEndMeansLast() {
        XCTAssertEqual(LauncherDropAction.decide(ids: ids, dragged: "folder:F", draggedIsApp: false, hoveredIndex: 0, zone: .center), .move(to: 0))
        XCTAssertEqual(LauncherDropAction.decide(ids: ids, dragged: "app:A", draggedIsApp: true, hoveredIndex: 20, zone: .center), .move(to: 3))
        XCTAssertEqual(LauncherDropAction.decide(ids: ids, dragged: "app:X", draggedIsApp: true, hoveredIndex: 1, zone: .side), .stay)
    }

    func testRemoveFromGridAndFolders() {
        let a = AppEntry(path: "/Applications/A.app", name: "A")
        let b = AppEntry(path: "/Applications/B.app", name: "B")
        let c = AppEntry(path: "/Applications/C.app", name: "C")
        var items: [LauncherItem] = [.app(a), .folder(LauncherFolder(id: "folder:1", name: "F", apps: [b, c]))]
        LauncherArrangement.remove(&items, app: b.path)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[1].folder?.apps.map(\.name), ["C"])
        LauncherArrangement.remove(&items, app: c.path)
        XCTAssertEqual(items.map(\.id), [LauncherItem.appID(a.path)])
        LauncherArrangement.remove(&items, app: a.path)
        XCTAssertTrue(items.isEmpty)
    }

    func testWhichAppsCanBeRemoved() throws {
        XCTAssertTrue(AppRemoval.isRemovable(path: "/Applications/Firefox.app"))
        XCTAssertTrue(AppRemoval.isRemovable(path: NSHomeDirectory() + "/Applications/Tool.app"))
        XCTAssertFalse(AppRemoval.isRemovable(path: "/System/Applications/Calculator.app"))
        XCTAssertFalse(AppRemoval.isRemovable(path: "/Applications/Qevigo.app", protected: ["/Applications/Qevigo.app"]))
        XCTAssertFalse(AppRemoval.isRemovable(path: "/Applications/Notes.txt"))

        // An app that only links into /System (as Safari does) is part of macOS.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qevigo-removal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent("Calculator.app")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/System/Applications/Calculator.app")
        XCTAssertFalse(AppRemoval.isRemovable(path: link.path))
    }
}
