import AppKit

extension PlayView {
    func drawWoodfish(at time: TimeInterval, context c: CGContext) {
        let age = time - woodHitAt
        let bounce = reduceMotion ? 0 : exp(-age * 13) * sin(age * 34)
        let center = woodCenter
        c.saveGState(); c.translateBy(x: center.x, y: center.y)
        // A low, woven cushion anchors the wooden instrument to the desktop.
        c.setShadow(offset: CGSize(width: 0, height: -5), blur: 12, color: NSColor.black.withAlphaComponent(0.24).cgColor)
        c.setFillColor(NSColor(srgbRed: 0.19, green: 0.25, blue: 0.22, alpha: 0.96).cgColor)
        c.fillEllipse(in: CGRect(x: -88, y: -61, width: 176, height: 40))
        c.setShadow(offset: .zero, blur: 0, color: nil)
        c.setStrokeColor(NSColor(srgbRed: 0.55, green: 0.59, blue: 0.43, alpha: 0.7).cgColor)
        c.setLineWidth(1.2)
        c.strokeEllipse(in: CGRect(x: -83, y: -55, width: 166, height: 28))
        c.saveGState()
        c.translateBy(x: 0, y: -CGFloat(bounce) * 3)
        c.scaleBy(x: 1 + CGFloat(bounce) * 0.018, y: 1 - CGFloat(bounce) * 0.035)
        let body = CGMutablePath()
        body.move(to: CGPoint(x: -79, y: -25))
        body.addCurve(to: CGPoint(x: -57, y: 49), control1: CGPoint(x: -99, y: 5), control2: CGPoint(x: -82, y: 34))
        body.addCurve(to: CGPoint(x: 54, y: 54), control1: CGPoint(x: -24, y: 73), control2: CGPoint(x: 28, y: 77))
        body.addCurve(to: CGPoint(x: 86, y: 1), control1: CGPoint(x: 78, y: 42), control2: CGPoint(x: 99, y: 18))
        body.addCurve(to: CGPoint(x: 57, y: -39), control1: CGPoint(x: 84, y: -22), control2: CGPoint(x: 80, y: -29))
        body.addCurve(to: CGPoint(x: -79, y: -25), control1: CGPoint(x: 16, y: -59), control2: CGPoint(x: -44, y: -53))
        body.closeSubpath()
        c.saveGState(); c.addPath(body); c.clip()
        let colors = [NSColor(srgbRed: 0.82, green: 0.52, blue: 0.27, alpha: 1).cgColor,
                      NSColor(srgbRed: 0.59, green: 0.30, blue: 0.13, alpha: 1).cgColor,
                      NSColor(srgbRed: 0.30, green: 0.13, blue: 0.055, alpha: 1).cgColor]
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.6, 1]) {
            c.drawRadialGradient(g, startCenter: CGPoint(x: -28, y: 48), startRadius: 0,
                                 endCenter: CGPoint(x: 5, y: 4), endRadius: 107, options: [.drawsAfterEndLocation])
        }
        // Irregular, closely spaced growth rings follow the convex shell.
        for index in 0..<38 {
            let y = CGFloat(index) * 4 - 63
            let offset = sin(CGFloat(index) * 1.8) * 3
            c.setStrokeColor(NSColor(srgbRed: 0.25, green: 0.095, blue: 0.035, alpha: 0.16 + Double(index % 3) * 0.045).cgColor)
            c.setLineWidth(index.isMultiple(of: 4) ? 1.0 : 0.45)
            c.move(to: CGPoint(x: -103, y: y))
            c.addCurve(to: CGPoint(x: 103, y: y + offset), control1: CGPoint(x: -36, y: y + 24 + offset),
                       control2: CGPoint(x: 27, y: y - 15 + offset)); c.strokePath()
            c.setStrokeColor(NSColor(srgbRed: 0.98, green: 0.76, blue: 0.45, alpha: 0.10).cgColor)
            c.move(to: CGPoint(x: -103, y: y + 1))
            c.addCurve(to: CGPoint(x: 103, y: y + offset + 1), control1: CGPoint(x: -36, y: y + 25 + offset),
                       control2: CGPoint(x: 27, y: y - 14 + offset)); c.strokePath()
        }
        c.restoreGState()
        c.setStrokeColor(NSColor(srgbRed: 0.95, green: 0.72, blue: 0.40, alpha: 0.65).cgColor)
        c.setLineWidth(1.0); c.addPath(body); c.strokePath()
        // The characteristic hollow slit curls across the front of the fish.
        let mouth = CGMutablePath()
        mouth.move(to: CGPoint(x: 82, y: 10))
        mouth.addCurve(to: CGPoint(x: -38, y: -16), control1: CGPoint(x: 41, y: -9), control2: CGPoint(x: -4, y: -29))
        mouth.addCurve(to: CGPoint(x: -47, y: -1), control1: CGPoint(x: -50, y: -13), control2: CGPoint(x: -54, y: -6))
        c.setLineCap(.round)
        c.setStrokeColor(NSColor(srgbRed: 0.94, green: 0.65, blue: 0.31, alpha: 0.8).cgColor)
        c.setLineWidth(8); c.addPath(mouth); c.strokePath()
        c.setStrokeColor(NSColor(srgbRed: 0.14, green: 0.055, blue: 0.02, alpha: 1).cgColor)
        c.setLineWidth(5.5); c.addPath(mouth); c.strokePath()
        c.setFillColor(NSColor(srgbRed: 0.10, green: 0.035, blue: 0.012, alpha: 1).cgColor)
        c.fillEllipse(in: CGRect(x: -53, y: -11, width: 13, height: 13))
        // A subtle carved eye and curved cheek make the silhouette recognizable.
        c.setStrokeColor(NSColor(srgbRed: 0.36, green: 0.17, blue: 0.065, alpha: 0.8).cgColor)
        c.setLineWidth(2)
        c.strokeEllipse(in: CGRect(x: 46, y: 18, width: 17, height: 15))
        c.setFillColor(NSColor(srgbRed: 0.34, green: 0.14, blue: 0.05, alpha: 1).cgColor)
        c.fillEllipse(in: CGRect(x: 51, y: 22, width: 6, height: 6))
        c.restoreGState()

        // The mallet pivots down exactly when the sound and +1 are emitted.
        c.saveGState()
        c.translateBy(x: 95, y: 61)
        let tap = age < 0.3 && !reduceMotion ? exp(-age * 18) : 0
        c.rotate(by: CGFloat(-0.42 + tap * 0.65))
        c.setShadow(offset: CGSize(width: 2, height: -3), blur: 4, color: NSColor.black.withAlphaComponent(0.18).cgColor)
        c.setStrokeColor(NSColor(srgbRed: 0.63, green: 0.38, blue: 0.19, alpha: 1).cgColor)
        c.setLineWidth(8); c.move(to: CGPoint(x: 0, y: 0)); c.addLine(to: CGPoint(x: -73, y: 15)); c.strokePath()
        c.setStrokeColor(NSColor(srgbRed: 0.94, green: 0.71, blue: 0.43, alpha: 0.8).cgColor)
        c.setLineWidth(1.4); c.move(to: CGPoint(x: -1, y: 2)); c.addLine(to: CGPoint(x: -68, y: 17)); c.strokePath()
        c.setFillColor(NSColor(srgbRed: 0.83, green: 0.61, blue: 0.35, alpha: 1).cgColor)
        c.fillEllipse(in: CGRect(x: -93, y: 2, width: 33, height: 30))
        c.setShadow(offset: .zero, blur: 0, color: nil)
        c.setFillColor(NSColor(srgbRed: 1, green: 0.86, blue: 0.61, alpha: 0.55).cgColor)
        c.fillEllipse(in: CGRect(x: -87, y: 19, width: 15, height: 7))
        c.restoreGState()

        let label = "当前 \(state.woodBalance.formatted()) · 敲击 \(state.totalStrikes.formatted()) 次" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let size = label.size(withAttributes: attrs)
        let pill = CGRect(x: -size.width / 2 - 12, y: -89, width: size.width + 24, height: 25)
        NSColor.playInk.withAlphaComponent(0.88).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 12, yRadius: 12).fill()
        label.draw(at: CGPoint(x: -size.width / 2, y: -83), withAttributes: attrs)
        for strike in floatingStrikes {
            let progress = min(1, (time - strike.time) / 0.95)
            let y: CGFloat = reduceMotion ? 98 : 75 + CGFloat(progress) * 58
            let alpha = 1 - progress * progress
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 23, weight: .semibold, width: .standard),
                .foregroundColor: strike.delta > 0 ? NSColor(srgbRed: 0.95, green: 0.82, blue: 0.49, alpha: alpha) : NSColor(srgbRed: 0.82, green: 0.37, blue: 0.27, alpha: alpha),
                .strokeColor: NSColor.black.withAlphaComponent(alpha * 0.2), .strokeWidth: -2
            ]
            ((strike.delta > 0 ? "+1" : "−1") as NSString).draw(at: CGPoint(x: strike.offset - 13, y: y), withAttributes: attributes)
        }
        c.restoreGState()
    }
}
