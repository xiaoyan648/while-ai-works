import AppKit
import WhileCore

/// Decoded once, shared by the guide and catch reveal; originals stay untouched.
enum FishingSprites {
    struct Sprite {
        let image: NSImage
        let silhouette: NSImage
    }
    static let catalog: [String: Sprite] = {
        var result: [String: Sprite] = [:]
        for species in CatchSpecies.catalog {
            #if SWIFT_PACKAGE
            let root = Bundle.module.resourceURL
            #else
            let root = Bundle.main.resourceURL
            #endif
            guard let url = root?.appendingPathComponent("FishAssets/\(species.id).png"),
                  let source = NSImage(contentsOf: url),
                  let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let bitmap = CGContext(data: nil, width: cg.width, height: cg.height,
                                         bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                  let data = bitmap.data else { continue }
            bitmap.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            let bytes = data.assumingMemoryBound(to: UInt8.self)
            var minX = cg.width, minY = cg.height, maxX = -1, maxY = -1
            for y in 0..<cg.height {
                for x in 0..<cg.width where bytes[y * bitmap.bytesPerRow + x * 4 + 3] > 0 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            guard maxX >= minX, maxY >= minY else { continue }
            let crop = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            guard let image = bitmap.makeImage()?.cropping(to: crop) else { continue }
            // Source-in retains only the real fish alpha, with no visible markings.
            bitmap.setBlendMode(.sourceIn)
            bitmap.setFillColor(CGColor(gray: 0.48, alpha: 0.3))
            bitmap.fill(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            guard let mask = bitmap.makeImage()?.cropping(to: crop) else { continue }
            result[species.id] = Sprite(image: NSImage(cgImage: image, size: crop.size),
                                       silhouette: NSImage(cgImage: mask, size: crop.size))
        }
        return result
    }()

    static func draw(_ species: CatchSpecies, in rect: CGRect, discovered: Bool) -> Bool {
        guard let sprite = catalog[species.id], rect.width > 0, rect.height > 0 else { return false }
        let image = discovered ? sprite.image : sprite.silhouette
        let scale = min(rect.width / image.size.width, rect.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let target = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                            width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return true
    }
}

/// Shared illustrations used both on the desktop and in the field guide.
enum FishingArtwork {
    static func specimen(_ species: CatchSpecies, in rect: CGRect, discovered: Bool = true) {
        if species.isSecret && !discovered {
            let text="?" as NSString
            let attributes:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:30,weight:.light),.foregroundColor:NSColor.playInk.withAlphaComponent(0.35)]
            let size=text.size(withAttributes:attributes)
            text.draw(at:CGPoint(x:rect.midX-size.width/2,y:rect.midY-size.height/2),withAttributes:attributes);return
        }
        if FishingSprites.draw(species, in: rect, discovered: discovered) { return }
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        c.saveGState()
        defer { c.restoreGState() }
        c.translateBy(x: rect.midX, y: rect.midY)
        c.scaleBy(x: rect.width / 100, y: rect.height / 70)
        let color = discovered ? NSColor(calibratedHue: species.hue, saturation: 0.48, brightness: 0.8, alpha: 1) : NSColor(calibratedWhite: 0.48, alpha: 0.3)
        if !species.isFish {
            if let image = NSImage(systemSymbolName: species.symbol, accessibilityDescription: species.name) {
                let config = NSImage.SymbolConfiguration(pointSize: 42, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
                (image.withSymbolConfiguration(config) ?? image).draw(in: CGRect(x: -30, y: -27, width: 60, height: 54))
            }
            return
        }
        let long = ["eel", "oarfish"].contains(species.id)
        let round = ["puffer", "moonfish"].contains(species.id)
        let h: CGFloat = long ? 10 : round ? 26 : 19
        let body = NSBezierPath(ovalIn: CGRect(x: -31, y: -h, width: 69, height: h * 2))
        let tail = NSBezierPath()
        tail.move(to: CGPoint(x: -23, y: 0)); tail.line(to: CGPoint(x: -48, y: h)); tail.line(to: CGPoint(x: -42, y: 0))
        tail.line(to: CGPoint(x: -48, y: -h)); tail.close()
        color.withAlphaComponent(discovered ? 0.85 : 0.3).setFill(); tail.fill()
        color.setFill(); body.fill()
        c.saveGState(); body.addClip()
        if discovered {
            let light = color.blended(withFraction: 0.65, of: .white)!
            NSGradient(starting: light, ending: color)?.draw(in: body, angle: -90)
            if species.id == "koi" {
                NSColor(srgbRed: 0.95, green: 0.40, blue: 0.24, alpha: 0.95).setFill()
                NSBezierPath(ovalIn: CGRect(x: -12, y: -10, width: 20, height: 28)).fill()
                NSBezierPath(ovalIn: CGRect(x: 22, y: 3, width: 23, height: 20)).fill()
            } else {
                color.withAlphaComponent(0.5).setStroke()
                for i in 0..<5 {
                    let x = CGFloat(i) * 9 - 24
                    let line = NSBezierPath(); line.move(to: CGPoint(x: x, y: -h)); line.curve(to: CGPoint(x: x + 3, y: h), controlPoint1: CGPoint(x: x + 10, y: -5), controlPoint2: CGPoint(x: x + 10, y: 5)); line.lineWidth = species.id == "perch" ? 3.5 : 1; line.stroke()
                }
            }
        }
        c.restoreGState()
        let fin = NSBezierPath(); fin.move(to: CGPoint(x: -15, y: h - 3)); fin.line(to: CGPoint(x: -5, y: h + 13)); fin.line(to: CGPoint(x: 17, y: h - 3)); fin.close()
        color.setFill(); fin.fill()
        let side = NSBezierPath(); side.move(to: CGPoint(x: 5, y: 0)); side.line(to: CGPoint(x: -6, y: -h - 7)); side.line(to: CGPoint(x: 15, y: -h + 1)); side.close(); color.withAlphaComponent(0.75).setFill(); side.fill()
        if discovered {
            NSColor.white.withAlphaComponent(0.9).setFill(); NSBezierPath(ovalIn: CGRect(x: 22, y: 3, width: 8, height: 8)).fill()
            NSColor.playInk.setFill(); NSBezierPath(ovalIn: CGRect(x: 26, y: 5, width: 4, height: 4)).fill()
            if species.id == "catfish" {
                NSColor.playInk.withAlphaComponent(0.65).setStroke()
                for direction: CGFloat in [-1, 1] {
                    let whisker = NSBezierPath(); whisker.move(to: CGPoint(x: 32, y: -3)); whisker.curve(to: CGPoint(x: 48, y: direction * 16), controlPoint1: CGPoint(x: 40, y: -2), controlPoint2: CGPoint(x: 45, y: direction * 6)); whisker.lineWidth = 1; whisker.stroke()
                }
            }
            if species.id == "puffer" {
                color.setStroke()
                for i in 0..<10 {
                    let a = CGFloat(i) * .pi * 2 / 10
                    let spine = NSBezierPath(); spine.move(to: CGPoint(x: 3 + cos(a) * 32, y: sin(a) * 23)); spine.line(to: CGPoint(x: 3 + cos(a) * 39, y: sin(a) * 30)); spine.stroke()
                }
            }
        }
    }

    static func text(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat = 11,
                     color: NSColor = .white, weight: NSFont.Weight = .regular) {
        (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color
        ])
    }
}

/// A shallow river occupies the usable desktop edge; the area above it stays transparent.
extension PlayView {
    var fishingRect: CGRect {
        let width = state.area == .edges ? min(620, bounds.width * 0.90) : min(820,bounds.width)
        return CGRect(x: bounds.maxX - width, y: 0, width: max(0, width), height: min(310, bounds.height))
    }
    var fishingStationX: CGFloat { fishingRect.width * 0.70 }
    func fishingRodBend(at time: TimeInterval) -> CGFloat {
        if state.castStartedAt != nil { return CGFloat(state.castPower(at: time)) }
        if state.fishing.engaged && state.fishing.catchResult?.species.isSecret == true {return reduceMotion ? 0.4 : 0.4+0.12*CGFloat(sin(state.fishing.elapsed*2.8))}
        let age = time - state.castReleasedAt
        guard !reduceMotion, age >= 0, age < 0.8, state.fishing.phase == .waiting else { return 0 }
        return CGFloat(state.releasedCastPower * exp(-age * 6) * cos(age * 18))
    }
    func fishingRodTip(at time: TimeInterval) -> CGPoint {
        let bend = fishingRodBend(at: time)
        return CGPoint(x: fishingRect.width * 0.77 + bend * 20, y: 115 - bend * 17)
    }
    func fishingBobber(at time: TimeInterval) -> CGPoint {
        let landing = CGPoint(x: state.castLanding.x * fishingRect.width, y: state.castLanding.y * 195)
        let flight = reduceMotion ? 1 : min(1, max(0, (time - state.castReleasedAt) / 0.55))
        if flight < 1 {
            let origin = CGPoint(x: state.castOrigin.x * fishingRect.width, y: state.castOrigin.y * 195)
            return CGPoint(x: origin.x + (landing.x - origin.x) * flight,
                           y: origin.y + (landing.y - origin.y) * flight + sin(flight * .pi) * 65)
        }
        let motion = reduceMotion ? 0 : time
        let dip = state.fishing.phase == .bite ? (reduceMotion ? 7 : 7 + 2 * sin(state.fishing.elapsed * 14)) : 0
        return CGPoint(x: landing.x, y: landing.y + sin(motion * 2) - dip)
    }
    /// A dorsal silhouette: broad shoulders, paired fins and a flexible narrow tail.
    /// It deliberately does not reuse the side-view collectible illustration.
    private func drawRiverFish(index: Int, at time: TimeInterval, context c: CGContext) {
        let phase = time * (0.12 + Double(index) * 0.012) + Double(index) * 2.17
        let px = fishingRect.width * (0.5 + CGFloat(sin(phase)) * 0.38)
        let py = 119 + CGFloat(sin(phase * 0.7 + Double(index))) * 37
        let dx = Double(fishingRect.width) * 0.38 * cos(phase)
        let dy = 37 * 0.7 * cos(phase * 0.7 + Double(index))
        let wag = CGFloat(sin(time * 3.2 + Double(index))) * 3
        let length: CGFloat = index % 3 == 0 ? 25 : 19
        c.saveGState(); defer { c.restoreGState() }
        c.translateBy(x: px, y: py); c.rotate(by: CGFloat(atan2(dy, dx))); c.scaleBy(x:0.62,y:0.62)
        c.setFillColor(NSColor(srgbRed: 0.025, green: 0.15, blue: 0.15, alpha: 0.22).cgColor)
        let body = CGMutablePath()
        body.move(to: CGPoint(x: length, y: 0))
        body.addCurve(to: CGPoint(x: -length * 0.7, y: wag * 0.6),
                      control1: CGPoint(x: length * 0.7, y: 7), control2: CGPoint(x: -length * 0.35, y: 7))
        body.addLine(to: CGPoint(x: -length - 4, y: wag + 5))
        body.addQuadCurve(to: CGPoint(x: -length - 4, y: wag - 5), control: CGPoint(x: -length + 1, y: wag))
        body.addLine(to: CGPoint(x: -length * 0.7, y: wag * 0.6))
        body.addCurve(to: CGPoint(x: length, y: 0),
                      control1: CGPoint(x: -length * 0.35, y: -7), control2: CGPoint(x: length * 0.7, y: -7))
        body.closeSubpath(); c.addPath(body); c.fillPath()
        for side: CGFloat in [-1, 1] {
            c.beginPath(); c.move(to: CGPoint(x: 7, y: side * 4))
            c.addLine(to: CGPoint(x: -4, y: side * 10)); c.addLine(to: CGPoint(x: 0, y: side * 3)); c.closePath(); c.fillPath()
        }
    }
    func updateCastAim(_ point: CGPoint) {
        let target=RiverScenery.clamp(CGPoint(x:point.x-fishingRect.minX,y:point.y),width:fishingRect.width)
        state.castAim=CGPoint(x:target.x/fishingRect.width,y:target.y/195)
    }
    func castTarget(at time: TimeInterval) -> CGPoint {
        let power=0.25+state.castPower(at:time)*0.75
        let target=CGPoint(x:fishingRect.width*0.82+(state.castAim.x*fishingRect.width-fishingRect.width*0.82)*power,
                           y:105+(state.castAim.y*195-105)*power)
        return RiverScenery.clamp(target,width:fishingRect.width)
    }
    func castWater(at point: CGPoint) -> FishingWater {
        if point.x > fishingRect.width * 0.74 && point.y > RiverScenery.far(point.x,fishingRect.width)-92 && point.y < RiverScenery.far(point.x,fishingRect.width)-30 { return .reeds }
        return point.y-RiverScenery.near(point.x,fishingRect.width)>40 && RiverScenery.far(point.x,fishingRect.width)-point.y>22 ? .deep : .shallow
    }
    var fishingTrack: CGRect {
        return CGRect(x:fishingRect.maxX-72,y:78,width:30,height:144)
    }
    var fishingRewardRect: CGRect {
        let giant=state.fishingReward?.catchResult.species.isSecret == true
        let width=giant ? min(300,fishingRect.width*0.50) : min(260,fishingRect.width*0.52)
        return CGRect(x:fishingRect.width-width-24,y:giant ? 28:38,width:width,height:giant ? min(150,max(110,fishingRect.width*0.24)):106)
    }
    func fishingContains(_ point: CGPoint) -> Bool {
        // Every hit target stays inside the visible triangular corner.
        let local=CGPoint(x:point.x-fishingRect.minX,y:point.y)
        guard fishingRect.contains(point),RiverScenery.outline(width:fishingRect.width).contains(local) else{return false}
        if RiverScenery.contains(CGPoint(x:point.x-fishingRect.minX,y:point.y),width:fishingRect.width) { return true }
        if state.fishing.phase == .fighting { return fishingTrack.insetBy(dx: -18, dy: -16).contains(point) }
        if state.fishing.phase == .landed {
            return fishingRewardRect.offsetBy(dx:fishingRect.minX,dy:0).contains(point)
        }
        return false
    }

    func drawFishing(at time: TimeInterval, context c: CGContext) {
        let rect = fishingRect
        guard rect.width > 60, rect.height > 100 else { return }
        let game = state.fishing
        let showingReward = game.phase == .landed && (state.fishingReward?.isVisible(at: time) ?? false)
        let age = max(0, time - fishingVisualStartedAt)
        let motion = reduceMotion ? 0 : time
        let x = fishingStationX
        c.saveGState()
        c.clip(to: rect)
        c.translateBy(x: rect.minX, y: 0)
        RiverScenery.outline(width:rect.width).addClip()
        defer { c.restoreGState() }
        let accent = NSColor(srgbRed: 0.73, green: 0.91, blue: 0.75, alpha: 1)
        let ink = NSColor(srgbRed: 0.96, green: 0.97, blue: 0.92, alpha: 1)
        drawRiver(width: rect.width, time: motion, context: c)

        // Small fish-shaped silhouettes drift with the current. Work cadence changes their count.
        c.saveGState();RiverScenery.water(width:rect.width).addClip()
        if state.isWorking {
            for i in 0..<(1 + Int(state.fishingIntensity * 2)) {
                drawRiverFish(index: i, at: motion, context: c)
            }
        }

        if game.engaged && game.catchResult?.species.isSecret == true {
            let wake=fishingBobber(at:time)
            c.saveGState();c.translateBy(x:wake.x,y:wake.y-14);c.rotate(by:reduceMotion ? 0.12:0.12+0.05*sin(motion*0.4))
            NSColor(srgbRed:0.03,green:0.12,blue:0.13,alpha:0.19).setFill()
            NSBezierPath(ovalIn:CGRect(x:-73,y:-11,width:136,height:23)).fill()
            let tail=NSBezierPath();tail.move(to:CGPoint(x:-62,y:0));tail.line(to:CGPoint(x:-89,y:14));tail.line(to:CGPoint(x:-83,y:0));tail.line(to:CGPoint(x:-89,y:-14));tail.close();tail.fill()
            c.restoreGState()
        }
        c.restoreGState()
        let live = game.phase == .waiting || game.engaged
        let tip = fishingRodTip(at: time)
        let bend = fishingRodBend(at: time)
        let bob = fishingBobber(at: time)
        let flight = reduceMotion ? 1 : min(1, max(0, (time - state.castReleasedAt) / 0.55))
        if state.castStartedAt != nil {
            let target = castTarget(at: time)
            NSColor.white.withAlphaComponent(0.7).setStroke()
            let guide = NSBezierPath(); guide.move(to: tip); guide.line(to: target)
            guide.setLineDash([3, 5], count: 2, phase: 0); guide.lineWidth = 0.8; guide.stroke()
            NSBezierPath(ovalIn: CGRect(x: target.x - 9, y: target.y - 9, width: 18, height: 18)).stroke()
            fishingLabel(castWater(at: target).title, centerX: target.x, y: target.y + 14, size: 10, color: ink, context: c)
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: CGRect(x: x - 62, y: 52, width: 124, height: 9), xRadius: 4.5, yRadius: 4.5).fill()
            accent.setFill()
            NSBezierPath(roundedRect: CGRect(x: x - 60, y: 54, width: 120 * state.castPower(at: time), height: 5), xRadius: 2.5, yRadius: 2.5).fill()
            fishingLabel("力度 \(Int(state.castPower(at: time) * 100))%", centerX: x, y: 66, size: 10, color: ink, context: c)
        }
        if game.phase != .landed {
            FishingRodArtwork.draw(game.rod, start: CGPoint(x: rect.width - 14, y: 18), tip: tip, bend: bend)
            if live {
                let line = NSBezierPath()
                line.move(to: tip)
                let slack = 4 + (1 - flight) * 28
                line.curve(to: bob, controlPoint1: CGPoint(x: tip.x + (bob.x - tip.x) * 0.30, y: tip.y + (bob.y - tip.y) * 0.30 - slack),
                           controlPoint2: CGPoint(x: tip.x + (bob.x - tip.x) * 0.75, y: tip.y + (bob.y - tip.y) * 0.75 - slack))
                NSColor.white.withAlphaComponent(0.7).setStroke(); line.lineWidth = 0.8; line.stroke()
                for i in 0..<(flight < 1 ? 0 : 3) {
                    let rippleAge = reduceMotion ? 0 : max(0, time - state.castReleasedAt - 0.55)
                    let radius = CGFloat((rippleAge * 12 + Double(i) * 16).truncatingRemainder(dividingBy: 48)) + 5
                    NSColor.white.withAlphaComponent((1 - radius / 54) * 0.26).setStroke()
                    NSBezierPath(ovalIn: CGRect(x: bob.x - radius, y: bob.y - radius * 0.65, width: radius * 2, height: radius * 1.3)).stroke()
                }
                c.saveGState(); c.translateBy(x: bob.x, y: bob.y)
                if game.phase == .bite { c.scaleBy(x: 1.05, y: 0.48) }
                c.rotate(by: CGFloat(sin(motion * 1.8)) * 0.08)
                NSColor(srgbRed: 0.89, green: 0.36, blue: 0.22, alpha: 1).setFill()
                NSBezierPath(roundedRect: CGRect(x: -3.5, y: -4, width: 7, height: 16), xRadius: 3.5, yRadius: 3.5).fill()
                NSColor(srgbRed: 0.98, green: 0.95, blue: 0.82, alpha: 1).setFill()
                NSBezierPath(roundedRect: CGRect(x: -3, y: 3, width: 6, height: 8), xRadius: 3, yRadius: 3).fill()
                c.restoreGState()
            }
        }
        if game.phase == .bite {
            let pulse = reduceMotion ? 0.5 : (sin(game.elapsed * 7) + 1) / 2
            accent.withAlphaComponent(0.40 + pulse * 0.35).setStroke()
            let radius = 13 + pulse * 4
            let ring = NSBezierPath(ovalIn: CGRect(x: bob.x - radius, y: bob.y - radius * 0.6, width: radius * 2, height: radius * 1.2))
            ring.lineWidth = 1.6; ring.stroke()
            fishingLabel("!", centerX: bob.x, y: bob.y + 17, size: 21, color: accent, context: c)
            let notice = CGRect(x:rect.width-198,y:141,width:164,height:38)
            NSColor(srgbRed:0.10,green:0.22,blue:0.20,alpha:0.96).setFill()
            NSBezierPath(roundedRect:notice,xRadius:8,yRadius:8).fill()
            fishingLabel("咬钩了 · 点击提竿", centerX: notice.midX, y: notice.minY + 17, size: 12, color: ink, context: c)
            fishingLabel("还有 \(max(0, Int(ceil(8 - game.elapsed)))) 秒", centerX: notice.midX, y: notice.minY + 4, size: 10, color: accent, context: c)
        }
        if game.phase == .fighting {
            let track = fishingTrack.offsetBy(dx: -rect.minX, dy: 0)
            c.saveGState()
            c.setShadow(offset: CGSize(width: 0, height: -2), blur: 8, color: NSColor.black.withAlphaComponent(0.2).cgColor)
            NSColor(srgbRed: 0.055, green: 0.17, blue: 0.18, alpha: 0.94).setFill()
            NSBezierPath(roundedRect: track.insetBy(dx: -5, dy: -6), xRadius: 13, yRadius: 13).fill()
            c.restoreGState()
            let bar = CGRect(x: track.minX + 2, y: track.minY + CGFloat(game.bar - game.barHeight / 2) * track.height,
                             width: track.width - 4, height: CGFloat(game.barHeight) * track.height)
            (game.inRange ? accent : accent.withAlphaComponent(0.45)).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 5, yRadius: 5).fill()
            let fishY = track.minY + CGFloat(game.fish) * track.height
            if let icon = NSImage(systemSymbolName: "fish.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [game.inRange ? .playInk : .white])) {
                icon.draw(in: CGRect(x: track.minX + 6, y: fishY - 7, width: 22, height: 14))
            }
            NSColor(srgbRed:0.08,green:0.18,blue:0.18,alpha:0.94).setFill()
            NSBezierPath(roundedRect:CGRect(x:track.maxX+8,y:track.minY-3,width:10,height:track.height+6),xRadius:5,yRadius:5).fill()
            NSColor.white.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: CGRect(x: track.maxX + 11, y: track.minY, width: 4, height: track.height), xRadius: 2, yRadius: 2).fill()
            accent.setFill()
            NSBezierPath(roundedRect: CGRect(x: track.maxX + 11, y: track.minY, width: 4, height: track.height * game.progress), xRadius: 2, yRadius: 2).fill()
            NSColor(srgbRed:0.08,green:0.18,blue:0.18,alpha:0.94).setFill()
            NSBezierPath(roundedRect:CGRect(x:track.midX-24,y:track.maxY+3,width:48,height:18),xRadius:5,yRadius:5).fill()
            NSBezierPath(roundedRect:CGRect(x:track.midX-26,y:track.minY-25,width:52,height:18),xRadius:5,yRadius:5).fill()
            fishingLabel("\(Int(game.progress * 100))%", centerX: track.midX, y: track.maxY + 6, size: 11, color: ink, context: c)
            fishingLabel(game.inRange ? "稳住" : "追上鱼", centerX: track.midX, y: track.minY - 23, size: 10, color: ink, context: c)
        }
        if game.phase == .landed, !showingReward, let result = game.catchResult {
            let t = reduceMotion ? 1 : min(1, age / 0.65)
            let lift = CGFloat(1 - pow(1 - t, 3))
            c.saveGState()
            c.translateBy(x: x, y: 101 + lift * 67)
            c.rotate(by: reduceMotion ? 0 : CGFloat(sin(t * .pi)) * -0.13)
            c.setAlpha(min(1, t * 3))
            c.beginTransparencyLayer(auxiliaryInfo: nil)
            FishingArtwork.specimen(result.species, in: CGRect(x: -100, y: -48, width: 200, height: 115))
            c.endTransparencyLayer()
            c.restoreGState()
            if !reduceMotion && age < 0.7 {
                for i in 0..<7 {
                    let direction = CGFloat(i) / 6 * .pi
                    let distance = CGFloat(age) * 90
                    NSColor.white.withAlphaComponent(max(0, 0.6 - age)).setFill()
                    NSBezierPath(ovalIn: CGRect(x: x + cos(direction) * distance - 2, y: 88 + sin(direction) * distance * 0.65, width: 3, height: 5)).fill()
                }
            }
            fishingLabel(result.species.name, centerX: x, y: 112, size: 17, color: ink, context: c)
            fishingLabel(String(format: "%.1f cm", result.sizeCM) + (result.medal.map { " · " + $0.title } ?? "") + (state.fishingNewRecord ? " · 新纪录" : ""), centerX: x, y: 93, size: 12, color: accent, context: c)
        }
        let title: String
        switch game.phase {
        case .ready: title = state.castStartedAt == nil ? "按住蓄力 · 松开抛竿" : "移动瞄准 · 松开抛竿 · Esc 取消"
        case .waiting: title = state.isWorking ? (game.water?.title ?? "河湾") + " · 等浮漂动" : "等 AI 开工，鱼就来了"
        case .bite: title = "有鱼上钩 · 点击提竿"
        case .fighting: title = state.interactionHeld ? "按下上浮 · 松开下沉" : "已暂停 · 开启操作继续"
        case .landed:
            title = state.fishingReward.map { !$0.canDismiss(at: time) } == true
                ? "已收入图鉴 · 看看这次的收获" : "已收入图鉴 · 点击收起"
        case .escaped: title = "鱼溜走了 · 按住蓄力再试一次"
        }
        if !showingReward {
        let footer = CGRect(x:rect.width*0.28,y:8,width:rect.width*0.42,height:38)
        NSColor(srgbRed:0.10,green:0.19,blue:0.17,alpha:0.94).setFill()
        NSBezierPath(roundedRect:footer,xRadius:9,yRadius:9).fill()
        fishingLabel(title, centerX: footer.midX, y: 28, size: min(10,footer.width/max(1,CGFloat(title.count))), color: ink, context: c)
        fishingLabel("\(game.rod.title) · 总鱼获 \(state.fishingBook.total)", centerX: footer.midX, y: 13, size: 9, color: ink.withAlphaComponent(0.86), context: c)
        }
        if showingReward, let reward = state.fishingReward {
            drawFishingReward(reward, at: time, centerX: x, context: c)
        }
    }

    private func drawFishingReward(_ reward: AppState.FishingReward, at time: TimeInterval,
                                   centerX: CGFloat, context c: CGContext) {
        let age = time - reward.caughtAt
        let entry = min(1, age / 0.32)
        let fade = min(1, (AppState.FishingReward.duration - age) / 0.45)
        let scale = reduceMotion ? 1 : 1 - 0.12 * pow(1 - entry, 3) + 0.035 * sin(entry * .pi)
        let card = fishingRewardRect
        let gold = NSColor(srgbRed: 1, green: 0.82, blue: 0.43, alpha: 1)
        c.saveGState()
        defer { c.restoreGState() }
        c.setAlpha(CGFloat(fade * (reduceMotion ? 1 : min(1, age / 0.12))))
        c.translateBy(x: card.midX, y: card.midY + (reduceMotion ? 0 : 10 * (1 - entry)))
        c.scaleBy(x: scale, y: scale)
        c.translateBy(x: -card.midX, y: -card.midY)
        let shape = NSBezierPath(roundedRect: card, xRadius: 17, yRadius: 17)
        NSColor(srgbRed: 0.075, green: 0.22, blue: 0.23, alpha: 1).setFill(); shape.fill()
        gold.withAlphaComponent(0.65).setStroke(); shape.lineWidth = 1; shape.stroke()
        FishingArtwork.text("✦  " + reward.title, x: card.minX + 15, y: card.maxY - 27,
                            size: 13, color: gold, weight: .semibold)
        if reward.catchResult.species.isSecret {
            FishingArtwork.text(reward.catchResult.species.name,x:card.minX+15,y:card.minY+12,size:14,color:.white,weight:.semibold)
            FishingArtwork.text(String(format:"%.2f 米",reward.catchResult.sizeCM/100) + (reward.catchResult.medal.map { " · " + $0.title } ?? ""),x:card.maxX-128,y:card.minY+12,size:11,color:gold,weight:.medium)
            FishingArtwork.specimen(reward.catchResult.species,in:CGRect(x:card.minX+12,y:card.minY+35,width:card.width-24,height:card.height-66))
        } else {
        FishingArtwork.specimen(reward.catchResult.species,
                                in: CGRect(x: card.minX + 12, y: card.minY + 25, width: 87, height: 58))
        FishingArtwork.text(reward.catchResult.species.name, x: card.minX + 109, y: card.minY + 62,
                            size: 17, color: .white, weight: .semibold)
        FishingArtwork.text(String(format: "%.1f cm", reward.catchResult.sizeCM) + (reward.catchResult.medal.map { " · " + $0.title } ?? ""),
                            x: card.minX + 109, y: card.minY + 39, size: 13, color: gold, weight: .medium)
        let footer = reward.perfect ? "完美收竿 · 全程稳稳接住" : reward.firstDiscovery ? "第一次相遇 · 已收入图鉴" : reward.newRecord ? "突破个人最佳 · 已收入图鉴" : "收获 +1 · 已收入图鉴"
        FishingArtwork.text(footer, x: card.minX + 15, y: card.minY + 10, size: 10,
                            color: NSColor.white.withAlphaComponent(0.65))
        }
        if let notice = reward.unlockNotices.first {
            let extra = reward.unlockNotices.count > 1 ? " · 另 \(reward.unlockNotices.count - 1) 项" : ""
            let banner = CGRect(x: card.minX, y: card.maxY + 8, width: card.width, height: 27)
            NSColor(srgbRed: 0.075, green: 0.22, blue: 0.23, alpha: 0.98).setFill()
            NSBezierPath(roundedRect: banner, xRadius: 8, yRadius: 8).fill()
            FishingArtwork.text(notice + extra, x: banner.minX + 10, y: banner.minY + 8, size: 10, color: gold)
        }
        if !reduceMotion && age < 0.9 {
            gold.withAlphaComponent((1 - age / 0.9) * 0.9).setFill()
            for index in 0..<7 {
                let angle = CGFloat(index) * .pi / 3.5
                let radius = 6 + CGFloat(age) * 16
                let x = card.midX + cos(angle) * (card.width / 2 + radius)
                let y = card.midY + sin(angle) * (card.height / 2 + radius)
                NSBezierPath(ovalIn: CGRect(x: x - 2, y: y - 2, width: 4, height: 4)).fill()
            }
        }
    }

    private func fishingLabel(_ text: String, centerX: CGFloat, y: CGFloat, size: CGFloat, color: NSColor, context c: CGContext) {
        let font = NSFont.systemFont(ofSize: size, weight: .medium)
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -1), blur: 4, color: NSColor(srgbRed: 0.02, green: 0.10, blue: 0.12, alpha: 0.95).cgColor)
        FishingArtwork.text(text, x: centerX - width / 2, y: y, size: size, color: color, weight: .medium)
        c.restoreGState()
    }

    private func livePhase(_ phase: FishingGame.Phase) -> Bool {
        phase == .waiting || phase == .bite || phase == .fighting
    }

    private func drawRiver(width: CGFloat, time: TimeInterval, context c: CGContext) {
        RiverScenery.draw(width:width,time:time,environment:state.fishingEnvironment,context:c)
    }
}

/// A right triangular river inlet anchored to the lower-right desktop corner.
enum RiverScenery {
    // A curved water vignette: the far edge dissolves into the actual desktop.
    static func far(_ x:CGFloat,_ width:CGFloat)->CGFloat {
        let u=min(1,max(0,x/max(width,1)))
        return 310*(u+0.15*sin(u * .pi))
    }
    static func near(_ x:CGFloat,_ width:CGFloat)->CGFloat {
        let radius=min(170,width*0.27),u=(width-x)/radius
        return abs(u)<1 ? max(0,79*sqrt(1-u*u)-8):0
    }
    static func outline(width:CGFloat)->NSBezierPath {
        let p=NSBezierPath();p.move(to:.zero)
        for i in 1...100 {let x=width*CGFloat(i)/100;p.line(to:CGPoint(x:x,y:far(x,width)))}
        p.line(to:CGPoint(x:width,y:0));p.close();return p
    }
    static func edgeOpacity(_ p:CGPoint,width:CGFloat)->CGFloat {
        guard p.x>=0,p.x<=width,p.y>=0 else{return 0}
        let slope=310/max(width,1)*(1+0.15 * .pi*cos(p.x/max(width,1) * .pi))
        let t=min(1,max(0,(far(p.x,width)-p.y)/(24*sqrt(1+slope*slope))))
        return t*t*(3-2*t)
    }
    static func shore(width:CGFloat,offset:CGFloat=0)->NSBezierPath {
        let p=NSBezierPath(),start=width-min(170,width*0.27)
        p.move(to:CGPoint(x:start,y:offset))
        for i in 1...80 {let x=start+(width-start)*CGFloat(i)/80;p.line(to:CGPoint(x:x,y:near(x,width)+offset))}
        return p
    }
    static func water(width:CGFloat)->NSBezierPath {
        let p=outline(width:width)
        let sand=beach(width:width);p.append(sand);p.windingRule = .evenOdd
        return p
    }
    static func beach(width:CGFloat)->NSBezierPath {
        let p=shore(width:width);p.line(to:CGPoint(x:width,y:0));p.close();return p
    }
    static func contains(_ p:CGPoint,width:CGFloat)->Bool {
        p.x<width-20 && p.y>max(48,near(p.x,width)+10) && edgeOpacity(p,width:width)>0.85
    }
    static func clamp(_ p:CGPoint,width:CGFloat)->CGPoint {
        let x=min(width-26,max(width*0.32,p.x))
        let slope=310/max(width,1)*(1+0.15 * .pi*cos(x/max(width,1) * .pi))
        let ceiling=far(x,width)-30*sqrt(1+slope*slope)
        return CGPoint(x:x,y:min(ceiling,max(max(54,near(x,width)+14),p.y)))
    }
    private static var masks:[Int:CGImage]=[:]
    static func featherMask(width:CGFloat)->CGImage {
        let w=max(1,Int(ceil(width*2))),h=620
        if let cached=masks[w] {return cached}
        var bytes=[UInt8](repeating:0,count:w*h)
        for y in 0..<h {for x in 0..<w {
            // Image rows are top-down; drawing coordinates are bottom-up.
            bytes[y*w+x]=UInt8((edgeOpacity(CGPoint(x:(CGFloat(x)+0.5)/2,y:(CGFloat(h-y)-0.5)/2),width:width)*255).rounded())
        }}
        let data=Data(bytes) as CFData
        let image=CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:w,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGBitmapInfo(rawValue:0),provider:CGDataProvider(data:data)!,decode:nil,shouldInterpolate:true,intent:.defaultIntent)!
        if masks.count>4 {masks.removeAll()};masks[w]=image;return image
    }
    static func draw(width:CGFloat,time:TimeInterval,environment:FishingEnvironment,context c:CGContext) {
        let night=environment.nightAmount
        func color(_ day:(CGFloat,CGFloat,CGFloat),_ dark:(CGFloat,CGFloat,CGFloat))->NSColor {
            NSColor(srgbRed:day.0,green:day.1,blue:day.2,alpha:1).blended(withFraction:night,of:NSColor(srgbRed:dark.0,green:dark.1,blue:dark.2,alpha:1))!
        }
        c.saveGState();defer{c.restoreGState()}
        let frame=CGRect(x:0,y:0,width:width,height:310)
        c.clip(to:frame,mask:featherMask(width:width))
        NSGradient(colors:[color((0.38,0.61,0.54),(0.16,0.32,0.35)),color((0.16,0.37,0.37),(0.065,0.18,0.24))])!.draw(in:frame,angle:70)
        c.saveGState();water(width:width).addClip()
        // Shallow water wraps only the small beach, not the remote edge.
        for (offset,alpha,lineWidth) in [(CGFloat(10),CGFloat(0.20),CGFloat(32)),(CGFloat(4),CGFloat(0.24),CGFloat(12))] {
            color((0.76,0.80,0.61),(0.39,0.53,0.52)).withAlphaComponent(alpha).setStroke()
            let edge=shore(width:width,offset:offset);edge.lineWidth=lineWidth;edge.stroke()
        }
        for i in 0..<45 {
            let x=(CGFloat(i*91)+CGFloat(time*2.5)).truncatingRemainder(dividingBy:width+50)-25
            let y=CGFloat(32+(i*31)%265),length=CGFloat(9+i*7%23)
            let wave=NSBezierPath();wave.move(to:CGPoint(x:x,y:y));wave.curve(to:CGPoint(x:x+length,y:y),controlPoint1:CGPoint(x:x+length*0.3,y:y+0.8),controlPoint2:CGPoint(x:x+length*0.7,y:y-0.8))
            color((0.81,0.88,0.75),(0.49,0.70,0.68)).withAlphaComponent(0.19).setStroke();wave.lineWidth=0.65;wave.stroke()
        }
        for i in 0..<6 {
            let x=width*(0.78+CGFloat(i*7%13)*0.012),y=far(x,width)-CGFloat(52+i*11%32)
            let r=CGFloat(6+i%3*2),sway=CGFloat(sin(time*0.3+Double(i)))*0.7
            c.saveGState();c.translateBy(x:x+sway,y:y);c.scaleBy(x:1,y:0.55)
            NSColor.black.withAlphaComponent(0.13).setFill();NSBezierPath(ovalIn:CGRect(x:-r,y:-r-2,width:2*r,height:2*r)).fill()
            let leaf=NSBezierPath();leaf.move(to:.zero);leaf.appendArc(withCenter:.zero,radius:r,startAngle:22,endAngle:353,clockwise:false);leaf.close()
            color((0.44,0.60,0.37),(0.19,0.36,0.32)).setFill();leaf.fill()
            color((0.73,0.79,0.48),(0.41,0.56,0.44)).withAlphaComponent(0.6).setStroke();leaf.lineWidth=0.65;leaf.stroke();c.restoreGState()
        }
        c.restoreGState()
        let sand=beach(width:width)
        c.saveGState();sand.addClip()
        NSGradient(colors:[color((0.80,0.74,0.56),(0.31,0.35,0.32)),color((0.64,0.64,0.49),(0.22,0.30,0.30))])!.draw(in:frame,angle:70)
        for i in 0..<90 {
            let x=width-CGFloat(i*47%178),y=CGFloat(i*29%79)
            color((0.54,0.50,0.37),(0.14,0.20,0.20)).withAlphaComponent(0.18).setFill()
            NSBezierPath(ovalIn:CGRect(x:x,y:y,width:i%3==0 ? 1.4:0.7,height:0.6)).fill()
        }
        c.restoreGState()
        for i in 0..<2 {
            let pulse=CGFloat(sin(time*0.65+Double(i)*1.5)),edge=shore(width:width,offset:3+CGFloat(i)*6+pulse*2)
            color((0.87,0.90,0.74),(0.52,0.64,0.62)).withAlphaComponent(0.26-Double(i)*0.06).setStroke();edge.lineWidth=i==0 ? 1.4:0.7;edge.stroke()
        }
        // A tiny tuft anchors the corner without rebuilding a full coastline.
        for i in 0..<4 {
            let x=width-CGFloat(40+i*6),y=CGFloat(8+i%2*3)
            let grass=NSBezierPath();grass.move(to:CGPoint(x:x,y:y));grass.curve(to:CGPoint(x:x-3,y:y+10+CGFloat(i%2)*4),controlPoint1:CGPoint(x:x-1,y:y+6),controlPoint2:CGPoint(x:x-4,y:y+9))
            color((0.36,0.45,0.28),(0.12,0.24,0.23)).setStroke();grass.lineWidth=1.2;grass.stroke()
        }
    }
}

/// Shared by the actual river and the equipment preview.
enum FishingRodArtwork {
    static func draw(_ rod: FishingRod, start: CGPoint, tip: CGPoint, bend: CGFloat) {
        let colors: [FishingRod: NSColor] = [
            .bamboo: NSColor(srgbRed: 0.43, green: 0.49, blue: 0.25, alpha: 1),
            .rain: NSColor(srgbRed: 0.49, green: 0.29, blue: 0.15, alpha: 1),
            .wave: NSColor(srgbRed: 0.18, green: 0.24, blue: 0.27, alpha: 1),
            .ocean: NSColor(srgbRed: 0.16, green: 0.34, blue: 0.51, alpha: 1)
        ]
        let dx = tip.x - start.x, dy = tip.y - start.y
        let c1 = CGPoint(x: start.x + dx * 0.25 - bend * 4, y: start.y + dy * 0.32)
        let c2 = CGPoint(x: start.x + dx * 0.78 - bend * 6, y: start.y + dy * 0.80 + bend * 8)
        func point(_ t: CGFloat) -> CGPoint {
            let u = 1 - t
            return CGPoint(x: u*u*u*start.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*tip.x,
                           y: u*u*u*start.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*tip.y)
        }
        let path = NSBezierPath(); path.move(to: start); path.curve(to: tip, controlPoint1: c1, controlPoint2: c2)
        colors[rod]!.setStroke(); path.lineWidth = rod == .ocean ? 4 : 3; path.lineCapStyle = .round; path.stroke()
        let grip = NSBezierPath(); grip.move(to: start); grip.line(to: point(0.22))
        NSColor(srgbRed: 0.17, green: 0.22, blue: 0.20, alpha: 1).setStroke()
        grip.lineWidth = 6; grip.lineCapStyle = .round; grip.stroke()
        let trim = rod == .bamboo ? NSColor(srgbRed: 0.66, green: 0.65, blue: 0.35, alpha: 1) : rod == .rain ? NSColor(srgbRed: 0.82, green: 0.69, blue: 0.45, alpha: 1) : NSColor(srgbRed: 0.78, green: 0.86, blue: 0.88, alpha: 1)
        trim.setStroke()
        for t: CGFloat in [0.25, 0.44, 0.63, 0.82] {
            let p = point(t)
            let ring = NSBezierPath(); ring.move(to: CGPoint(x: p.x - 2.5, y: p.y - 1)); ring.line(to: CGPoint(x: p.x + 2.5, y: p.y + 1))
            ring.lineWidth = rod == .rain ? 3 : 1.5; ring.stroke()
            if rod == .wave || rod == .ocean {
                NSBezierPath(ovalIn: CGRect(x: p.x - 5, y: p.y - 3, width: 4, height: 5)).stroke()
            }
        }
        if rod == .ocean {
            trim.setFill()
            NSBezierPath(ovalIn: CGRect(x: point(0.17).x - 5, y: point(0.17).y - 5, width: 10, height: 10)).fill()
        }
    }
}
