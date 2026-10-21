// Regenerates Resources/AppIcon.icns:  make icon
// (swift scripts/make-icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns)
import AppKit

let iconset = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// A speech bubble: a rounded rectangle with a tail at its bottom left or right. Filled as two shapes so
/// their overlap doesn't cancel out.
func fillBubble(_ rect: NSRect, tailOnLeft: Bool) {
    NSBezierPath(roundedRect: rect, xRadius: rect.height * 0.42, yRadius: rect.height * 0.42).fill()
    let edge = tailOnLeft ? rect.minX : rect.maxX
    let direction: CGFloat = tailOnLeft ? 1 : -1
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: edge + 90 * direction, y: rect.minY + 80))
    tail.line(to: NSPoint(x: edge + 40 * direction, y: rect.minY - 72))
    tail.line(to: NSPoint(x: edge + 210 * direction, y: rect.minY + 20))
    tail.close()
    tail.fill()
}

func drawIcon(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: 1024, height: 1024)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Apple's icon grid: an 824 pt body centered on a 1024 pt canvas.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGradient(colors: [
        NSColor(srgbRed: 0.20, green: 0.18, blue: 0.52, alpha: 1),
        NSColor(srgbRed: 0.38, green: 0.39, blue: 0.86, alpha: 1),
    ])?.draw(in: shape, angle: 90)

    // Two chat bubbles, drawn by hand: SF Symbols may not be used in app icons. The back one is teal
    // (group chats), the front one white (1:1 chats).
    NSColor(srgbRed: 0.35, green: 0.82, blue: 0.86, alpha: 1).setFill()
    fillBubble(NSRect(x: 360, y: 470, width: 440, height: 300), tailOnLeft: false)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    // One transparency layer, so the bubble and its tail cast a single shadow.
    NSGraphicsContext.current?.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
    NSColor.white.setFill()
    fillBubble(NSRect(x: 214, y: 268, width: 470, height: 320), tailOnLeft: true)
    NSGraphicsContext.current?.cgContext.endTransparencyLayer()
    NSGraphicsContext.restoreGraphicsState()

    // A heartbeat line across the front bubble.
    let pulse = NSBezierPath()
    pulse.move(to: NSPoint(x: 268, y: 428))
    for point in [(368, 428), (408, 360), (462, 520), (514, 380), (548, 428), (630, 428)] {
        pulse.line(to: NSPoint(x: point.0, y: point.1))
    }
    pulse.lineWidth = 38
    pulse.lineCapStyle = .round
    pulse.lineJoinStyle = .round
    NSColor(srgbRed: 0.33, green: 0.32, blue: 0.80, alpha: 1).setStroke()
    pulse.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try drawIcon(pixels: points * scale)?.write(to: iconset.appending(path: name))
    }
}
print(iconset.path)
