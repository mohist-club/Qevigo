import AppKit

/// The brief overlay a shortcut shows so you can tell it did something —
/// the same shape as the volume and brightness panels macOS draws itself.
/// Not used for translation, where the translation window is the feedback.
@MainActor
final class ShortcutHUD {
    static let shared = ShortcutHUD()

    private var panel: NSPanel?
    private var dismissal: DispatchWorkItem?
    private static let side: CGFloat = 190

    private init() {}

    func show(symbol: String, title: String, subtitle: String? = nil, image: NSImage? = nil) {
        let panel = panel ?? makePanel()
        self.panel = panel
        (panel.contentView as? HUDContentView)?.update(
            symbol: symbol, title: title, subtitle: subtitle, image: image
        )
        place(panel)

        dismissal?.cancel()
        panel.alphaValue = 1
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

    /// Low and centred on the screen the pointer is on, like the system panels.
    private func place(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - Self.side / 2,
            y: frame.minY + frame.height * 0.12
        ))
    }
}

private final class HUDContentView: NSView {
    private let effect = NSVisualEffectView()
    private let symbolView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 20
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        effect.frame = bounds
        addSubview(effect)

        symbolView.imageScaling = .scaleProportionallyUpOrDown
        symbolView.contentTintColor = .labelColor

        titleLabel.alignment = .center
        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        subtitleLabel.alignment = .center
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 1

        for view in [symbolView, titleLabel, subtitleLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(view)
        }
        NSLayoutConstraint.activate([
            symbolView.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbolView.topAnchor.constraint(equalTo: topAnchor, constant: 38),
            symbolView.widthAnchor.constraint(equalToConstant: 68),
            symbolView.heightAnchor.constraint(equalToConstant: 68),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            titleLabel.topAnchor.constraint(equalTo: symbolView.bottomAnchor, constant: 16),

            subtitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            subtitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(symbol: String, title: String, subtitle: String?, image: NSImage?) {
        if let image {
            symbolView.image = image
            symbolView.contentTintColor = nil
        } else {
            let configuration = NSImage.SymbolConfiguration(pointSize: 56, weight: .regular)
            symbolView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
                .withSymbolConfiguration(configuration)
            symbolView.contentTintColor = .labelColor
        }
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle ?? ""
        subtitleLabel.isHidden = subtitle == nil
    }
}
