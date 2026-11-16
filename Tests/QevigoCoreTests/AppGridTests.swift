import XCTest
@testable import QevigoCore

final class AppGridTests: XCTestCase {
    private let apps = [
        AppEntry(path: "/System/Applications/Calculator.app", name: "计算器"),
        AppEntry(path: "/Applications/Safari.app", name: "Safari"),
        AppEntry(path: "/System/Applications/System Settings.app", name: "系统设置"),
        AppEntry(path: "/Applications/Visual Studio Code.app", name: "Visual Studio Code"),
        AppEntry(path: "/Applications/WeChat.app", name: "微信"),
    ]

    private func names(_ query: String) -> [String] {
        AppGrid.search(apps, query: query).map(\.name)
    }

    func testEmptyQueryKeepsEverythingInOrder() {
        XCTAssertEqual(names(""), apps.map(\.name))
        XCTAssertEqual(names("  "), apps.map(\.name))
    }

    func testPinyinAndInitials() {
        XCTAssertEqual(names("jsq"), ["计算器"])
        XCTAssertEqual(names("jisuan"), ["计算器"])
        XCTAssertEqual(names("weixin"), ["微信"])
        XCTAssertEqual(names("wx"), ["微信"])
    }

    func testShownNameFileNameAndWordInitials() {
        XCTAssertEqual(names("计算"), ["计算器"])
        XCTAssertEqual(names("calc"), ["计算器"])
        XCTAssertEqual(names("wechat"), ["微信"])
        XCTAssertEqual(names("vsc"), ["Visual Studio Code"])
        XCTAssertEqual(names("Studio"), ["Visual Studio Code"])
        XCTAssertEqual(names("system settings"), ["系统设置"])
    }

    func testPrefixMatchesComeFirst() {
        // "Safari" and "System Settings" start with "s"; "Visual Studio Code" only contains it.
        let result = names("s")
        XCTAssertEqual(Array(result.prefix(2)), ["Safari", "系统设置"])
        XCTAssertTrue(result.contains("Visual Studio Code"))
        XCTAssertLessThan(result.firstIndex(of: "系统设置")!, result.firstIndex(of: "Visual Studio Code")!)
    }

    func testNoMatch() {
        XCTAssertEqual(names("zzzz"), [])
    }

    func testPages() {
        XCTAssertEqual(AppGrid.pages([Int](), perPage: 35).count, 0)
        XCTAssertEqual(AppGrid.pages(Array(0..<35), perPage: 35).map(\.count), [35])
        XCTAssertEqual(AppGrid.pages(Array(0..<36), perPage: 35).map(\.count), [35, 1])
        XCTAssertEqual(AppGrid.pages(Array(0..<3), perPage: 0).count, 0)
    }

    func testGridSize() {
        XCTAssertEqual(AppGrid.size(for: CGSize(width: 1512, height: 982)), .init(columns: 7, rows: 5))
        XCTAssertEqual(AppGrid.size(for: CGSize(width: 1024, height: 700)), .init(columns: 5, rows: 4))
        XCTAssertEqual(AppGrid.size(for: CGSize(width: 1024, height: 700)).perPage, 20)
    }

    func testCatalogScansVendorFoldersSkipsHiddenAndDeduplicates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qevigo-apps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Zeta.app", "Alpha.app", "Vendor/Beta.app", ".Hidden.app", "Vendor/.Secret.app"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try Data().write(to: root.appendingPathComponent("notes.txt"))

        // The same folder listed twice must not list its apps twice.
        let entries = AppCatalog.scan(directories: [root.path, root.path])
        XCTAssertEqual(entries.map(\.name), ["Alpha", "Beta", "Zeta"])
        XCTAssertEqual(entries[1].path, root.appendingPathComponent("Vendor/Beta.app").path)
    }
}
