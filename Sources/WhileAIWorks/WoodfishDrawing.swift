import AppKit

extension PlayView {
    func malletAngle(at time: TimeInterval) -> CGFloat {
        guard !reduceMotion, woodSwingAt > -100 else { return -0.42 }
        let age = max(0, time-woodSwingAt)
        if age < 0.035 {
            let t = age/0.035
            return woodSwingFrom + (-0.065-woodSwingFrom)*CGFloat(t*t)
        }
        // Hold at the shell until the display clock emits the contact event.
        let contactAge = woodHitAt >= woodSwingAt ? max(0,time-woodHitAt) : 0
        let t = min(1, contactAge/0.22)
        return -0.42 + 0.355*CGFloat(pow(1-t, 3)) - 0.04*CGFloat(sin(t * .pi))
    }

    func drawWoodfish(at time: TimeInterval, context c: CGContext) {
        let age = time - woodHitAt
        let bounce = reduceMotion ? 0 : age >= 0 ? exp(-age * 23) * sin(age * 38) : 0
        let center = woodCenter
        c.saveGState(); c.translateBy(x: center.x, y: center.y)
        // A low, woven cushion anchors the wooden instrument to the desktop.
        c.setShadow(offset: CGSize(width: 0, height: -5), blur: 12, color: NSColor.black.withAlphaComponent(0.24).cgColor)
        c.setFillColor(NSColor(srgbRed: 0.30, green: 0.43, blue: 0.36, alpha: 0.96).cgColor)
        c.fillEllipse(in: CGRect(x: -88, y: -61, width: 176, height: 40))
        c.setShadow(offset: .zero, blur: 0, color: nil)
        c.setStrokeColor(NSColor(srgbRed: 0.72, green: 0.81, blue: 0.72, alpha: 0.45).cgColor)
        c.setLineWidth(1.2)
        c.strokeEllipse(in: CGRect(x: -83, y: -55, width: 166, height: 28))
        c.saveGState()
        c.translateBy(x: 0, y: -CGFloat(bounce) * 3)
        c.scaleBy(x: 1 + CGFloat(bounce) * 0.018, y: 1 - CGFloat(bounce) * 0.018)
        let body = CGMutablePath()
        body.move(to: CGPoint(x: -79, y: -25))
        body.addCurve(to: CGPoint(x: -57, y: 49), control1: CGPoint(x: -99, y: 5), control2: CGPoint(x: -82, y: 34))
        body.addCurve(to: CGPoint(x: 54, y: 54), control1: CGPoint(x: -24, y: 73), control2: CGPoint(x: 28, y: 77))
        body.addCurve(to: CGPoint(x: 86, y: 1), control1: CGPoint(x: 78, y: 42), control2: CGPoint(x: 99, y: 18))
        body.addCurve(to: CGPoint(x: 57, y: -39), control1: CGPoint(x: 84, y: -22), control2: CGPoint(x: 80, y: -29))
        body.addCurve(to: CGPoint(x: -79, y: -25), control1: CGPoint(x: 16, y: -59), control2: CGPoint(x: -44, y: -53))
        body.closeSubpath()
        c.saveGState(); c.addPath(body); c.clip()
        let colors = [NSColor(srgbRed: 0.76, green: 0.59, blue: 0.40, alpha: 1).cgColor,
                      NSColor(srgbRed: 0.57, green: 0.39, blue: 0.24, alpha: 1).cgColor,
                      NSColor(srgbRed: 0.31, green: 0.21, blue: 0.14, alpha: 1).cgColor]
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.6, 1]) {
            c.drawRadialGradient(g, startCenter: CGPoint(x: -28, y: 48), startRadius: 0,
                                 endCenter: CGPoint(x: 5, y: 4), endRadius: 107, options: [.drawsAfterEndLocation])
        }
        // Sparse, low-contrast grain follows the warm walnut shell.
        for index in 0..<12 {
            let y = CGFloat(index) * 12 - 63
            let offset = sin(CGFloat(index) * 1.8) * 3
            c.setStrokeColor(NSColor(srgbRed: 0.25, green: 0.095, blue: 0.035, alpha: 0.07 + Double(index % 3) * 0.018).cgColor)
            c.setLineWidth(index.isMultiple(of: 4) ? 0.65 : 0.4)
            c.move(to: CGPoint(x: -103, y: y))
            c.addCurve(to: CGPoint(x: 103, y: y + offset), control1: CGPoint(x: -36, y: y + 24 + offset),
                       control2: CGPoint(x: 27, y: y - 15 + offset)); c.strokePath()
            c.setStrokeColor(NSColor(srgbRed: 0.98, green: 0.76, blue: 0.45, alpha: 0.10).cgColor)
            c.move(to: CGPoint(x: -103, y: y + 1))
            c.addCurve(to: CGPoint(x: 103, y: y + offset + 1), control1: CGPoint(x: -36, y: y + 25 + offset),
                       control2: CGPoint(x: 27, y: y - 14 + offset)); c.strokePath()
        }
        c.restoreGState()
        c.setStrokeColor(NSColor(srgbRed: 0.94, green: 0.81, blue: 0.63, alpha: 0.38).cgColor)
        c.setLineWidth(1.0); c.addPath(body); c.strokePath()
        // The characteristic hollow slit curls across the front of the fish.
        let mouth = CGMutablePath()
        mouth.move(to: CGPoint(x: 82, y: 10))
        mouth.addCurve(to: CGPoint(x: -38, y: -16), control1: CGPoint(x: 41, y: -9), control2: CGPoint(x: -4, y: -29))
        mouth.addCurve(to: CGPoint(x: -47, y: -1), control1: CGPoint(x: -50, y: -13), control2: CGPoint(x: -54, y: -6))
        c.setLineCap(.round)
        c.setStrokeColor(NSColor(srgbRed: 0.84, green: 0.66, blue: 0.45, alpha: 0.5).cgColor)
        c.setLineWidth(8); c.addPath(mouth); c.strokePath()
        c.setStrokeColor(NSColor(srgbRed: 0.18, green: 0.12, blue: 0.08, alpha: 1).cgColor)
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
        c.rotate(by: malletAngle(at: time))
        c.setShadow(offset: CGSize(width: 2, height: -3), blur: 4, color: NSColor.black.withAlphaComponent(0.18).cgColor)
        c.setStrokeColor(NSColor(srgbRed: 0.59, green: 0.43, blue: 0.28, alpha: 1).cgColor)
        c.setLineWidth(8); c.move(to: CGPoint(x: 0, y: 0)); c.addLine(to: CGPoint(x: -73, y: 15)); c.strokePath()
        c.setStrokeColor(NSColor(srgbRed: 0.94, green: 0.71, blue: 0.43, alpha: 0.8).cgColor)
        c.setLineWidth(1.4); c.move(to: CGPoint(x: -1, y: 2)); c.addLine(to: CGPoint(x: -68, y: 17)); c.strokePath()
        c.setFillColor(NSColor(srgbRed: 0.77, green: 0.62, blue: 0.43, alpha: 1).cgColor)
        c.fillEllipse(in: CGRect(x: -93, y: 2, width: 33, height: 30))
        c.setShadow(offset: .zero, blur: 0, color: nil)
        c.setFillColor(NSColor(srgbRed: 1, green: 0.86, blue: 0.61, alpha: 0.55).cgColor)
        c.fillEllipse(in: CGRect(x: -87, y: 19, width: 15, height: 7))
        c.saveGState(); c.translateBy(x: 1, y: -1); c.scaleBy(x: 0.65, y: 0.65)
        InteractionArtwork.paw(at: .zero, pressure: 0.6, angle: .pi / 2, snow: state.mascotCoat == .snow, pads: false, context: c)
        c.restoreGState()
        c.restoreGState()

        let label = "当前 \(state.woodBalance.formatted()) · 敲击 \(state.totalStrikes.formatted()) 次" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: PlayChrome.ink]
        let size = label.size(withAttributes: attrs)
        let pill = CGRect(x: -size.width / 2 - 12, y: -89, width: size.width + 24, height: 25)
        PlayChrome.panel(pill, context: c)
        label.draw(at: CGPoint(x: -size.width / 2, y: -83), withAttributes: attrs)
        for strike in floatingStrikes {
            let progress = min(1, (time - strike.time) / 0.95)
            let y: CGFloat = 88 + (reduceMotion ? 0 : CGFloat(progress)*22)
            let alpha = 1 - progress * progress
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16, weight: .semibold, width: .standard),
                .foregroundColor: (strike.delta > 0 ? PlayChrome.accent : PlayChrome.secondary).withAlphaComponent(alpha)
            ]
            ((strike.delta > 0 ? "+\(strike.delta)" : "−1") as NSString).draw(at: CGPoint(x: strike.offset - 13, y: y), withAttributes: attributes)
        }
        c.restoreGState()
    }
}
