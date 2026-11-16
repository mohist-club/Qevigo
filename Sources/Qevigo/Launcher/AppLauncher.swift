import AppKit
import QevigoCore
import SwiftUI

/// A full-screen grid of every installed app, in the manner of the Launchpad
/// that macOS 26 removed. It opens on the screen under the pointer, filters as
/// you type, and closes on Esc, a click on empty space, launching an app, or
/// switching to another app.
@MainActor
final class AppLauncher: NSObject, NSWindowDelegate {
    static let shared = AppLauncher()

    let model = LauncherModel()
    private var panel: LauncherPanel?
    private var monitor: Any?
    private var isHiding = false
    private var hasScanned = false
    /// For the screenshot tool, which may not own the key window.
    var staysOpenWhenInactive = false

    private var scrollTotal: CGFloat = 0
    private var scrollTurnedPage = false
    private var lastWheelTurn = Date.distantPast

    var isShown: Bool { panel?.isVisible == true && !isHiding }
    var contentView: NSView? { panel?.contentView }

    private override init() {
        super.init()
        model.onLaunch = { [weak self] in self?.launch($0) }
        model.onDismiss = { [weak self] in self?.hide() }
    }

    func toggle() {
        if isShown { hide() } else { show() }
    }

    func show() {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let panel = panel ?? makePanel()
        self.panel = panel
        isHiding = false

        refreshApps()
        model.reset(grid: AppGrid.size(for: screen.frame.size))
        model.appeared = false
        panel.setFrame(screen.frame, display: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        installMonitor()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
        withAnimation(.easeOut(duration: 0.24)) { model.appeared = true }
        Task { @MainActor [weak self] in self?.model.focusRequest += 1 }
    }

    func hide() {
        guard let panel, panel.isVisible, !isHiding else { return }
        isHiding = true
        removeMonitor()
        withAnimation(.easeIn(duration: 0.16)) { model.appeared = false }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // show() may have run again while this faded out.
                guard let self, self.isHiding else { return }
                panel.orderOut(nil)
                self.isHiding = false
            }
        })
    }

    func windowDidResignKey(_ notification: Notification) {
        if isShown, !staysOpenWhenInactive { hide() }
    }

    // MARK: Apps

    /// The first open scans synchronously so the grid is never empty; later
    /// opens show the last list at once and pick up newly installed apps in
    /// the background.
    private func refreshApps() {
        guard hasScanned else {
            model.setApps(AppCatalog.scan())
            hasScanned = true
            return
        }
        Task.detached(priority: .userInitiated) {
            let apps = AppCatalog.scan()
            await MainActor.run { AppLauncher.shared.model.setApps(apps) }
        }
    }

    private func launch(_ entry: AppEntry) {
        hide()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: entry.path), configuration: configuration) { _, error in
            guard let error else { return }
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                NSAlert(error: error).runModal()
            }
        }
    }

    // MARK: Window

    private func makePanel() -> LauncherPanel {
        let frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let panel = LauncherPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Above the Dock and the menu bar, as Launchpad was.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.isMovable = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.delegate = self

        let blur = NSVisualEffectView(frame: frame)
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active

        // The blur alone leaves bright wallpapers too busy for white labels.
        let dim = NSView(frame: frame)
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        dim.autoresizingMask = [.width, .height]
        blur.addSubview(dim)

        let hosting = NSHostingView(rootView: LauncherView(model: model))
        hosting.sizingOptions = []
        hosting.frame = frame
        hosting.autoresizingMask = [.width, .height]
        blur.addSubview(hosting)

        panel.contentView = blur
        return panel
    }

    // MARK: Keys and scrolling

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, event.window === panel else { return event }
                return self.handle(event) ? nil : event
            }
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// True when the event was used here and should go no further.
    private func handle(_ event: NSEvent) -> Bool {
        if event.type == .scrollWheel {
            handleScroll(event)
            return true
        }
        // While an input method is composing (pinyin, for one), Return, Esc
        // and the arrows pick and dismiss candidates; leave them to it.
        if let editor = panel?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) { return false }

        switch event.keyCode {
        case 53: // Esc: clear the search first, then close.
            if model.query.isEmpty { hide() } else { model.query = "" }
        case 36, 76: model.activateSelection()
        case 123: model.move(columns: -1, rows: 0)
        case 124: model.move(columns: 1, rows: 0)
        case 125: model.move(columns: 0, rows: 1)
        case 126: model.move(columns: 0, rows: -1)
        default:
            // Typing goes to the search field even after a click took focus away.
            guard !(panel?.firstResponder is NSTextView), let characters = event.characters, !characters.isEmpty,
                  characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { return false }
            model.query += characters
            model.focusRequest += 1
        }
        return true
    }

    /// A trackpad swipe turns one page per gesture; a mouse wheel turns one
    /// page per notch, no faster than four a second.
    private func handleScroll(_ event: NSEvent) {
        if event.hasPreciseScrollingDeltas {
            if event.phase == .began || event.phase == .mayBegin {
                scrollTotal = 0
                scrollTurnedPage = false
            }
            guard event.momentumPhase.isEmpty, !scrollTurnedPage else { return }
            scrollTotal += abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
            if abs(scrollTotal) > 40 {
                model.turnPage(scrollTotal > 0 ? -1 : 1)
                scrollTurnedPage = true
            }
        } else {
            let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
            guard delta != 0, Date().timeIntervalSince(lastWheelTurn) > 0.25 else { return }
            lastWheelTurn = Date()
            model.turnPage(delta > 0 ? -1 : 1)
        }
    }
}

/// Borderless panels refuse key status by default, and the search field needs it.
/// As a non-activating panel it takes the keyboard without pulling Qevigo in
/// front, so the app you launch comes forward on its own.
final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class LauncherModel: ObservableObject {
    @Published private(set) var results: [AppEntry] = []
    @Published var query = "" {
        didSet { if query != oldValue { refilter() } }
    }
    @Published var page = 0
    /// Index into `results`. Nothing is highlighted until you type or use the arrows.
    @Published var selection: Int?
    @Published var appeared = false
    /// Bumped to put the cursor back in the search field.
    @Published var focusRequest = 0
    @Published private(set) var grid = AppGrid.Size(columns: 7, rows: 5)

    var onLaunch: (AppEntry) -> Void = { _ in }
    var onDismiss: () -> Void = {}

    private var apps: [AppEntry] = []
    private var icons: [String: NSImage] = [:]

    var pages: [[AppEntry]] { AppGrid.pages(results, perPage: grid.perPage) }
    var pageCount: Int { max(1, Int((Double(results.count) / Double(grid.perPage)).rounded(.up))) }
    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    func reset(grid: AppGrid.Size) {
        self.grid = grid
        page = 0
        query = ""
        refilter()
    }

    func setApps(_ apps: [AppEntry]) {
        guard apps != self.apps else { return }
        self.apps = apps
        refilter()
    }

    func icon(for entry: AppEntry) -> NSImage {
        if let icon = icons[entry.path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: entry.path)
        icon.size = NSSize(width: 256, height: 256)
        icons[entry.path] = icon
        return icon
    }

    func launch(_ entry: AppEntry) { onLaunch(entry) }

    func move(columns: Int, rows: Int) {
        guard !results.isEmpty else { return }
        guard let current = selection else {
            // The first arrow press highlights the first app on this page.
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

    func activateSelection() {
        guard let index = selection ?? (isSearching && !results.isEmpty ? 0 : nil), results.indices.contains(index) else { return }
        launch(results[index])
    }

    private func select(_ index: Int) {
        selection = index
        page = index / grid.perPage
    }

    private func refilter() {
        results = AppGrid.search(apps, query: query)
        if isSearching {
            // Return opens the best match, and results start on the first page.
            selection = results.isEmpty ? nil : 0
            page = 0
        } else {
            selection = nil
        }
        page = min(page, pageCount - 1)
    }
}
