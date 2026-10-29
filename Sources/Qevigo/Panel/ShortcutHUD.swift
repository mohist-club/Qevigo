import AppKit

/// The brief overlay a shortcut shows so you can tell it did something — a
/// small square of glass near the top of the screen, the shape macOS uses for
/// its own volume and brightness panels. Not used for translation, where the
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
        (panel.contentView as? HUDContentView)?.update(
            symbol: symbol, title: title, subtitle: subtitle, image: image
        )
        let target = placement()

        dismissal?.cancel()
        // Liquid Glass refracts what is behind it only while the window itself
        // is fully opaque; lowering the window's alpha flattens it to a grey
        // slab, so transparency is left to the glass material.
        //
        // It grows into place rather than appearing outright: the glass keeps
        // its proportions as the square resizes, which is the part that reads
        // as liquid.
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
        let side = HUDContentView.windowSide
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: side, height: side),
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
    private func placement() -> NSRect {
        let side = HUDContentView.windowSide
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return NSRect(x: 0, y: 0, width: side, height: side) }
        // The glass sits inside a transparent margin, so the position is
        // worked out for the glass and the window is grown around it.
        let margin = HUDContentView.margin
        return NSRect(
            x: frame.midX - side / 2,
            y: frame.maxY - frame.height * 0.16 - HUDContentView.side - margin,
            width: side,
            height: side
        )
    }
}

private final class HUDContentView: NSView {
    /// A square of about 16,400pt², the size that reads clearly without
    /// covering what is underneath.
    static let side: CGFloat = 128
    /// Transparent room around the glass. Without it the window clips the
    /// shadow and edge highlight the material draws outside its own bounds,
    /// which is what flattens it into a plain grey square.
    static let margin: CGFloat = 22
    static var windowSide: CGFloat { side + margin * 2 }

    private let symbolView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let content = NSView()
    private let shadowView = NSView()
    private let shadowMask = CAShapeLayer()
    private var background: NSView!
    private var glassView: NSView?

    private static let iconSide: CGFloat = 50
    private static let inset: CGFloat = 14
    private static let iconToTitle: CGFloat = 12
    /// A squircle rather than a circle, in the proportion the system HUDs use.
    private static let radiusRatio: CGFloat = 0.22

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.windowSide, height: Self.windowSide))
        wantsLayer = true

        // Liquid Glass where the system has it. The material carries the
        // translucency on its own; older systems fall back to a HUD material.
        let background: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            // The panel never becomes key, so the material renders in its
            // quieter inactive form. A light tint brings it back up to the
            // brightness of the system's own overlays, and stays out of the
            // way in dark mode.
            glass.tintColor = Self.tint
            glass.cornerRadius = Self.side * Self.radiusRatio
            if #available(macOS 27.0, *) {
                // Lets the material react to what moves behind and under it.
                glass.effectIsInteractive = true
            }
            glassView = glass
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
            effect.layer?.cornerRadius = Self.side * Self.radiusRatio
            effect.layer?.cornerCurve = .continuous
            effect.layer?.masksToBounds = true
            background = effect
        }
        // A soft drop shadow of its own, so the square lifts off whatever is
        // behind it instead of sitting flat against it. The layer has no
        // content — only the shadow its path casts — so the glass above stays
        // see-through.
        // Set through NSView.shadow rather than on the layer: AppKit keeps a
        // layer-backed view's shadow in step with this property and zeroes
        // anything written straight to the layer, leaving no shadow at all.
        // The strength lives in the colour's alpha.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -5)
        shadowView.wantsLayer = true
        shadowView.shadow = shadow
        shadowView.layer?.masksToBounds = false
        // The part of the shadow that falls under the square is masked away.
        // The material is translucent, so a shadow left there shows straight
        // through it and dulls the whole panel.
        shadowView.layer?.mask = shadowMask
        addSubview(shadowView)

        background.autoresizingMask = [.width, .height]
        background.frame = bounds.insetBy(dx: Self.margin, dy: Self.margin)
        addSubview(background)
        self.background = background

        symbolView.imageScaling = .scaleProportionallyUpOrDown
        symbolView.contentTintColor = .labelColor

        titleLabel.alignment = .center
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        subtitleLabel.alignment = .center
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 1

        // NSGlassEffectView refracts whatever sits in its contentView, so the
        // icon and labels go there rather than on top of it.
        content.autoresizingMask = [.width, .height]
        content.frame = bounds.insetBy(dx: Self.margin, dy: Self.margin)
        if #available(macOS 26.0, *), let glass = glassView as? NSGlassEffectView {
            glass.contentView = content
        } else {
            background.addSubview(content)
        }
        for view in [symbolView, titleLabel, subtitleLabel] { content.addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static let tint = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.06)
            : NSColor.white.withAlphaComponent(0.34)
    }

    func update(symbol: String, title: String, subtitle: String?, image: NSImage?) {
        if let image {
            symbolView.image = image
            symbolView.contentTintColor = nil
        } else {
                let configuration = NSImage.SymbolConfiguration(pointSize: 34, weight: .regular)
            symbolView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
                .withSymbolConfiguration(configuration)
            symbolView.contentTintColor = .labelColor
        }
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle ?? ""
        subtitleLabel.isHidden = subtitle == nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // The glass keeps the margin on every side as the window grows into
        // place, so the proportions hold through the animation.
        let scale = bounds.width / Self.windowSide
        let square = bounds.insetBy(dx: Self.margin * scale, dy: Self.margin * scale)
        let radius = min(square.width, square.height) * Self.radiusRatio
        if #available(macOS 26.0, *), let glass = glassView as? NSGlassEffectView {
            background.frame = square
            glass.frame = NSRect(origin: .zero, size: square.size)
            glass.cornerRadius = radius
        } else {
            background.frame = square
            background.layer?.cornerRadius = radius
        }
        content.frame = NSRect(origin: .zero, size: square.size)
        // The shadow view spans the window so its mask can reach the spill
        // outside the square.
        shadowView.frame = bounds
        let shape = NSBezierPath(roundedRect: square, xRadius: radius, yRadius: radius)
        shadowView.layer?.shadowPath = shape.cgPath
        let hole = NSBezierPath(rect: bounds)
        hole.append(shape)
        hole.windingRule = .evenOdd
        shadowMask.frame = bounds
        shadowMask.fillRule = .evenOdd
        shadowMask.path = hole.cgPath

        let titleHeight = ceil(titleLabel.fittingSize.height)
        let subtitleHeight = subtitleLabel.isHidden ? 0 : ceil(subtitleLabel.fittingSize.height)
        let block = Self.iconSide + Self.iconToTitle + titleHeight + (subtitleLabel.isHidden ? 0 : subtitleHeight + 1)
        let top = (square.height + block) / 2
        let width = square.width - Self.inset * 2

        symbolView.frame = NSRect(x: (square.width - Self.iconSide) / 2, y: top - Self.iconSide,
                                  width: Self.iconSide, height: Self.iconSide)
        titleLabel.frame = NSRect(x: Self.inset, y: top - Self.iconSide - Self.iconToTitle - titleHeight,
                                  width: width, height: titleHeight)
        subtitleLabel.frame = NSRect(x: Self.inset, y: top - block, width: width, height: subtitleHeight)
    }
}
