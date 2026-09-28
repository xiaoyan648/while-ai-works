import AppKit

struct BubblePose {
    let pressure: CGFloat
    let collapse: CGFloat
    let settle: CGFloat
    static func smooth(_ t: Double) -> CGFloat {
        let x = min(1, max(0, t)); return CGFloat(x*x*(3-2*x))
    }
    init(pressedAt: TimeInterval?, poppedAt: TimeInterval?, popPressure: CGFloat, at time: TimeInterval, reduceMotion: Bool) {
        if let poppedAt {
            let age = max(0, time-poppedAt)
            pressure = reduceMotion ? 1 : popPressure+(1-popPressure)*Self.smooth(age/0.032)
            collapse = reduceMotion ? 1 : Self.smooth(age/0.095)
            settle = reduceMotion || age > 0.26 ? 0 : CGFloat(sin(max(0, age-0.08)*34)*exp(-max(0, age-0.08)*24))*collapse*0.018
        } else {
            pressure = pressedAt.map { reduceMotion ? 1 : 0.18+0.82*Self.smooth((time-$0)/0.09) } ?? 0
            collapse = 0; settle = 0
        }
    }
}

extension PlayView {
    func drawDesktopBubble(_ bubble: Bubble, at time: TimeInterval, context c: CGContext) {
        let animating = time-bubble.appearedAt < 0.26 ||
            (bubble.pressedAt != nil && bubble.poppedAt == nil) ||
            (bubble.poppedAt.map { time-$0 < 0.28 } ?? false)
        guard !animating, !wasToolOver(bubble) else { drawBubble(bubble, at: time, context: c); return }
        let scale = min(2, window?.backingScaleFactor ?? 2)
        let key = BubbleImageKey(radius: bubble.radius, seed: bubble.seed, flat: bubble.poppedAt != nil, scale: scale)
        let extent: CGFloat = 80
        var image = bubbleImages[key]
        if image == nil {
            let pixels = Int(extent*scale)
            if let raster = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                      bytesPerRow: pixels*4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                raster.scaleBy(x: scale, y: scale)
                var local = bubble; local.point = CGPoint(x: extent/2, y: extent/2)
                drawBubble(local, at: time, context: raster, highlight: false)
                image = raster.makeImage()
                if let image {
                    // Bound retained images even on a large full-screen bubble sheet.
                    if bubbleImageOrder.count >= 256 { bubbleImages.removeValue(forKey: bubbleImageOrder.removeFirst()) }
                    bubbleImages[key] = image; bubbleImageOrder.append(key)
                }
            }
        }
        if let image {
            c.draw(image, in: CGRect(x: bubble.point.x-extent/2, y: bubble.point.y-extent/2, width: extent, height: extent))
        } else { drawBubble(bubble, at: time, context: c) }
    }

    func drawBubble(_ bubble: Bubble, at time: TimeInterval, context c: CGContext, highlight: Bool? = nil) {
        let radius = bubble.radius
        let pose = BubblePose(pressedAt: bubble.pressedAt, poppedAt: bubble.poppedAt,
                              popPressure: bubble.popPressure, at: time, reduceMotion: reduceMotion)
        let pressure = pose.pressure, collapse = pose.collapse, tension = 1-collapse
        let appear = reduceMotion ? 1 : BubblePose.smooth((time-bubble.appearedAt)/0.22)
        let hovered = highlight ?? wasToolOver(bubble)
        c.saveGState(); c.translateBy(x: bubble.point.x, y: bubble.point.y); c.setAlpha(appear)
        // Quiet welded film. Paired light/dark edges stay legible over either wallpaper.
        let film = CGRect(x: -32, y: -32, width: 64, height: 64)
        let filmPath = CGPath(roundedRect: film, cornerWidth: 9, cornerHeight: 9, transform: nil)
        c.setFillColor(NSColor.white.withAlphaComponent(0.025).cgColor); c.addPath(filmPath); c.fillPath()
        c.setLineWidth(0.6); c.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
        c.addPath(filmPath); c.strokePath()
        c.setStrokeColor(NSColor.black.withAlphaComponent(0.05).cgColor)
        c.move(to: CGPoint(x: -25, y: -31)); c.addLine(to: CGPoint(x: 23, y: -31)); c.strokePath()

        let sx = 1+pressure*0.025-collapse*0.065+pose.settle
        let sy = 1-pressure*0.12-collapse*0.10-pose.settle
        let rim = membrane(radius: radius, seed: bubble.seed, collapse: collapse)
        c.scaleBy(x: sx, y: sy)
        c.setShadow(offset: CGSize(width: 0, height: -1.8*tension), blur: 2.8*tension+0.5,
                    color: NSColor.black.withAlphaComponent(0.16*tension).cgColor)
        c.setFillColor(NSColor.white.withAlphaComponent(0.025+0.02*tension).cgColor)
        c.addPath(rim); c.fillPath(); c.setShadow(offset: .zero, blur: 0, color: nil)
        c.saveGState(); c.addPath(rim); c.clip()
        let colors = [NSColor.white.withAlphaComponent(0.25*tension+0.05).cgColor,
                      NSColor.white.withAlphaComponent(0.025).cgColor,
                      NSColor.black.withAlphaComponent(0.12*tension+0.025).cgColor]
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0,0.64,1]) {
            c.drawRadialGradient(g, startCenter: CGPoint(x: -radius*0.26, y: radius*0.32), startRadius: 0,
                                 endCenter: .zero, endRadius: radius, options: [.drawsAfterEndLocation])
        }
        let dent = CGPoint(x: bubble.contact.x/sx, y: bubble.contact.y/sy)
        if pressure > 0 {
            let colors = [NSColor.black.withAlphaComponent(pressure*(0.13*tension+0.025)).cgColor,
                          NSColor.white.withAlphaComponent(pressure*0.08*tension).cgColor, NSColor.clear.cgColor]
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0,0.62,1]) {
                c.drawRadialGradient(g, startCenter: dent, startRadius: 0, endCenter: dent, endRadius: radius*0.67, options: [])
            }
        }
        c.setLineCap(.round)
        c.setLineWidth(1.5); c.setStrokeColor(NSColor.white.withAlphaComponent((0.62+(hovered ? 0.12 : 0))*tension).cgColor)
        c.move(to: CGPoint(x: -radius*0.77, y: radius*0.25))
        c.addCurve(to: CGPoint(x: radius*0.13, y: radius*0.81-pressure*3),
                   control1: CGPoint(x: -radius*0.69, y: radius*0.73), control2: CGPoint(x: -radius*0.24, y: radius*0.91-pressure*5))
        c.strokePath()
        // The same membrane develops two soft folds as tension disappears.
        for index in 0..<2 {
            let y = (CGFloat(index)-0.5)*radius*0.5
            let bend = sin(bubble.seed+CGFloat(index))*radius*0.12
            c.setLineWidth(0.65); c.setStrokeColor(NSColor.black.withAlphaComponent(collapse*0.085).cgColor)
            c.move(to: CGPoint(x: -radius*0.78, y: y+4))
            c.addCurve(to: CGPoint(x: radius*(index == 0 ? 0.64 : 0.28), y: y-7), control1: CGPoint(x: -radius*0.18, y: y+bend-8*collapse), control2: CGPoint(x: radius*0.2, y: y+bend+4))
            c.strokePath()
            c.setLineWidth(0.8); c.setStrokeColor(NSColor.white.withAlphaComponent(collapse*0.20).cgColor)
            c.move(to: CGPoint(x: -radius*0.77, y: y+5))
            c.addCurve(to: CGPoint(x: radius*(index == 0 ? 0.63 : 0.27), y: y-6), control1: CGPoint(x: -radius*0.18, y: y+bend-8*collapse+1), control2: CGPoint(x: radius*0.2, y: y+bend+5))
            c.strokePath()
        }
        c.restoreGState()
        c.setLineWidth(0.7); c.setStrokeColor(NSColor.white.withAlphaComponent(0.28+0.25*tension).cgColor)
        c.addPath(rim); c.strokePath()
        c.setStrokeColor(NSColor.black.withAlphaComponent(0.055+0.05*tension).cgColor)
        c.addArc(center: .zero, radius: radius*0.98, startAngle: -.pi*0.92, endAngle: -.pi*0.1, clockwise: false); c.strokePath()
        c.restoreGState()
    }

    private func wasToolOver(_ bubble: Bubble) -> Bool {
        guard bubble.poppedAt == nil, let point = hoverPoint else { return false }
        return hypot(point.x-bubble.point.x, point.y-bubble.point.y) < bubble.radius
    }
    private func membrane(radius: CGFloat, seed: CGFloat, collapse: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for index in 0...64 {
            let angle = CGFloat(index)/64 * .pi*2
            let r = radius * (1+(0.006+collapse*0.025)*sin(angle*3+seed)+collapse*0.013*cos(angle*5+seed))
            let point = CGPoint(x: cos(angle)*r, y: sin(angle)*r)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath(); return path
    }
}
