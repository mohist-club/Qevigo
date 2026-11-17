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
    /// Order and folders, kept in the data folder beside the settings.
    private let layoutStore = JSONFileStore()
    private static let layoutFile = "launcher_layout.json"
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
        model.setLayout(layoutStore.load(LauncherLayout.self, from: Self.layoutFile) ?? LauncherLayout())
        model.onLayoutChange = { [layoutStore] layout in layoutStore.save(layout, to: AppLauncher.layoutFile) }
        model.onRemove = { [weak self] app in self?.remove(app) }
        model.isRunning = { !AppLauncher.runningInstances(of: $0).isEmpty }
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

    // MARK: Removing apps

    nonisolated static func runningInstances(of app: AppEntry) -> [NSRunningApplication] {
        let url = URL(fileURLWithPath: app.path).resolvingSymlinksInPath().standardizedFileURL
        let bundleID = Bundle(path: app.path)?.bundleIdentifier
        return NSWorkspace.shared.runningApplications.filter { running in
            if let bundleID, running.bundleIdentifier == bundleID { return true }
            return running.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == url
        }
    }

    /// Quits the app if it is running, then moves it to the Trash. Apps the
    /// user may not write to (App Store installs, owned by root) go through
    /// Finder, which asks for an administrator password itself; the grid
    /// steps aside first so that prompt is not hidden behind it.
    private func remove(_ app: AppEntry) {
        Task { @MainActor in
            let running = Self.runningInstances(of: app)
            if !running.isEmpty {
                running.forEach { $0.terminate() }
                for _ in 0..<60 where running.contains(where: { !$0.isTerminated }) {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                guard running.allSatisfy(\.isTerminated) else {
                    report(tr("「\(app.name)」没有退出，没有移到废纸篓。", "“\(app.name)” did not quit, so it was not moved to the Trash."))
                    return
                }
            }
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: app.path), resultingItemURL: nil)
                model.didRemove(path: app.path)
            } catch let error where Self.isPermissionError(error) {
                hide()
                do {
                    // The path is passed as an argument, never spliced into the script.
                    _ = try await ActionLauncher.runSpec(ShortcutExecutionSpec(executable: "/usr/bin/osascript", arguments: [
                        "-e", "on run argv",
                        "-e", "tell application \"Finder\" to delete (POSIX file (item 1 of argv) as alias)",
                        "-e", "end run",
                        app.path,
                    ]))
                    model.didRemove(path: app.path)
                    ShortcutHUD.shared.show(symbol: "trash", title: app.name, subtitle: tr("已移到废纸篓", "Moved to Trash"),
                                            image: NSWorkspace.shared.icon(forFile: app.path))
                } catch {
                    report(tr("无法将「\(app.name)」移到废纸篓：\(error.localizedDescription)",
                              "Could not move “\(app.name)” to the Trash: \(error.localizedDescription)"))
                }
            } catch {
                report(tr("无法将「\(app.name)」移到废纸篓：\(error.localizedDescription)",
                          "Could not move “\(app.name)” to the Trash: \(error.localizedDescription)"))
            }
        }
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteNoPermissionError { return true }
        if error.domain == NSPOSIXErrorDomain, [Int(EPERM), Int(EACCES)].contains(error.code) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionError(underlying) }
        return false
    }

    /// Errors leave the grid first: it sits above ordinary windows and would hide the alert.
    private func report(_ message: String) {
        hide()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel, .flagsChanged]) { [weak self] event in
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
        if event.type == .flagsChanged {
            model.optionChanged(isDown: event.modifierFlags.contains(.option))
            return false
        }
        if event.type == .scrollWheel {
            // Pages stay put while a folder is open over them.
            if model.openFolderID == nil { handleScroll(event) }
            return true
        }
        // While an input method is composing (pinyin, for one), Return, Esc
        // and the arrows pick and dismiss candidates; leave them to it.
        if let editor = panel?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        // Esc backs out one step at a time.
        if event.keyCode == 53 {
            if model.pendingRemoval != nil {
                model.cancelRemoval()
            } else if model.isEditing {
                model.endEditing()
            } else if model.openFolderID != nil {
                panel?.makeFirstResponder(nil)
                model.closeFolder()
            } else if !model.query.isEmpty {
                model.query = ""
            } else {
                hide()
            }
            return true
        }
        // The question takes no keys: removing an app needs a click.
        if model.pendingRemoval != nil { return true }
        // With a folder open, keys belong to its name field.
        if model.openFolderID != nil { return false }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) { return false }

        switch event.keyCode {
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
            model.endEditing()
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

