import AppKit
import QevigoCore
import SwiftUI

private final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

final class FloatingTranslationPanel: NSPanel {
    let state = PanelState()
    private let store: SettingsStore
    private weak var sourceTextView: NSTextView?
    private var isApplyingFrame = false
    var onClear: (() -> Void)?
    private var observers: [NSObjectProtocol] = []

    static let defaultSize = NSSize(width: 940, height: 580)
    static let minimumSize = NSSize(width: 740, height: 460)
    static let maximumSize = NSSize(width: 1400, height: 1000)

    @MainActor
    init(store: SettingsStore, actions: (FloatingTranslationPanel) -> PanelActions) {
        self.store = store
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.nonactivatingPanel, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        minSize = Self.minimumSize
        maxSize = Self.maximumSize
        isReleasedWhenClosed = false
        appearance = store.preferences.appearance.nsAppearance

        var panelActions = actions(self)
        let previousReady = panelActions.textViewReady
        panelActions.textViewReady = { [weak self] textView in
            self?.sourceTextView = textView
            previousReady(textView)
        }
        let hosting = TransparentHostingView(rootView: TranslationPanelView(state: state, store: store, actions: panelActions))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.cornerRadius = TranslationPanelView.cornerRadius
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        contentView = hosting

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.persistFrame(resized: false) }
        })
        observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isApplyingFrame else { return }
                self.persistFrame(resized: true)
            }
        })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible, !self.state.isPinned else { return }
                self.close()
            }
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { close() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == 51, modifiers == [.command] {
            clearAll()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Focus

    @MainActor
    func focusInput() {
        NSApp.activate(ignoringOtherApps: true)
        focusInput(attemptsLeft: 6)
    }

    /// SwiftUI can hand us the NSTextView before AppKit attached it to this
    /// window; makeFirstResponder is refused in that gap, so retry briefly.
    @MainActor
    private func focusInput(attemptsLeft: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.contentView?.layoutSubtreeIfNeeded()
            if let textView = self.sourceTextView, textView.window === self {
                self.makeKeyAndOrderFront(nil)
                self.makeFirstResponder(textView)
            } else if attemptsLeft > 1 {
                self.focusInput(attemptsLeft: attemptsLeft - 1)
            } else {
                self.makeKeyAndOrderFront(nil)
            }
        }
    }

    @MainActor
    func clearAll() {
        state.sourceText = ""
        state.translatedText = ""
        state.errorMessage = nil
        state.failoverNotice = nil
        state.isLoading = false
        onClear?()
        focusInput()
    }

    // MARK: Placement

    private var savedFrame: PanelFrame? {
        store.files.load(PanelFrame.self, from: StoreFile.panelFrame)
    }

    @MainActor
    private func persistFrame(resized: Bool) {
        var saved = savedFrame ?? PanelFrame(
            x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height, wasManuallyResized: false
        )
        saved.x = frame.origin.x
        saved.y = frame.origin.y
        if resized {
            saved.width = frame.width
            saved.height = frame.height
            saved.wasManuallyResized = true
        }
        store.files.save(saved, to: StoreFile.panelFrame)
    }

    @MainActor
    func show(near point: NSPoint?) {
        let saved = savedFrame
        let size = size(from: saved)
        var origin: NSPoint
        if let saved {
            origin = NSPoint(x: saved.x, y: saved.y)
        } else if let point {
            origin = NSPoint(x: point.x, y: point.y - size.height - 12)
        } else if let screen = NSScreen.main {
            origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2)
        } else {
            origin = .zero
        }
        clamp(&origin, size: size, reference: point)
        isApplyingFrame = true
        setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
        isApplyingFrame = false
        orderFrontRegardless()
        makeKey()
    }

    private func size(from saved: PanelFrame?) -> NSSize {
        guard let saved, saved.wasManuallyResized,
              saved.width >= Self.minimumSize.width, saved.height >= Self.minimumSize.height else {
            return Self.defaultSize
        }
        return NSSize(
            width: min(saved.width, Self.maximumSize.width),
            height: min(saved.height, Self.maximumSize.height)
        )
    }

    private func clamp(_ origin: inout NSPoint, size: NSSize, reference: NSPoint?) {
        let point = reference ?? origin
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        origin.x = min(max(origin.x, visible.minX + 8), max(visible.minX + 8, visible.maxX - size.width - 8))
        origin.y = min(max(origin.y, visible.minY + 8), max(visible.minY + 8, visible.maxY - size.height - 8))
    }
}
