import AppKit

/// Desktop tools are drawn with their contact point at the mouse hotspot.
/// No global cursor hiding: the view uses a transparent cursor only in its active region.
enum InteractionArtwork {
    static let clearCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus(); NSColor.clear.setFill(); NSRect(x: 0, y: 0, width: 2, height: 2).fill(); image.unlockFocus()
        return NSCursor(image: image, hotSpot: .zero)
    }()

    static func cloth(at point: CGPoint, pressure: CGFloat, angle: CGFloat, context c: CGContext) {
        c.saveGState()
        c.translateBy(x: point.x, y: point.y)
        c.rotate(by: angle)
        c.scaleBy(x: 1 + pressure * 0.06, y: 1 - pressure * 0.10)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -31, y: 26))
        path.addCurve(to: CGPoint(x: 31, y: 25), control1: CGPoint(x: -12, y: 31), control2: CGPoint(x: 13, y: 24))
        path.addQuadCurve(to: CGPoint(x: 36, y: -23), control: CGPoint(x: 42, y: 0))
        path.addCurve(to: CGPoint(x: -32, y: -28), control1: CGPoint(x: 17, y: -33), control2: CGPoint(x: -8, y: -24))
        path.addQuadCurve(to: CGPoint(x: -31, y: 26), control: CGPoint(x: -42, y: -2))
        path.closeSubpath()
        c.setShadow(offset: CGSize(width: 2 - pressure, height: -4 + pressure * 2.7), blur: 7 - pressure * 4,
                    color: NSColor.black.withAlphaComponent(0.25).cgColor)
        c.setFillColor(NSColor(srgbRed: 0.55, green: 0.70, blue: 0.62, alpha: 1).cgColor)
        c.addPath(path); c.fillPath()
        c.setShadow(offset: .zero, blur: 0, color: nil)
        c.saveGState(); c.addPath(path); c.clip()
        let colors = [NSColor(srgbRed: 0.82, green: 0.88, blue: 0.76, alpha: 1).cgColor,
                      NSColor(srgbRed: 0.54, green: 0.69, blue: 0.58, alpha: 1).cgColor,
                      NSColor(srgbRed: 0.33, green: 0.51, blue: 0.43, alpha: 1).cgColor]
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.54, 1]) {
            c.drawLinearGradient(g, start: CGPoint(x: -27, y: 30), end: CGPoint(x: 30, y: -30), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        // Dense, deterministic loops of terry weave stay attached to the fabric.
        c.setLineWidth(0.48)
        for row in 0..<30 {
            for col in 0..<35 {
                let x = CGFloat(col) * 2.3 - 39 + (row.isMultiple(of: 2) ? 0 : 0.8)
                let y = CGFloat(row) * 2.25 - 34
                let variation = CGFloat((row * 13 + col * 7) % 11) / 11
                c.setStrokeColor(NSColor(white: 1, alpha: 0.15 + variation * 0.2).cgColor)
                c.strokeEllipse(in: CGRect(x: x, y: y, width: 1.3, height: 1.65))
                c.setStrokeColor(NSColor(white: 0.12, alpha: 0.06).cgColor)
                c.move(to: CGPoint(x: x + 1, y: y - 0.5)); c.addLine(to: CGPoint(x: x + 1.7, y: y - 0.5)); c.strokePath()
            }
        }
        // A diagonal fold loses height as the cloth is pressed against the glass.
        c.setStrokeColor(NSColor(srgbRed: 0.20, green: 0.36, blue: 0.29, alpha: 0.23 - pressure * 0.08).cgColor)
        c.setLineWidth(3.2 - pressure)
        c.move(to: CGPoint(x: -29, y: 17)); c.addCurve(to: CGPoint(x: 29, y: -18), control1: CGPoint(x: -11, y: 1), control2: CGPoint(x: 9, y: 8)); c.strokePath()
        c.setStrokeColor(NSColor.white.withAlphaComponent(0.3 - pressure * 0.12).cgColor)
        c.setLineWidth(1.3)
        c.move(to: CGPoint(x: -28, y: 19)); c.addCurve(to: CGPoint(x: 28, y: -15), control1: CGPoint(x: -10, y: 3), control2: CGPoint(x: 8, y: 10)); c.strokePath()
        c.restoreGState()
        c.setStrokeColor(NSColor(srgbRed: 0.28, green: 0.46, blue: 0.37, alpha: 0.8).cgColor)
        c.setLineWidth(2.3); c.addPath(path); c.strokePath()
        c.saveGState(); c.scaleBy(x: 0.9, y: 0.87)
        c.setStrokeColor(NSColor(srgbRed: 0.92, green: 0.94, blue: 0.82, alpha: 0.8).cgColor)
        c.setLineWidth(0.7); c.setLineDash(phase: 0, lengths: [1.3, 1.7]); c.addPath(path); c.strokePath()
        c.restoreGState()
        // Turned-down corner and its short seam.
        c.setFillColor(NSColor(srgbRed: 0.77, green: 0.84, blue: 0.72, alpha: 1).cgColor)
        c.move(to: CGPoint(x: 24, y: -25)); c.addLine(to: CGPoint(x: 36, y: -23)); c.addLine(to: CGPoint(x: 33, y: -11)); c.closePath(); c.fillPath()
        c.restoreGState()
    }

    static func finger(at point: CGPoint, pressure: CGFloat, rebound: CGFloat, flipped: Bool, mirrored: Bool, context c: CGContext) {
        c.saveGState()
        c.translateBy(x: point.x, y: point.y)
        c.rotate(by: flipped ? .pi + 0.16 : -0.22)
        c.scaleBy(x: (mirrored ? -1 : 1) * 0.76, y: 0.76)
        // The pad remains at (0, 0), including while pressed or rebounding.
        c.scaleBy(x: 1 + pressure * 0.07 - rebound * 0.025, y: 1 - pressure * 0.055 + rebound * 0.025)
        let hand = CGMutablePath()
        hand.move(to: CGPoint(x: -13, y: -52))
        hand.addCurve(to: CGPoint(x: -12, y: 5), control1: CGPoint(x: -15, y: -33), control2: CGPoint(x: -14, y: -10))
        hand.addCurve(to: CGPoint(x: 13, y: 4), control1: CGPoint(x: -10, y: 23), control2: CGPoint(x: 13, y: 22))
        hand.addLine(to: CGPoint(x: 16, y: -39))
        hand.addCurve(to: CGPoint(x: 30, y: -42), control1: CGPoint(x: 19, y: -27), control2: CGPoint(x: 30, y: -30))
        hand.addCurve(to: CGPoint(x: 43, y: -49), control1: CGPoint(x: 34, y: -33), control2: CGPoint(x: 43, y: -39))
        hand.addCurve(to: CGPoint(x: 54, y: -61), control1: CGPoint(x: 49, y: -42), control2: CGPoint(x: 55, y: -48))
        hand.addCurve(to: CGPoint(x: 46, y: -96), control1: CGPoint(x: 58, y: -78), control2: CGPoint(x: 53, y: -89))
        hand.addCurve(to: CGPoint(x: 9, y: -98), control1: CGPoint(x: 35, y: -106), control2: CGPoint(x: 20, y: -105))
        hand.addCurve(to: CGPoint(x: -13, y: -52), control1: CGPoint(x: -8, y: -88), control2: CGPoint(x: -25, y: -65))
        hand.closeSubpath()
        c.setShadow(offset: CGSize(width: 3, height: -5 + pressure * 3), blur: 7 - pressure * 4,
                    color: NSColor.black.withAlphaComponent(0.23).cgColor)
        c.setFillColor(NSColor(srgbRed: 0.81, green: 0.55, blue: 0.38, alpha: 1).cgColor)
        c.addPath(hand); c.fillPath()
        c.setShadow(offset: .zero, blur: 0, color: nil)
        c.saveGState(); c.addPath(hand); c.clip()
        let colors = [NSColor(srgbRed: 0.98, green: 0.80, blue: 0.63, alpha: 1).cgColor,
                      NSColor(srgbRed: 0.87, green: 0.63, blue: 0.45, alpha: 1).cgColor,
                      NSColor(srgbRed: 0.66, green: 0.40, blue: 0.27, alpha: 1).cgColor]
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.58, 1]) {
            c.drawLinearGradient(g, start: CGPoint(x: -12, y: 14), end: CGPoint(x: 50, y: -55), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        // A narrow diffuse reflection follows the raised index finger.
        let light = [NSColor.white.withAlphaComponent(0.26).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: light as CFArray, locations: [0, 1]) {
            c.saveGState(); c.scaleBy(x: 0.35, y: 1)
            c.drawRadialGradient(g, startCenter: CGPoint(x: -9, y: -20), startRadius: 0, endCenter: CGPoint(x: -9, y: -20), endRadius: 45, options: [])
            c.restoreGState()
        }
        c.restoreGState()
        c.setStrokeColor(NSColor(srgbRed: 0.49, green: 0.28, blue: 0.18, alpha: 0.65).cgColor)
        c.setLineWidth(0.9); c.addPath(hand); c.strokePath()
        // A small natural nail helps the fingertip read clearly at desktop scale.
        let nail = CGPath(roundedRect: CGRect(x: -8, y: 0, width: 17, height: 13), cornerWidth: 5, cornerHeight: 5, transform: nil)
        c.setFillColor(NSColor(srgbRed: 0.98, green: 0.82 + pressure * 0.035, blue: 0.73 + pressure * 0.035, alpha: 1).cgColor)
        c.addPath(nail); c.fillPath()
        c.setStrokeColor(NSColor(srgbRed: 0.66, green: 0.42, blue: 0.32, alpha: 0.48).cgColor)
        c.setLineWidth(0.55); c.addPath(nail); c.strokePath()
        c.setStrokeColor(NSColor.white.withAlphaComponent(0.7).cgColor); c.setLineWidth(1.1)
        c.move(to: CGPoint(x: -5, y: 10)); c.addQuadCurve(to: CGPoint(x: 6, y: 10), control: CGPoint(x: 0, y: 14)); c.strokePath()
        c.setLineCap(.round)
        for y: CGFloat in [-22, -26, -46] {
            c.setStrokeColor(NSColor(srgbRed: 0.56, green: 0.33, blue: 0.22, alpha: 0.32).cgColor)
            c.setLineWidth(0.65)
            c.move(to: CGPoint(x: -7, y: y)); c.addQuadCurve(to: CGPoint(x: 9, y: y - 1), control: CGPoint(x: 1, y: y + 2)); c.strokePath()
        }
        // Folded fingers and thumb, separated by soft creases rather than thick outlines.
        for (x, y): (CGFloat, CGFloat) in [(18, -44), (31, -49), (44, -58)] {
            c.setStrokeColor(NSColor(srgbRed: 0.48, green: 0.28, blue: 0.18, alpha: 0.35).cgColor)
            c.setLineWidth(1)
            c.move(to: CGPoint(x: x, y: y)); c.addQuadCurve(to: CGPoint(x: x + 4, y: y - 16), control: CGPoint(x: x - 2, y: y - 9)); c.strokePath()
        }
        c.setStrokeColor(NSColor(srgbRed: 0.56, green: 0.34, blue: 0.22, alpha: 0.38).cgColor)
        c.move(to: CGPoint(x: -13, y: -55)); c.addCurve(to: CGPoint(x: 17, y: -79), control1: CGPoint(x: 0, y: -49), control2: CGPoint(x: 12, y: -65)); c.strokePath()
        c.restoreGState()
    }
}
