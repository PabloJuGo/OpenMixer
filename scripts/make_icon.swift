// Draws the OpenMixer app icon (original artwork) and writes Resources/AppIcon.icns.  Usage: swift scripts/make_icon.swift
import AppKit

func draw(_ s: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
        let u = s / 1024
        // macOS icon grid: art occupies ~80% of the canvas.
        let tile = NSBezierPath(roundedRect: rect.insetBy(dx: 100 * u, dy: 100 * u), xRadius: 185 * u, yRadius: 185 * u)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35); shadow.shadowBlurRadius = 24 * u; shadow.shadowOffset = NSSize(width: 0, height: -10 * u)
        shadow.set()
        NSColor(red: 0.12, green: 0.2, blue: 0.5, alpha: 1).setFill(); tile.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(colors: [NSColor(red: 0.36, green: 0.62, blue: 1, alpha: 1), NSColor(red: 0.13, green: 0.22, blue: 0.62, alpha: 1)])!.draw(in: tile, angle: -90)
        // gloss
        NSGraphicsContext.saveGraphicsState(); tile.addClip()
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
            .draw(in: NSRect(x: 0, y: 520 * u, width: s, height: 500 * u), angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        // speaker cone
        let c = NSPoint(x: 440 * u, y: 512 * u)
        func circle(_ r: CGFloat) -> NSBezierPath { NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)) }
        NSColor.white.withAlphaComponent(0.95).setFill(); circle(290 * u).fill()
        NSGradient(colors: [NSColor(red: 0.2, green: 0.3, blue: 0.7, alpha: 1), NSColor(red: 0.1, green: 0.17, blue: 0.5, alpha: 1)])!.draw(in: circle(255 * u), angle: -90)
        for r in [215, 175] as [CGFloat] {
            let ring = circle(r * u); ring.lineWidth = 6 * u
            NSColor.white.withAlphaComponent(0.18).setStroke(); ring.stroke()
        }
        NSGradient(colors: [NSColor.white, NSColor(red: 0.8, green: 0.86, blue: 1, alpha: 1)])!.draw(in: circle(105 * u), angle: -90)

        // level pills
        for i in 0..<4 {
            let pill = NSBezierPath(roundedRect: NSRect(x: 735 * u, y: (268 + CGFloat(i) * 130) * u, width: 150 * u, height: 82 * u), xRadius: 41 * u, yRadius: 41 * u)
            NSColor.white.withAlphaComponent(i < 3 ? 0.95 : 0.35).setFill(); pill.fill()
        }
        return true
    }
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("OpenMixer.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let image = draw(CGFloat(px))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns")
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote \(out.path)" : "iconutil failed")
