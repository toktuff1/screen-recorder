import AppKit
let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let bg = NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 220, yRadius: 220)
NSColor(calibratedRed: 0.10, green: 0.15, blue: 0.27, alpha: 1).setFill(); bg.fill()
let screen = NSBezierPath(roundedRect: NSRect(x: 180, y: 310, width: 664, height: 454), xRadius: 55, yRadius: 55)
NSColor(calibratedRed: 0.91, green: 0.95, blue: 1, alpha: 1).setStroke(); screen.lineWidth = 34; screen.stroke()
let stand = NSBezierPath(); stand.move(to: NSPoint(x: 512, y: 307)); stand.line(to: NSPoint(x: 512, y: 222)); stand.lineWidth = 34; stand.lineCapStyle = .round; stand.stroke()
let foot = NSBezierPath(); foot.move(to: NSPoint(x: 380, y: 220)); foot.line(to: NSPoint(x: 644, y: 220)); foot.lineWidth = 34; foot.lineCapStyle = .round; foot.stroke()
let ring = NSBezierPath(ovalIn: NSRect(x: 398, y: 423, width: 228, height: 228)); ring.lineWidth = 15; NSColor.white.withAlphaComponent(0.95).setStroke(); ring.stroke()
NSColor(calibratedRed: 1, green: 0.25, blue: 0.29, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 428, y: 453, width: 168, height: 168)).fill()
image.unlockFocus()
for n in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = n * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "work/ScreenRecorder.iconset/icon_\(n)x\(n)\(suffix).png"))
    }
}
