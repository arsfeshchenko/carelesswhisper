import AppKit

enum IconDrawer {
    private static let size: CGFloat = 18.0
    private static let eggH: CGFloat = 13.5
    private static let eggS: CGFloat = eggH / 167.0
    private static let eggW: CGFloat = 135.0 * eggS
    private static let eggOX: CGFloat = (size - eggW) / 2.0
    private static let eggOY: CGFloat = (size - eggH) / 2.0

    private static func pt(_ sx: CGFloat, _ sy: CGFloat,
                           scale: CGFloat = 1.0, offsetY: CGFloat = 0.0) -> NSPoint {
        let cx = size / 2.0
        let cy = size / 2.0
        let nx = sx * eggS + eggOX
        let ny = (167.0 - sy) * eggS + eggOY
        return NSPoint(
            x: (nx - cx) * scale + cx,
            y: (ny - cy) * scale + cy + offsetY
        )
    }

    private static func eggPath(scale: CGFloat = 1.0, offsetY: CGFloat = 0.0) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: pt(135, 99.5, scale: scale, offsetY: offsetY))
        path.curve(to: pt(67.5, 167, scale: scale, offsetY: offsetY),
                   controlPoint1: pt(135, 136.779, scale: scale, offsetY: offsetY),
                   controlPoint2: pt(104.779, 167, scale: scale, offsetY: offsetY))
        path.curve(to: pt(0, 99.5, scale: scale, offsetY: offsetY),
                   controlPoint1: pt(30.2208, 167, scale: scale, offsetY: offsetY),
                   controlPoint2: pt(0, 136.779, scale: scale, offsetY: offsetY))
        path.curve(to: pt(67.5, 0, scale: scale, offsetY: offsetY),
                   controlPoint1: pt(0, 62.2208, scale: scale, offsetY: offsetY),
                   controlPoint2: pt(30.2208, 0, scale: scale, offsetY: offsetY))
        path.curve(to: pt(135, 99.5, scale: scale, offsetY: offsetY),
                   controlPoint1: pt(104.779, 0, scale: scale, offsetY: offsetY),
                   controlPoint2: pt(135, 62.2208, scale: scale, offsetY: offsetY))
        path.close()
        return path
    }

    private static func makeImage(_ draw: (NSRect) -> Void) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        draw(rect)
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    static func idle() -> NSImage {
        makeImage { _ in
            NSColor.black.setFill()
            eggPath().fill()
        }
    }

    static func recording(scale: CGFloat) -> NSImage {
        makeImage { _ in
            NSColor.black.setFill()
            eggPath(scale: scale).fill()
        }
    }

    static func processing(offsetY: CGFloat) -> NSImage {
        makeImage { _ in
            NSColor.black.setFill()
            eggPath(offsetY: offsetY).fill()
        }
    }

    static func success() -> NSImage {
        makeImage { _ in
            // Egg outline
            let path = eggPath()
            NSColor.black.setStroke()
            path.lineWidth = 1.2
            path.stroke()

            // Checkmark inside
            let check = NSBezierPath()
            check.move(to: NSPoint(x: 5.5, y: 8.5))
            check.line(to: NSPoint(x: 8.0, y: 6.0))
            check.line(to: NSPoint(x: 12.5, y: 11.5))
            check.lineWidth = 1.5
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.black.setStroke()
            check.stroke()
        }
    }

    static func error() -> NSImage {
        makeImage { _ in
            // Circle (not egg)
            let inset: CGFloat = 2.5
            let circleRect = NSRect(x: inset, y: inset,
                                    width: size - inset * 2, height: size - inset * 2)
            let circle = NSBezierPath(ovalIn: circleRect)
            NSColor.black.setStroke()
            circle.lineWidth = 1.2
            circle.stroke()

            // X mark inside
            let x = NSBezierPath()
            x.move(to: NSPoint(x: 6.5, y: 6.5))
            x.line(to: NSPoint(x: 11.5, y: 11.5))
            x.move(to: NSPoint(x: 11.5, y: 6.5))
            x.line(to: NSPoint(x: 6.5, y: 11.5))
            x.lineWidth = 1.5
            x.lineCapStyle = .round
            NSColor.black.setStroke()
            x.stroke()
        }
    }
}
