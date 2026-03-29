import AppKit

enum IconDrawer {
    private static let size: CGFloat = 18.0

    private static func makeImage(_ draw: (NSRect) -> Void, template: Bool = true) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        draw(NSRect(x: 0, y: 0, width: size, height: size))
        img.unlockFocus()
        img.isTemplate = template
        return img
    }

    // MARK: - States

    static func idle() -> NSImage {
        let src = NSImage(named: "mic")!
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        src.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    static func recording(opacity: CGFloat) -> NSImage {
        makeImage({ _ in
            NSColor(red: 1.0, green: 0.631, blue: 0.0, alpha: opacity).setFill()
            NSBezierPath(ovalIn: NSRect(x: 3.5, y: 3.5, width: 11, height: 11)).fill()
        }, template: false)
    }

    static func processing(time: TimeInterval) -> NSImage {
        makeImage { _ in
            let center = NSPoint(x: size / 2, y: size / 2)
            let radius: CGFloat = 6.0
            let lineWidth: CGFloat = 1.8

            // Faint background track
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            NSColor.black.withAlphaComponent(0.2).setStroke()
            track.lineWidth = lineWidth
            track.stroke()

            // Spinning arc (~270°), one revolution per second
            let startDeg = CGFloat(time * 360.0).truncatingRemainder(dividingBy: 360.0)
            let endDeg = (startDeg - 270.0 + 360.0).truncatingRemainder(dividingBy: 360.0)
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius,
                          startAngle: startDeg,
                          endAngle: endDeg,
                          clockwise: false)
            NSColor.black.setStroke()
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            arc.stroke()
        }
    }

    static func success() -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let img = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)!
            .withSymbolConfiguration(config)!
        img.isTemplate = true
        return img
    }

    static func error() -> NSImage {
        makeImage { _ in
            let x = NSBezierPath()
            x.move(to: NSPoint(x: 5.5, y: 5.5))
            x.line(to: NSPoint(x: 12.5, y: 12.5))
            x.move(to: NSPoint(x: 12.5, y: 5.5))
            x.line(to: NSPoint(x: 5.5, y: 12.5))
            x.lineWidth = 2.0
            x.lineCapStyle = .round
            NSColor.black.setStroke()
            x.stroke()
        }
    }
}
