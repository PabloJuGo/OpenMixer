import AppKit

/// The menu-bar glyph: a speaker-cone tile plus four pills that light up with the output volume.
public enum StatusIcon {
    public static func litPills(volume: Float, muted: Bool) -> Int {
        guard !muted, volume > 0 else { return 0 }
        return min(4, max(1, Int(ceilf(volume * 4))))
    }

    public static func image(volume: Float, muted: Bool) -> NSImage {
        let lit = litPills(volume: volume, muted: muted)
        let image = NSImage(size: NSSize(width: 27, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            // Tile with a speaker cone cut out of it.
            let tile = NSBezierPath(roundedRect: NSRect(x: 1, y: 1.5, width: 15, height: 15), xRadius: 4, yRadius: 4)
            let cone = NSBezierPath(ovalIn: NSRect(x: 3, y: 3.5, width: 11, height: 11))
            let dome = NSBezierPath(ovalIn: NSRect(x: 6, y: 6.5, width: 5, height: 5))
            tile.append(cone); tile.append(dome)
            tile.windingRule = .evenOdd
            tile.fill()
            let ring = NSBezierPath(ovalIn: NSRect(x: 4.6, y: 5.1, width: 7.8, height: 7.8))
            ring.lineWidth = 0.6
            NSColor.black.withAlphaComponent(0.9).setStroke()
            ring.stroke()
            for i in 0..<4 {   // bottom pill = first to light
                NSColor.black.withAlphaComponent(i < lit ? 1 : 0.3).setFill()
                NSBezierPath(roundedRect: NSRect(x: 19, y: 1.5 + CGFloat(i) * 4.2, width: 6, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
