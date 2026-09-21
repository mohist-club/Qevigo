import AppKit
import Combine
import QevigoCore
import SwiftUI

enum SettingsTab: Int, CaseIterable {
    case general, shortcuts, services, advanced, about

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "keyboard"
        case .services: return "globe"
        case .advanced: return "slider.horizontal.3"
        case .about: return "info.circle"
        }
    }

    var title: String {
        switch self {
        case .general: return tr("通用", "General")
        case .shortcuts: return tr("快捷键", "Shortcuts")
        case .services: return tr("翻译服务", "Services")
        case .advanced: return tr("高级", "Advanced")
        case .about: return tr("关于", "About")
        }
    }
}

/// The standard macOS preferences window: an `NSTabViewController` in toolbar
/// style, exactly what system apps use. Each tab hosts a SwiftUI form and the
/// window resizes to fit the selected tab.
@MainActor
final class SettingsWindowController: NSWindowController {
    private let tabController = SettingsTabViewController()
    private let store: SettingsStore
    private var cancellables = Set<AnyCancellable>()

    init(env: AppEnvironment) {
        store = env.settings
        let window = NSWindow(contentViewController: tabController)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("QevigoSettingsWindow")
        super.init(window: window)

        tabController.configure(env: env)
        applyAppearance(store.preferences.appearance)

        store.$preferences
            .map { ($0.interfaceLanguage, $0.appearance) }
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, appearance in
                self?.applyAppearance(appearance)
                self?.tabController.refreshTitles()
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(tab: SettingsTab? = nil) {
        if let tab { tabController.select(tab, animated: false) }
        tabController.fitWindowToSelection(animated: false)
        if window?.isVisible == false { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func applyAppearance(_ mode: AppearanceMode) {
        window?.appearance = mode.nsAppearance
    }
}

@MainActor
private final class SettingsTabViewController: NSTabViewController {
    private var hostControllers: [SettingsTab: NSHostingController<AnyView>] = [:]
    private static let contentWidth: CGFloat = 640

    func configure(env: AppEnvironment) {
        tabStyle = .toolbar
        transitionOptions = []

        for tab in SettingsTab.allCases {
            let host = NSHostingController(rootView: rootView(for: tab, env: env))
            host.sizingOptions = []
            host.title = tab.title
            hostControllers[tab] = host
            let item = NSTabViewItem(viewController: host)
            item.identifier = "\(tab.rawValue)"
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            addTabViewItem(item)
        }
    }

    private func rootView(for tab: SettingsTab, env: AppEnvironment) -> AnyView {
        let store = env.settings
        switch tab {
        case .general: return AnyView(GeneralTab().environmentObject(store))
        case .shortcuts: return AnyView(ShortcutsTab().environmentObject(store))
        case .services: return AnyView(ServicesTab(health: env.translation.health).environmentObject(store))
        case .advanced: return AnyView(AdvancedTab().environmentObject(store))
        case .about: return AnyView(AboutTab().environmentObject(store))
        }
    }

    func refreshTitles() {
        for item in tabViewItems {
            guard let raw = (item.identifier as? String).flatMap(Int.init), let tab = SettingsTab(rawValue: raw) else { continue }
            item.label = tab.title
            hostControllers[tab]?.title = tab.title
        }
        if tabViewItems.indices.contains(selectedTabViewItemIndex) {
            view.window?.title = tabViewItems[selectedTabViewItemIndex].label
        }
    }

    func select(_ tab: SettingsTab, animated: Bool) {
        selectedTabViewItemIndex = tab.rawValue
    }

    override func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, willSelect: tabViewItem)
        guard let tabViewItem else { return }
        resizeWindow(for: tabViewItem, animated: view.window?.isVisible == true)
    }

    func fitWindowToSelection(animated: Bool) {
        guard tabViewItems.indices.contains(selectedTabViewItemIndex) else { return }
        resizeWindow(for: tabViewItems[selectedTabViewItemIndex], animated: animated)
    }

    private func resizeWindow(for item: NSTabViewItem, animated: Bool) {
        guard let raw = (item.identifier as? String).flatMap(Int.init),
              let tab = SettingsTab(rawValue: raw),
              let host = hostControllers[tab], let window = view.window else { return }
        let fitting = host.sizeThatFits(in: CGSize(width: Self.contentWidth, height: 10_000))
        let size = CGSize(width: Self.contentWidth, height: max(fitting.height, 120))
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: animated)
    }
}
