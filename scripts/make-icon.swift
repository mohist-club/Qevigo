// Renders the Qevigo app icon: a white "Q" whose tail doubles as a speech-bubble
// tail, on a green-to-blue squircle.
//   swift scripts/make-icon.swift            writes Resources/AppIcon-master.png and Resources/AppIcon.iconset
import AppKit

let canvas: CGFloat = 1024

func renderMaster() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // macOS icon grid: 824pt body centered on a 1024 canvas.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 28
    shadow.set()
    NSColor.black.setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [
        NSColor(srgbRed: 0.20, green: 0.84, blue: 0.62, alpha: 1),
        NSColor(srgbRed: 0.05, green: 0.66, blue: 0.80, alpha: 1),
        NSColor(srgbRed: 0.16, green: 0.42, blue: 0.95, alpha: 1)
    ])!.draw(in: body, angle: -60)
    // Soft top highlight.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    let glyphShadow = NSShadow()
    glyphShadow.shadowColor = NSColor(srgbRed: 0.02, green: 0.20, blue: 0.40, alpha: 0.30)
    glyphShadow.shadowOffset = NSSize(width: 0, height: -8)
    glyphShadow.shadowBlurRadius = 18
    glyphShadow.set()
    let cg = NSGraphicsContext.current!.cgContext
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    NSColor.white.setFill()
    markPaths(center: NSPoint(x: 500, y: 530), radius: 222, stroke: 94).forEach { $0.fill() }
    cg.endTransparencyLayer()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// The Q-bubble mark: a ring plus a tail at the lower right. Keep in sync with `BrandMark` in the app.
func markPaths(center c: NSPoint, radius r: CGFloat, stroke w: CGFloat) -> [NSBezierPath] {
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

func png(_ rep: NSBitmapImageRep, size: Int) -> Data {
    let scaled = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: scaled)
    NSGraphicsContext.current?.imageInterpolation = .high
    rep.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return scaled.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let master = renderMaster()
try png(master, size: 1024).write(to: root.appendingPathComponent("Resources/AppIcon-master.png"))
let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
for base in [16, 32, 128, 256, 512] {
    try png(master, size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(master, size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("wrote Resources/AppIcon-master.png and \(iconset.lastPathComponent)")
