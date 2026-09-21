import AppKit
import QevigoCore

/// Checks GitHub Releases of `AppInfo.updateRepository` and offers the DMG.
/// Installation stays manual: the app is ad-hoc signed, so it cannot replace itself.
@MainActor
enum UpdateChecker {
    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let html_url: URL
        let assets: [Asset]
    }

    static var isAvailable: Bool { AppInfo.updateRepository != nil }

    static func check(silentWhenCurrent: Bool) async {
        guard let repository = AppInfo.updateRepository,
              let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.setValue("Qevigo", forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let release = try JSONDecoder().decode(Release.self, from: data)
            present(release, silentWhenCurrent: silentWhenCurrent)
        } catch {
            guard !silentWhenCurrent else { return }
            alert(tr("检查更新失败", "Update Check Failed"), error.localizedDescription)
        }
    }

    private static func present(_ release: Release, silentWhenCurrent: Bool) {
        let latest = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard latest.compare(AppInfo.version, options: .numeric) == .orderedDescending else {
            if !silentWhenCurrent {
                alert(tr("已是最新版本", "You're Up to Date"), tr("当前版本：\(AppInfo.version)", "Current version: \(AppInfo.version)"))
            }
            return
        }
        let panel = NSAlert()
        panel.messageText = tr("发现新版本 \(release.tag_name)", "Version \(release.tag_name) Is Available")
        panel.informativeText = tr(
            "当前版本：\(AppInfo.version)。下载后打开 DMG，将 App 拖到“应用程序”完成替换。",
            "Current version: \(AppInfo.version). Open the DMG and drag the app to Applications to update."
        )
        panel.addButton(withTitle: tr("下载 DMG", "Download DMG"))
        panel.addButton(withTitle: tr("稍后", "Later"))
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .alertFirstButtonReturn {
            let dmg = release.assets.first { $0.name.lowercased().hasSuffix(".dmg") }?.browser_download_url
            NSWorkspace.shared.open(dmg ?? release.html_url)
        }
    }

    private static func alert(_ title: String, _ message: String) {
        let panel = NSAlert()
        panel.messageText = title
        panel.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        panel.runModal()
    }
}
