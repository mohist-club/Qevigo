import AppKit

/// The brief overlay a shortcut shows so you can tell it did something — a
/// small glass pill near the top of the screen, in the shape the system uses
/// for its own transient banners. Not used for translation, where the
/// translation window is the feedback.
@MainActor
final class ShortcutHUD {
    static let shared = ShortcutHUD()

    private var panel: NSPanel?
    private var dismissal: DispatchWorkItem?
    /// Long enough to read two short lines, short enough to stay out of the way.
    private static let visibleDuration: TimeInterval = 0.9
    private static let growDuration: TimeInterval = 0.22

    private init() {}

    func show(symbol: String, title: String, subtitle: String? = nil, image: NSImage? = nil) {
        let panel = panel ?? makePanel()
        self.panel = panel
        guard let content = panel.contentView as? HUDContentView else { return }
        let size = content.update(symbol: symbol, title: title, subtitle: subtitle, image: image)
        let target = placement(for: size)

        dismissal?.cancel()
        // Liquid Glass refracts what is behind it only while the window itself
        // is fully opaque; lowering the window's alpha flattens it to a grey
        // slab, so transparency is left to the glass material.
        //
        // It grows into place rather than appearing outright: the glass keeps
        // its capsule as the pill resizes, which is the part that reads as
        // liquid.
        panel.setFrame(target.insetBy(dx: target.width * 0.05, dy: target.height * 0.05), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.growDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak panel] in
            guard let panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().setFrame(target.insetBy(dx: target.width * 0.03, dy: target.height * 0.03), display: true)
                panel.animator().alphaValue = 0
            } completionHandler: {
                panel.orderOut(nil)
            }
        }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleDuration, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: HUDContentView.height),
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
        panel.contentView = HUDContentView()
        return panel
    }

    /// Centred in the upper part of the screen the pointer is on, clear of
    /// whatever is being worked on lower down.
    private func placement(for size: NSSize) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return NSRect(origin: .zero, size: size) }
        return NSRect(
            x: frame.midX - size.width / 2,
            y: frame.maxY - frame.height * 0.16 - size.height,
            width: size.width,
            height: size.height
        )
    }
}

private final class HUDContentView: NSView {
    static let height: CGFloat = 72

    private let symbolView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let content = NSView()
    private var background: NSView!
    private var glassView: NSView?

    private static let iconSide: CGFloat = 38
    private static let leading: CGFloat = 16
    private static let gap: CGFloat = 14
    private static let trailing: CGFloat = 20
    private static let widthRange: ClosedRange<CGFloat> = 225...380

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: Self.height))
        wantsLayer = true

        // Liquid Glass where the system has it. The material carries the
        // translucency on its own; older systems fall back to a HUD material.
        let background: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = Self.height / 2
            if #available(macOS 27.0, *) {
                // Lets the material react to what moves behind and under it.
                glass.effectIsInteractive = true
            }
            self.glassView = glass
            // Glass renders through a container, which is what blends nearby
            // glass shapes into one another rather than stacking them.
            let container = NSGlassEffectContainerView()
            container.spacing = 12
            container.contentView = glass
            background = container
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = Self.height / 2
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

        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 1

        // NSGlassEffectView refracts whatever sits in its contentView, so the
        // icon and labels go there rather than on top of it.
        content.autoresizingMask = [.width, .height]
        content.frame = bounds
        if #available(macOS 26.0, *), let glass = glassView as? NSGlassEffectView {
            glass.contentView = content
        } else {
            background.addSubview(content)
        }
        for view in [symbolView, titleLabel, subtitleLabel] { content.addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Fills in the pill and reports the width it needs, so it hugs its text.
    func update(symbol: String, title: String, subtitle: String?, image: NSImage?) -> NSSize {
        if let image {
            symbolView.image = image
            symbolView.contentTintColor = nil
        } else {
            let configuration = NSImage.SymbolConfiguration(pointSize: 26, weight: .regular)
            symbolView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
                .withSymbolConfiguration(configuration)
            symbolView.contentTintColor = .labelColor
        }
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle ?? ""
        subtitleLabel.isHidden = subtitle == nil

        let text = max(width(of: titleLabel), width(of: subtitleLabel))
        let width = Self.leading + Self.iconSide + Self.gap + text + Self.trailing
        let size = NSSize(width: min(max(width, Self.widthRange.lowerBound), Self.widthRange.upperBound),
                          height: Self.height)
        setFrameSize(size)
        return size
    }

    private func width(of label: NSTextField) -> CGFloat {
        guard !label.isHidden, let font = label.font else { return 0 }
        return ceil((label.stringValue as NSString).size(withAttributes: [.font: font]).width)
    }

    override func layout() {
        super.layout()
        if #available(macOS 26.0, *), let glass = glassView as? NSGlassEffectView {
            glass.frame = bounds
            glass.cornerRadius = bounds.height / 2
        } else if let layer = background.layer {
            layer.cornerRadius = bounds.height / 2
        }
        content.frame = bounds
        symbolView.frame = NSRect(x: Self.leading, y: (bounds.height - Self.iconSide) / 2,
                                  width: Self.iconSide, height: Self.iconSide)
        let x = Self.leading + Self.iconSide + Self.gap
        let available = max(bounds.width - x - Self.trailing, 0)
        let titleHeight = ceil(titleLabel.fittingSize.height)
        if subtitleLabel.isHidden {
            titleLabel.frame = NSRect(x: x, y: (bounds.height - titleHeight) / 2, width: available, height: titleHeight)
        } else {
            let subtitleHeight = ceil(subtitleLabel.fittingSize.height)
            let block = titleHeight + subtitleHeight
            let top = (bounds.height + block) / 2
            titleLabel.frame = NSRect(x: x, y: top - titleHeight, width: available, height: titleHeight)
            subtitleLabel.frame = NSRect(x: x, y: top - block - 1, width: available, height: subtitleHeight)
        }
    }
}
