import AppKit

/// The Qevigo mark: a "Q" whose tail doubles as a speech-bubble tail.
/// Same geometry as `scripts/make-icon.swift`, scaled to any size.
enum BrandMark {
    static func paths(in rect: NSRect) -> [NSBezierPath] {
        // Proportions taken from the 1024pt icon: mark spans ~0.62 of the canvas.
        let unit = min(rect.width, rect.height) / 620
        let c = NSPoint(x: rect.minX + 290 * unit, y: rect.minY + 340 * unit)
        let r = 222 * unit
        let w = 94 * unit
        func point(_ distance: CGFloat, _ degrees: CGFloat) -> NSPoint {
            let a = degrees * .pi / 180
            return NSPoint(x: c.x + distance * cos(a), y: c.y + distance * sin(a))
        }
        let ring = NSBezierPath()
        ring.appendOval(in: NSRect(x: c.x - r - w / 2, y: c.y - r - w / 2, width: 2 * r + w, height: 2 * r + w))
        ring.appendOval(in: NSRect(x: c.x - r + w / 2, y: c.y - r + w / 2, width: 2 * r - w, height: 2 * r - w))
        ring.windingRule = .evenOdd

        let outer = r + w / 2
        let tail = NSBezierPath()
        tail.move(to: point(outer - w * 0.35, -12))
        tail.curve(to: point(outer + r * 0.62, -52), controlPoint1: point(outer + w * 0.2, -20), controlPoint2: point(outer + r * 0.42, -40))
        tail.curve(to: point(outer - w * 0.35, -82), controlPoint1: point(outer + r * 0.20, -66), controlPoint2: point(outer, -82))
        tail.close()
        return [ring, tail]
    }

    /// Monochrome template image; macOS picks the right color for menu bars and buttons.
    static func templateImage(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor.black.setFill()
            paths(in: rect.insetBy(dx: size * 0.06, dy: size * 0.06)).forEach { $0.fill() }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Qevigo"
        return image
    }
}
