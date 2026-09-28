import AppKit

/// A small cat head drawn as a template image, so it follows the menu bar's colours.
enum StatusIcon {
    static func image(filled: Bool, working: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let head = NSBezierPath()
            head.move(to: NSPoint(x: 3.1, y: 8.4))
            head.line(to: NSPoint(x: 2.9, y: 2.9))
            head.curve(to: NSPoint(x: 3.9, y: 2.5), controlPoint1: NSPoint(x: 2.9, y: 2.4), controlPoint2: NSPoint(x: 3.4, y: 2.2))
            head.line(to: NSPoint(x: 6.9, y: 4.6))
            head.curve(to: NSPoint(x: 11.1, y: 4.6), controlPoint1: NSPoint(x: 8.2, y: 4.2), controlPoint2: NSPoint(x: 9.8, y: 4.2))
            head.line(to: NSPoint(x: 14.1, y: 2.5))
            head.curve(to: NSPoint(x: 15.1, y: 2.9), controlPoint1: NSPoint(x: 14.6, y: 2.2), controlPoint2: NSPoint(x: 15.1, y: 2.4))
            head.line(to: NSPoint(x: 14.9, y: 8.4))
            head.curve(to: NSPoint(x: 9, y: 15.4), controlPoint1: NSPoint(x: 16.3, y: 12.4), controlPoint2: NSPoint(x: 13.2, y: 15.4))
            head.curve(to: NSPoint(x: 3.1, y: 8.4), controlPoint1: NSPoint(x: 4.8, y: 15.4), controlPoint2: NSPoint(x: 1.7, y: 12.4))
            head.close()
            NSColor.black.set()
            let eyes = [NSRect(x: 5.1, y: 8.2, width: 2.3, height: 3.1), NSRect(x: 10.6, y: 8.2, width: 2.3, height: 3.1)]
            if filled {
                head.fill()
                NSGraphicsContext.current?.compositingOperation = .clear
                eyes.forEach { NSBezierPath(ovalIn: $0).fill() }
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            } else {
                head.lineWidth = 1.4
                head.lineJoinStyle = .round
                head.stroke()
                eyes.forEach { NSBezierPath(ovalIn: $0).fill() }
            }
            if working {
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: NSRect(x: 12.2, y: 11.2, width: 6.6, height: 6.6)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSBezierPath(ovalIn: NSRect(x: 13.4, y: 12.4, width: 4.2, height: 4.2)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "AI 干活时我们干什么"
        return image
    }
}
