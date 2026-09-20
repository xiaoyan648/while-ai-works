import AppKit

extension PlayView {
    func drawBubble(_ bubble: Bubble, at time: TimeInterval, context c: CGContext) {
        let radius = bubble.radius
        let p = bubble.point
        let popAge = bubble.poppedAt.map { time - $0 }
        let pressure = bubble.pressedAt.map { min(1, max(0, (time - $0) / 0.12)) } ?? 0
        let appear = reduceMotion ? 1 : min(1, max(0, (time - bubble.appearedAt) / 0.26))
        c.saveGState()
        c.translateBy(x: p.x, y: p.y)
        c.setAlpha(appear)
        // The square welded film is nearly clear; the desktop remains visible through it.
        let film = CGRect(x: -32, y: -32, width: 64, height: 64)
        c.setFillColor(NSColor.white.withAlphaComponent(0.035).cgColor)
        c.addPath(CGPath(roundedRect: film, cornerWidth: 7, cornerHeight: 7, transform: nil)); c.fillPath()
        c.setLineWidth(0.7)
        c.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor)
        c.move(to: CGPoint(x: -30, y: -25)); c.addLine(to: CGPoint(x: -30, y: 25))
        c.addQuadCurve(to: CGPoint(x: -25, y: 30), control: CGPoint(x: -30, y: 30))
        c.addLine(to: CGPoint(x: 25, y: 30)); c.strokePath()
        c.setStrokeColor(NSColor.black.withAlphaComponent(0.065).cgColor)
        c.move(to: CGPoint(x: -25, y: -30)); c.addLine(to: CGPoint(x: 25, y: -30))
        c.addQuadCurve(to: CGPoint(x: 30, y: -25), control: CGPoint(x: 30, y: -30))
        c.addLine(to: CGPoint(x: 30, y: 25)); c.strokePath()

        if let age = popAge {
            let bounce = reduceMotion ? 0 : exp(-age * 21) * sin(age * 56) * 0.06
            c.scaleBy(x: 1 + bounce, y: 1 - bounce)
            drawDeflated(radius: radius, seed: bubble.seed, context: c)
        } else {
            let squash = reduceMotion ? 0 : pressure
            c.scaleBy(x: 1 + squash * 0.035, y: 1 - squash * 0.21)
            let rect = CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)
            let rim = irregularCircle(radius: radius, seed: bubble.seed, roughness: 0.015)
            c.setShadow(offset: CGSize(width: 0, height: -2.3), blur: 3.2,
                        color: NSColor.black.withAlphaComponent(0.19).cgColor)
            c.setFillColor(NSColor.white.withAlphaComponent(0.045).cgColor)
            c.addPath(rim); c.fillPath()
            c.setShadow(offset: .zero, blur: 0, color: nil)
            c.saveGState(); c.addPath(rim); c.clip()
            let colors = [NSColor.white.withAlphaComponent(0.32).cgColor,
                          NSColor.white.withAlphaComponent(0.055).cgColor,
                          NSColor(white: 0.55, alpha: 0.035).cgColor,
                          NSColor(white: 0.11, alpha: 0.20).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                                         locations: [0, 0.27, 0.73, 1]) {
                c.drawRadialGradient(gradient, startCenter: CGPoint(x: -radius * 0.28, y: radius * 0.35), startRadius: 0,
                                     endCenter: .zero, endRadius: radius, options: [.drawsAfterEndLocation])
            }
            // Broad curved reflections, like a window reflected in a thin plastic dome.
            c.setStrokeColor(NSColor.white.withAlphaComponent(0.76 - pressure * 0.2).cgColor)
            c.setLineWidth(2.5); c.setLineCap(.round)
            c.addArc(center: CGPoint(x: 0, y: -1), radius: radius * 0.79,
                     startAngle: 0.53 * .pi, endAngle: 0.91 * .pi, clockwise: false); c.strokePath()
            c.setStrokeColor(NSColor.white.withAlphaComponent(0.31).cgColor)
            c.setLineWidth(1)
            c.addArc(center: .zero, radius: radius * 0.85,
                     startAngle: -0.43 * .pi, endAngle: 0.12 * .pi, clockwise: false); c.strokePath()
            c.setFillColor(NSColor.white.withAlphaComponent(0.60).cgColor)
            c.fillEllipse(in: CGRect(x: -radius * 0.48, y: radius * 0.41, width: radius * 0.19, height: radius * 0.10))
            if pressure > 0 {
                let indentation = [NSColor.black.withAlphaComponent(pressure * 0.24).cgColor,
                                   NSColor.white.withAlphaComponent(pressure * 0.13).cgColor,
                                   NSColor.clear.cgColor]
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: indentation as CFArray, locations: [0, 0.68, 1]) {
                    c.drawRadialGradient(gradient, startCenter: bubble.contact, startRadius: 0,
                                         endCenter: bubble.contact, endRadius: radius * 0.75, options: [])
                }
            }
            c.restoreGState()
            c.setLineWidth(0.8)
            c.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
            c.addPath(rim); c.strokePath()
            c.setStrokeColor(NSColor.black.withAlphaComponent(0.18).cgColor)
            c.strokeEllipse(in: rect.insetBy(dx: 2, dy: 2))
            c.setStrokeColor(NSColor.white.withAlphaComponent(0.38).cgColor)
            c.strokeEllipse(in: rect.insetBy(dx: 3.2, dy: 3.2))
        }
        c.restoreGState()
    }

    private func drawDeflated(radius: CGFloat, seed: CGFloat, context c: CGContext) {
        let shape = irregularCircle(radius: radius * 0.95, seed: seed, roughness: 0.055)
        c.saveGState(); c.addPath(shape); c.clip()
        let colors = [NSColor(white: 0.18, alpha: 0.12).cgColor,
                      NSColor.white.withAlphaComponent(0.045).cgColor,
                      NSColor.white.withAlphaComponent(0.22).cgColor]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.6, 1]) {
            c.drawRadialGradient(gradient, startCenter: CGPoint(x: 2, y: -2), startRadius: 0,
                                 endCenter: .zero, endRadius: radius, options: [.drawsAfterEndLocation])
        }
        let pinch = CGPoint(x: sin(seed) * radius * 0.18, y: cos(seed) * radius * 0.13)
        for index in 0..<9 {
            let angle = CGFloat(index) * .pi * 2 / 9 + seed * 0.05
            let edge = CGPoint(x: cos(angle) * radius * 0.96, y: sin(angle) * radius * 0.96)
            let inner = CGPoint(x: pinch.x + cos(angle + 0.4) * radius * 0.20,
                                y: pinch.y + sin(angle + 0.4) * radius * 0.20)
            let bend = CGPoint(x: edge.x * 0.5 + sin(seed + CGFloat(index)) * 4,
                               y: edge.y * 0.5 + cos(seed + CGFloat(index)) * 4)
            c.setStrokeColor(NSColor.black.withAlphaComponent(index.isMultiple(of: 2) ? 0.16 : 0.08).cgColor)
            c.setLineWidth(0.6)
            c.move(to: edge); c.addQuadCurve(to: inner, control: bend); c.strokePath()
            c.setStrokeColor(NSColor.white.withAlphaComponent(0.54).cgColor)
            c.setLineWidth(0.9)
            c.move(to: CGPoint(x: edge.x + 1, y: edge.y + 0.7))
            c.addQuadCurve(to: CGPoint(x: inner.x + 1, y: inner.y + 0.7), control: CGPoint(x: bend.x + 1, y: bend.y + 0.7)); c.strokePath()
        }
        c.restoreGState()
        c.setStrokeColor(NSColor.white.withAlphaComponent(0.5).cgColor)
        c.setLineWidth(0.8); c.addPath(shape); c.strokePath()
        c.setStrokeColor(NSColor.black.withAlphaComponent(0.13).cgColor)
        c.setLineWidth(0.5); c.strokeEllipse(in: CGRect(x: -radius + 2, y: -radius + 2, width: radius * 2 - 4, height: radius * 2 - 4))
    }
    private func irregularCircle(radius: CGFloat, seed: CGFloat, roughness: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for index in 0...72 {
            let angle = CGFloat(index) / 72 * .pi * 2
            let r = radius * (1 + roughness * sin(angle * 7 + seed) + roughness * 0.4 * cos(angle * 11 + seed))
            let point = CGPoint(x: cos(angle) * r, y: sin(angle) * r)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}
