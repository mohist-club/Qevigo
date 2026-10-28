import AppKit

/// The brief overlay a shortcut shows so you can tell it did something —
/// the same shape as the volume and brightness panels macOS draws itself.
/// Not used for translation, where the translation window is the feedback.
@MainActor
final class ShortcutHUD {
    static let shared = ShortcutHUD()

    private var panel: NSPanel?
    private var dismissal: DispatchWorkItem?
    private static let side: CGFloat = 148

    private init() {}

    func show(symbol: String, title: String, subtitle: String? = nil, image: NSImage? = nil) {
        let panel = panel ?? makePanel()
        self.panel = panel
        (panel.contentView as? HUDContentView)?.update(
            symbol: symbol, title: title, subtitle: subtitle, image: image
        )
        place(panel)

        dismissal?.cancel()
        // Follows the glass transparency in settings, so it can be tuned there.
        let transparency = AppEnvironment.shared.settings.preferences.glassTransparency
        panel.alphaValue = min(max(1 - transparency * 0.5, 0.45), 0.95)
        panel.orderFrontRegardless()

        let work = DispatchWorkItem { [weak panel] in
            guard let panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                panel.animator().alphaValue = 0
            } completionHandler: {
                panel.orderOut(nil)
            }
        }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.side, height: Self.side),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Above full-screen apps, and never in the way of a click.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.contentView = HUDContentView(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        return panel
    }

    /// Centred in the upper part of the screen the pointer is on, clear of
    /// whatever is being worked on lower down.
    private func place(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - Self.side / 2,
            y: frame.maxY - frame.height * 0.16 - Self.side
        ))
    }
}

private final class HUDContentView: NSView {
    private let symbolView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        // Liquid Glass where the system has it, in its clearest style; older
        // systems fall back to the most transparent material available.
        let background: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .clear
            glass.cornerRadius = 18
            background = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .underWindowBackground
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 18
            effect.layer?.cornerCurve = .continuous
            effect.layer?.masksToBounds = true
            background = effect
        }
        background.autoresizingMask = [.width, .height]
        background.frame = bounds
        addSubview(background)
        self.background = background

        symbolView.imageScaling = .scaleProportionallyUpOrDown
        symbolView.contentTintColor = .labelColor

        titleLabel.alignment = .center
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        subtitleLabel.alignment = .center
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 1

        // NSGlassEffectView refracts whatever sits in its contentView, so the
        // labels go there rather than on top of it.
        let content = NSView(frame: bounds)
        content.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *), let glass = background as? NSGlassEffectView {
            glass.contentView = content
        } else {
            background.addSubview(content)
        }
        for view in [symbolView, titleLabel, subtitleLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            symbolView.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbolView.topAnchor.constraint(equalTo: topAnchor, constant: 28),
            symbolView.widthAnchor.constraint(equalToConstant: 52),
            symbolView.heightAnchor.constraint(equalToConstant: 52),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleLabel.topAnchor.constraint(equalTo: symbolView.bottomAnchor, constant: 12),

            subtitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            subtitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2)
        ])
    }

    private var background: NSView!

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(symbol: String, title: String, subtitle: String?, image: NSImage?) {
        if let image {
            symbolView.image = image
            symbolView.contentTintColor = nil
        } else {
            let configuration = NSImage.SymbolConfiguration(pointSize: 42, weight: .regular)
            symbolView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
                .withSymbolConfiguration(configuration)
            symbolView.contentTintColor = .labelColor
        }
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle ?? ""
        subtitleLabel.isHidden = subtitle == nil
    }
}
