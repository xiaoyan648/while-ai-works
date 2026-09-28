import AppKit

/// One material family for desktop HUDs, matching the menu bar's forest palette.
enum PlayChrome {
    static func color(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(value >> 16 & 255) / 255,
                           green: CGFloat(value >> 8 & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
    static let accent = color(0x2F7A63, 0x6CC6A5)
    static let ink = color(0x233C33, 0xE6F1EA)
    static let secondary = color(0x5C7268, 0xA7BEB4)
    static let gold = color(0xA66F1C, 0xE5B75C)
    static let surface = color(0xF0F5F1, 0x182C28)
    static let well = color(0xDCE8E1, 0x243E35)

    static func panel(_ rect: CGRect, radius: CGFloat = 12, context c: CGContext) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -2), blur: 8, color: NSColor.black.withAlphaComponent(0.13).cgColor)
        c.setFillColor(surface.withAlphaComponent(0.97).cgColor); c.addPath(path); c.fillPath()
        c.setShadow(offset: .zero, blur: 0, color: nil)
        c.setStrokeColor(ink.withAlphaComponent(0.10).cgColor); c.setLineWidth(0.65)
        c.addPath(path); c.strokePath()
        c.restoreGState()
    }
}

/// A rounded contact patch swept along a line. Both pixels and stain coverage use this path.
/// The hull has at most six vertices, independent of mouse speed or event frequency.
enum ClothContact {
    static let halfWidth: CGFloat = 32
    static let halfHeight: CGFloat = 26
    static let corner: CGFloat = 13
    static let angle: CGFloat = -0.10

    static func sweep(from start: CGPoint, to end: CGPoint) -> CGPath {
        var points: [CGPoint] = []
        for origin in [start, end] {
            for x in [-halfWidth + corner, halfWidth - corner] {
                for y in [-halfHeight + corner, halfHeight - corner] {
                    points.append(CGPoint(x: origin.x + x * cos(angle) - y * sin(angle),
                                          y: origin.y + x * sin(angle) + y * cos(angle)))
                }
            }
        }
        points.sort { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        func cross(_ a: CGPoint, _ b: CGPoint, _ p: CGPoint) -> CGFloat {
            (b.x-a.x)*(p.y-a.y) - (b.y-a.y)*(p.x-a.x)
        }
        func half(_ input: [CGPoint]) -> [CGPoint] {
            var result: [CGPoint] = []
            for p in input {
                while result.count >= 2 && cross(result[result.count-2], result[result.count-1], p) <= 0 { result.removeLast() }
                result.append(p)
            }
            return Array(result.dropLast())
        }
        let hull = half(points) + half(Array(points.reversed()))
        let shape = CGMutablePath()
        for index in hull.indices {
            let previous = hull[(index+hull.count-1)%hull.count]
            let point = hull[index], next = hull[(index+1)%hull.count]
            let incoming = atan2(point.y-previous.y, point.x-previous.x) - .pi/2
            let outgoing = atan2(next.y-point.y, next.x-point.x) - .pi/2
            shape.addArc(center: point, radius: corner, startAngle: incoming, endAngle: outgoing, clockwise: false)
        }
        shape.closeSubpath()
        return shape
    }
}

struct HandOrientation {
    private(set) var angle: CGFloat = -0.22
    private(set) var target: CGFloat = -0.22
    private var bottom = false
    private var right = false
    mutating func update(point: CGPoint, bounds: CGRect, pressed: Bool, delta: TimeInterval, reduceMotion: Bool) {
        // Freeze the displayed pose for the whole press, including a mid-turn press.
        guard !pressed else { target = angle; return }
        bottom = point.y < (bottom ? 122 : 88)
        right = point.x > bounds.maxX - (right ? 112 : 76)
        target = bottom ? (right ? 2.55 : .pi + 0.16) : (right ? -0.76 : -0.22)
        var distance = (target - angle).truncatingRemainder(dividingBy: 2 * .pi)
        if distance > .pi { distance -= 2 * .pi }
        if distance < -.pi { distance += 2 * .pi }
        angle += reduceMotion ? distance : distance * CGFloat(1 - exp(-max(0, delta) / 0.065))
        if abs(distance) < 0.001 { angle = target }
    }
}

struct BubbleContact {
    let entry: CGFloat
    let point: CGPoint
    static func hit(center: CGPoint, radius: CGFloat, from start: CGPoint, to end: CGPoint) -> BubbleContact? {
        let dx = end.x-start.x, dy = end.y-start.y
        let length = dx*dx + dy*dy
        let ox = start.x-center.x, oy = start.y-center.y
        let c = ox*ox + oy*oy - radius*radius
        if c <= 0 { return BubbleContact(entry: 0, point: start) }
        guard length > 0 else { return nil }
        let b = ox*dx + oy*dy
        let discriminant = b*b-length*c
        guard discriminant >= 0 else { return nil }
        let entry = (-b-sqrt(discriminant))/length
        guard entry >= 0, entry <= 1 else { return nil }
        // Use the nearest point for the finger dent, entry for chronological ordering.
        let nearest = min(1, max(0, -b/length))
        return BubbleContact(entry: entry, point: CGPoint(x: start.x+dx*nearest, y: start.y+dy*nearest))
    }
}

enum InteractionArtwork {
    static let clearCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus(); NSColor.clear.setFill(); NSRect(x: 0, y: 0, width: 2, height: 2).fill(); image.unlockFocus()
        return NSCursor(image: image, hotSpot: .zero)
    }()

    static func gradient(_ colors: [NSColor], from start: CGPoint, to end: CGPoint, context c: CGContext) {
        guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map(\.cgColor) as CFArray, locations: nil) else { return }
        c.drawLinearGradient(g, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    static func cloth(at point: CGPoint, pressure: CGFloat, angle: CGFloat, drag: CGPoint = .zero, snow: Bool = false, context c: CGContext) {
        let p = min(1, max(0, pressure)), lift = 1-p
        c.saveGState(); c.translateBy(x: point.x, y: point.y); c.rotate(by: ClothContact.angle)
        // Only the suspended corners lag; the contact patch never rotates or trails the mouse.
        let dx = min(4, max(-4, drag.x)) * 0.65
        let dy = min(4, max(-4, drag.y)) * 0.65
        let curl = lift * 3 + (angle - ClothContact.angle) * 8
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -19, y: 26))
        path.addCurve(to: CGPoint(x: 19, y: 26), control1: CGPoint(x: -5, y: 26+curl), control2: CGPoint(x: 7, y: 26+curl))
        path.addCurve(to: CGPoint(x: 32, y: 13), control1: CGPoint(x: 28+dx, y: 26+dy), control2: CGPoint(x: 32, y: 23))
        path.addLine(to: CGPoint(x: 32, y: -13))
        path.addCurve(to: CGPoint(x: 19, y: -26), control1: CGPoint(x: 32, y: -23), control2: CGPoint(x: 27-dx, y: -26-dy-curl))
        path.addCurve(to: CGPoint(x: -19, y: -26), control1: CGPoint(x: 5, y: -26-curl), control2: CGPoint(x: -8, y: -26))
        path.addCurve(to: CGPoint(x: -32, y: -13), control1: CGPoint(x: -28+dx, y: -26+dy), control2: CGPoint(x: -32, y: -22))
        path.addLine(to: CGPoint(x: -32, y: 13))
        path.addCurve(to: CGPoint(x: -19, y: 26), control1: CGPoint(x: -32, y: 23), control2: CGPoint(x: -29-dx, y: 26-dy))
        path.closeSubpath()
        c.setShadow(offset: CGSize(width: 0, height: -1.5-lift*3), blur: 2+lift*5, color: NSColor.black.withAlphaComponent(0.18).cgColor)
        c.setFillColor(NSColor(srgbRed: 0.57, green: 0.72, blue: 0.65, alpha: 1).cgColor); c.addPath(path); c.fillPath()
        c.setShadow(offset: .zero, blur: 0, color: nil)
        c.saveGState(); c.addPath(path); c.clip()
        gradient([NSColor(srgbRed: 0.80, green: 0.87, blue: 0.80, alpha: 1),
                  NSColor(srgbRed: 0.59, green: 0.74, blue: 0.65, alpha: 1),
                  NSColor(srgbRed: 0.43, green: 0.61, blue: 0.53, alpha: 1)],
                 from: CGPoint(x: -25, y: 32), to: CGPoint(x: 30, y: -32), context: c)
        // A few translucent fibres suggest weave without pixel-sized terry noise.
        c.setLineWidth(0.45); c.setStrokeColor(NSColor.white.withAlphaComponent(0.095).cgColor)
        for row in 0..<12 {
            let y = CGFloat(row)*5-28
            c.move(to: CGPoint(x: -33, y: y)); c.addQuadCurve(to: CGPoint(x: 33, y: y+1), control: CGPoint(x: dx, y: y+curl)); c.strokePath()
        }
        c.setLineCap(.round)
        c.setStrokeColor(NSColor(srgbRed: 0.24, green: 0.43, blue: 0.34, alpha: 0.06+lift*0.11).cgColor)
        c.setLineWidth(2+lift*1.5)
        c.move(to: CGPoint(x: -28, y: 17)); c.addCurve(to: CGPoint(x: 26, y: -17), control1: CGPoint(x: -9+dx, y: -2+curl), control2: CGPoint(x: 10, y: 8+dy)); c.strokePath()
        c.setStrokeColor(NSColor.white.withAlphaComponent(0.09+lift*0.18).cgColor); c.setLineWidth(1.2)
        c.move(to: CGPoint(x: -28, y: 19)); c.addCurve(to: CGPoint(x: 26, y: -15), control1: CGPoint(x: -9+dx, y: curl), control2: CGPoint(x: 10, y: 10+dy)); c.strokePath()
        c.restoreGState()
        c.setLineWidth(0.65); c.setStrokeColor(NSColor(srgbRed: 0.31, green: 0.49, blue: 0.40, alpha: 0.32).cgColor)
        c.addPath(path); c.strokePath()
        c.saveGState(); c.scaleBy(x: 0.94, y: 0.93)
        c.setStrokeColor(NSColor.white.withAlphaComponent(0.34).cgColor); c.setLineWidth(0.6); c.addPath(path); c.strokePath(); c.restoreGState()
        // Small lifted hem, smoothly flattening on contact.
        c.setFillColor(NSColor(srgbRed: 0.82, green: 0.88, blue: 0.81, alpha: 0.7).cgColor)
        c.move(to: CGPoint(x: 21-dx, y: -25-curl)); c.addQuadCurve(to: CGPoint(x: 31, y: -14+lift*3), control: CGPoint(x: 33, y: -27-dy))
        c.addQuadCurve(to: CGPoint(x: 21-dx, y: -25-curl), control: CGPoint(x: 25, y: -17)); c.fillPath()
        // The paw presses the cloth; only its wrist and the lifted hem lag behind.
        c.saveGState(); c.translateBy(x: dx * 0.2, y: 5 + lift * 2); c.scaleBy(x: 0.68, y: 0.68)
        paw(at: .zero, pressure: p, rebound: 0, angle: .pi + angle * 0.15, snow: snow, pads: false, context: c)
        c.restoreGState()
        c.restoreGState()
    }

    static func finger(at point: CGPoint, pressure: CGFloat, rebound: CGFloat, flipped: Bool, mirrored: Bool, context c: CGContext) {
        finger(at: point, pressure: pressure, rebound: rebound,
               angle: flipped ? .pi+0.16 : -0.22, mirrored: mirrored, context: c)
    }
    static func finger(at point: CGPoint, pressure: CGFloat, rebound: CGFloat, angle: CGFloat, mirrored: Bool = false, snow: Bool = false, context c: CGContext) {
        paw(at: point, pressure: pressure, rebound: rebound, angle: angle, snow: snow, pads: true, mirrored: mirrored, context: c)
    }

    /// Four rounded toes and a short wrist; the central pad remains at the input hotspot.
    static func paw(at point: CGPoint, pressure: CGFloat, rebound: CGFloat = 0, angle: CGFloat = 0,
                    snow: Bool = false, pads: Bool = true, mirrored: Bool = false, context c: CGContext) {
        let p = min(1, max(0, pressure))
        c.saveGState(); defer { c.restoreGState() }
        c.translateBy(x: point.x, y: point.y); c.rotate(by: angle)
        c.scaleBy(x: (mirrored ? -1 : 1) * (1 + p * 0.07), y: 1 - p * 0.07 + rebound * 0.025)
        let outline = CGMutablePath()
        outline.move(to: CGPoint(x: -12, y: -39))
        outline.addCurve(to: CGPoint(x: -22, y: -4), control1: CGPoint(x: -12, y: -24), control2: CGPoint(x: -26, y: -17))
        outline.addCurve(to: CGPoint(x: -15, y: 16), control1: CGPoint(x: -33, y: 12), control2: CGPoint(x: -23, y: 23))
        outline.addCurve(to: CGPoint(x: -2, y: 24), control1: CGPoint(x: -19, y: 32), control2: CGPoint(x: -3, y: 36))
        outline.addCurve(to: CGPoint(x: 13, y: 18), control1: CGPoint(x: 5, y: 36), control2: CGPoint(x: 22, y: 30))
        outline.addCurve(to: CGPoint(x: 22, y: -2), control1: CGPoint(x: 30, y: 25), control2: CGPoint(x: 32, y: 5))
        outline.addCurve(to: CGPoint(x: 12, y: -39), control1: CGPoint(x: 27, y: -15), control2: CGPoint(x: 13, y: -24))
        outline.addQuadCurve(to: CGPoint(x: -12, y: -39), control: CGPoint(x: 0, y: -43)); outline.closeSubpath()
        c.setShadow(offset: CGSize(width: 0, height: -2 - (1-p)*2), blur: 4, color: NSColor.black.withAlphaComponent(0.16).cgColor)
        c.setFillColor((snow ? NSColor(white: 0.95, alpha: 1) : NSColor(srgbRed: 0.075, green: 0.095, blue: 0.10, alpha: 1)).cgColor)
        c.addPath(outline); c.fillPath(); c.setShadow(offset: .zero, blur: 0, color: nil)
        c.saveGState(); c.addPath(outline); c.clip()
        gradient(snow ? [NSColor(srgbRed: 1, green: 0.99, blue: 0.94, alpha: 1), NSColor(srgbRed: 0.79, green: 0.85, blue: 0.81, alpha: 1)] :
                    [NSColor(srgbRed: 0.17, green: 0.22, blue: 0.21, alpha: 1), NSColor(srgbRed: 0.055, green: 0.07, blue: 0.08, alpha: 1)],
                 from: CGPoint(x: -22, y: 28), to: CGPoint(x: 20, y: -40), context: c)
        c.restoreGState()
        c.setLineWidth(0.7); c.setStrokeColor((snow ? NSColor.black.withAlphaComponent(0.13) : NSColor.white.withAlphaComponent(0.12)).cgColor)
        c.addPath(outline); c.strokePath()
        if pads {
            c.setFillColor((snow ? NSColor(srgbRed: 0.77, green: 0.57, blue: 0.57, alpha: 1) : NSColor(srgbRed: 0.43, green: 0.37, blue: 0.40, alpha: 1)).cgColor)
            c.fillEllipse(in: CGRect(x: -11-p, y: -9, width: 22+p*2, height: 18-p*2))
            for (x,y,w,h): (CGFloat,CGFloat,CGFloat,CGFloat) in [(-20,7,9,11),(-12,19,9,11),(2,20,9,11),(16,8,9,11)] {
                c.fillEllipse(in: CGRect(x: x, y: y-p*2, width: w, height: h-p))
            }
        } else {
            c.setStrokeColor((snow ? NSColor.black.withAlphaComponent(0.13) : NSColor.white.withAlphaComponent(0.15)).cgColor)
            c.setLineWidth(0.8); c.setLineCap(.round)
            for x: CGFloat in [-14, 0, 14] {
                c.move(to: CGPoint(x: x, y: 17)); c.addQuadCurve(to: CGPoint(x: x-1, y: 9), control: CGPoint(x: x+1, y: 12)); c.strokePath()
            }
        }
    }

    static func pawPrintPath(center: CGPoint, radius: CGFloat, angle: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.addEllipse(in: CGRect(x: -0.33, y: -0.49, width: 0.66, height: 0.60))
        for (x,y): (CGFloat,CGFloat) in [(-0.49,0.14),(-0.26,0.39),(0.03,0.42),(0.28,0.18)] {
            p.addEllipse(in: CGRect(x: x, y: y, width: 0.24, height: 0.30))
        }
        var transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angle).scaledBy(x: radius, y: radius)
        return p.copy(using: &transform)!
    }
}
