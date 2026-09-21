import AppKit
import Combine
import QevigoCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let env = AppEnvironment.shared
    private lazy var coordinator = TranslationCoordinator(store: env.settings, service: env.translation)
    private let hotkeys = HotkeyService()
    private var statusItem: NSStatusItem?
    private var settingsController: SettingsWindowController?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setUpStatusItem()
        rebuildMenus()

        env.settings.onBindingsChanged = { [weak self] in self?.syncHotkeys() }
        env.settings.$preferences
            .map { ($0.interfaceLanguage, $0.translateShortcutEnabled) }
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildMenus()
                self?.syncHotkeys()
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(forName: .qevigoShortcutRecording, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                if note.object as? Bool == true { self?.hotkeys.suspend() } else { self?.syncHotkeys() }
            }
        }

        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(index + 1) {
            if arguments.contains("--english") { env.settings.preferences.interfaceLanguage = .english }
            if arguments.contains("--dark") { env.settings.preferences.appearance = .dark }
            if arguments.contains("--light") { env.settings.preferences.appearance = .light }
            let controller = SettingsWindowController(env: env)
            settingsController = controller
            let directory = URL(fileURLWithPath: arguments[index + 1])
            Task { await SnapshotTool.run(directory: directory, controller: controller) }
            return
        }
        if let index = arguments.firstIndex(of: "--demo-panel"), arguments.indices.contains(index + 2) {
            if arguments.contains("--english") { env.settings.preferences.interfaceLanguage = .english }
            if arguments.contains("--dark") { env.settings.preferences.appearance = .dark }
            let text = arguments[index + 1]
            let output = URL(fileURLWithPath: arguments[index + 2])
            if let panel = coordinator.openDemo(text: text) {
                Task { await SnapshotTool.panel(panel, to: output, delay: 3.0) }
            }
            return
        }
        if UpdateChecker.isAvailable, env.settings.preferences.automaticUpdateChecks {
            Task { await UpdateChecker.check(silentWhenCurrent: true) }
        }
        if arguments.contains("--settings") { openSettings() }
        if let index = CommandLine.arguments.firstIndex(of: "--tab"),
           CommandLine.arguments.indices.contains(index + 1),
           let raw = Int(CommandLine.arguments[index + 1]), let tab = SettingsTab(rawValue: raw) {
            openSettings(tab: tab)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        env.settings.flush()
    }

    /// Launching the app again from Finder or Spotlight opens Settings, since
    /// a menu-bar-only app has no Dock icon to click.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    private func syncHotkeys() {
        hotkeys.sync(
            translateEnabled: env.settings.preferences.translateShortcutEnabled,
            bindings: env.settings.bindings
        ) { [weak self] in self?.coordinator.trigger() }
    }

    // MARK: Menus

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.statusBarIcon()
        item.button?.imagePosition = .imageOnly
        statusItem = item
    }

    private func rebuildMenus() {
        let statusMenu = NSMenu()
        statusMenu.addItem(item(tr("翻译选中文字", "Translate Selection"), #selector(translateNow)))
        statusMenu.addItem(.separator())
        statusMenu.addItem(item(tr("设置…", "Settings…"), #selector(openSettingsAction), key: ","))
        if UpdateChecker.isAvailable {
            statusMenu.addItem(item(tr("检查更新…", "Check for Updates…"), #selector(checkForUpdates)))
        }
        statusMenu.addItem(.separator())
        statusMenu.addItem(item(tr("退出 Qevigo", "Quit Qevigo"), #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
        statusItem?.menu = statusMenu

        // An accessory app has no visible menu bar, but its main menu still
        // routes the standard editing shortcuts (⌘C, ⌘V, ⌘A, ⌘Z) to text fields.
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(item(tr("设置…", "Settings…"), #selector(openSettingsAction), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(item(tr("退出 Qevigo", "Quit Qevigo"), #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
        main.addItem(submenu(appMenu, title: "Qevigo"))

        let edit = NSMenu(title: tr("编辑", "Edit"))
        edit.addItem(item(tr("撤销", "Undo"), Selector(("undo:")), key: "z", target: nil))
        edit.addItem(item(tr("重做", "Redo"), Selector(("redo:")), key: "Z", target: nil))
        edit.addItem(.separator())
        edit.addItem(item(tr("剪切", "Cut"), #selector(NSText.cut(_:)), key: "x", target: nil))
        edit.addItem(item(tr("拷贝", "Copy"), #selector(NSText.copy(_:)), key: "c", target: nil))
        edit.addItem(item(tr("粘贴", "Paste"), #selector(NSText.paste(_:)), key: "v", target: nil))
        edit.addItem(item(tr("全选", "Select All"), #selector(NSText.selectAll(_:)), key: "a", target: nil))
        main.addItem(submenu(edit, title: tr("编辑", "Edit")))

        let window = NSMenu(title: tr("窗口", "Window"))
        window.addItem(item(tr("最小化", "Minimize"), #selector(NSWindow.performMiniaturize(_:)), key: "m", target: nil))
        window.addItem(item(tr("关闭", "Close"), #selector(NSWindow.performClose(_:)), key: "w", target: nil))
        main.addItem(submenu(window, title: tr("窗口", "Window")))
        NSApp.mainMenu = main
    }

    private func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = target ?? ([#selector(translateNow), #selector(openSettingsAction), #selector(checkForUpdates)].contains(action) ? self : nil)
        return menuItem
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    @objc private func translateNow() { coordinator.trigger() }

    @objc private func openSettingsAction() { openSettings() }

    @objc private func checkForUpdates() { Task { await UpdateChecker.check(silentWhenCurrent: false) } }

    func openSettings(tab: SettingsTab? = nil) {
        if settingsController == nil { settingsController = SettingsWindowController(env: env) }
        settingsController?.show(tab: tab)
    }

    /// Monochrome ⌘ mark whose lower-right corner becomes a speech-bubble tail.
    private static func statusBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            NSImage(systemSymbolName: "command", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)?
                .draw(in: NSRect(x: 2, y: 2, width: 14, height: 14))
            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: 11.8, y: 4.1))
            tail.line(to: NSPoint(x: 16.2, y: 1.2))
            tail.line(to: NSPoint(x: 14.6, y: 6.2))
            tail.close()
            NSColor.black.setFill()
            tail.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Qevigo"
        return image
    }
}
