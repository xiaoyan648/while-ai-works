import AppKit
import QuartzCore
import WhileCore

final class PlayView: NSView {
    struct Bubble {
        var point: CGPoint
        var radius: CGFloat
        var seed: CGFloat
        var poppedAt: TimeInterval?
        var popPressure: CGFloat = 0
        var pressedAt: TimeInterval?
        var deadline: TimeInterval?
        var contact = CGPoint.zero
        var appearedAt: TimeInterval
        var rect: CGRect { CGRect(x: point.x - radius - 12, y: point.y - radius - 12, width: radius * 2 + 24, height: radius * 2 + 24) }
    }
    struct FloatingStrike { var time: TimeInterval; var offset: CGFloat; var delta: Int = 1 }
    let state: AppState
    var bitmap: CGContext?
    var bitmapSize = CGSize.zero
    var bubbles: [Bubble] = []
    struct BubbleImageKey: Hashable { var radius: CGFloat; var seed: CGFloat; var flat: Bool; var scale: CGFloat }
    var bubbleImages: [BubbleImageKey: CGImage] = [:]
    var bubbleImageOrder: [BubbleImageKey] = []
    var stains: [StainProgress] = []
    var hoverPoint: CGPoint?
    var woodHitAt: TimeInterval = -100
    var floatingStrikes: [FloatingStrike] = []
    private var ticker: CADisplayLink?
    private let frameTarget = PlayFrameTarget()
    private let clock: () -> TimeInterval
    private let motionPreference: () -> Bool
    private(set) var handOrientation = HandOrientation()
    private(set) var clothDrag = CGPoint.zero
    private var targetClothDrag = CGPoint.zero
    private var lastClothMove: TimeInterval = -100
    struct CleanGleam { var point: CGPoint; var time: TimeInterval }
    var cleanGleams: [CleanGleam] = []
    var woodSwingAt: TimeInterval = -100
    var woodSwingFrom: CGFloat = -0.42
    private var pendingWoodContacts: [TimeInterval] = []
    private var lastMode: PlayMode?
    private var lastArea: PlayArea?
    private var lastReset: UUID?
    private var previousPoint: CGPoint?
    private var previousTime: TimeInterval = 0
    private var tracking: NSTrackingArea?
    private var lastSpawn: TimeInterval = 0
    private var dirtBudget: CGFloat = 0
    private var lastWorking = false
    private var hintUntil: TimeInterval = 0
    private var wasHeld = false
    private var mouseIsDown = false { didSet { state.mouseInteractionActive = mouseIsDown } }
    private(set) var toolPressure: CGFloat = 0
    private(set) var toolTilt: CGFloat = -0.12
    private var targetToolTilt: CGFloat = -0.12
    private var toolReboundAt: TimeInterval = -100
    private var lastToolTick = ProcessInfo.processInfo.systemUptime
    private var strikeGate = StrikeGate()
    private var woodAccessibility: PlayAccessibilityButton?
    private var bubbleAccessibility: PlayAccessibilityButton?
    private var fishingAccessibility: PlayAccessibilityButton?
    private var lastFishingPhase = FishingGame.Phase.ready
    var fishingVisualStartedAt: TimeInterval = 0
    private var lastFishingFrame: TimeInterval = 0
    private var lastFishingTick: TimeInterval?
    private var lastTotal = -1
    private var lastDecaySerial = 0
    private var lastWoodBalance = 0
    var now: TimeInterval { clock() }
    var reduceMotion: Bool { motionPreference() }
    var woodCenter: CGPoint {
        state.area == .edges ? CGPoint(x: bounds.maxX - 121, y: 103) : CGPoint(x: bounds.midX, y: bounds.midY - 12)
    }
    var woodRect: CGRect { CGRect(x: woodCenter.x - 89, y: woodCenter.y - 55, width: 178, height: 122) }
    var woodDrawingRect: CGRect { CGRect(x: woodCenter.x - 130, y: woodCenter.y - 91, width: 275, height: 270) }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(state: AppState, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.state = state
        self.clock = clock
        self.motionPreference = reduceMotion
        super.init(frame: .zero)
        lastDecaySerial = state.woodDecaySerial
        lastWoodBalance = state.woodBalance
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("桌面解压")
        frameTarget.view = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { ticker?.invalidate() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ticker?.invalidate(); ticker = nil
        lastFishingTick = nil
        if window != nil {
            let link = displayLink(target: frameTarget, selector: #selector(PlayFrameTarget.step(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            ticker = link
            sync()
        } else {
            cancelInteraction()
        }
    }
    override func layout() {
        super.layout()
        if bounds.width > 0, bounds.height > 0, bitmapSize != bounds.size { configureCanvas() }
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }
    func sync() {
        if state.mode != lastMode || state.area != lastArea || lastReset != state.resetID {
            lastMode = state.mode; lastArea = state.area; lastReset = state.resetID
            lastFishingTick = nil
            cancelInteraction()
            configureCanvas()
        }
        setAccessibilityHelp(state.mode.hint)
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }
    func setInteractionEnabled(_ enabled: Bool) {
        if wasHeld != enabled {
            wasHeld = enabled
            if !enabled {
                cancelInteraction(); updateToolPoint(nil)
                if window != nil { NSCursor.arrow.set() }
            } else if let window {
                let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
                if bounds.contains(point) { updateToolPoint(point) }
            }
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }
    func cancelInteraction() {
        if previousPoint != nil { PlayAudio.shared.endWipe() }
        state.castStartedAt = nil
        previousPoint = nil
        mouseIsDown = false
        state.fishingRelease()
        toolPressure = 0; toolReboundAt = -100
        clothDrag = .zero; targetClothDrag = .zero
        pendingWoodContacts.removeAll()
        woodSwingAt = -100
        targetToolTilt = -0.12
        if window != nil, wasHeld { NSCursor.arrow.set() }
        strikeGate.release()
        for index in bubbles.indices where bubbles[index].pressedAt != nil && bubbles[index].poppedAt == nil {
            bubbles[index].pressedAt = nil; bubbles[index].deadline = nil
        }
    }
    private func configureCanvas() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        bitmapSize = bounds.size
        bitmap = nil
        bubbles.removeAll()
        bubbleImages.removeAll(); bubbleImageOrder.removeAll()
        stains.removeAll()
        lastDecaySerial = state.woodDecaySerial
        floatingStrikes.removeAll()
        cleanGleams.removeAll()
        dirtBudget = 0
        if state.mode == .wipe {
            let scale = min(window?.backingScaleFactor ?? 2, 2)
            let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
            bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                               bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            bitmap?.scaleBy(x: scale, y: scale)
            for _ in 0..<(state.area == .edges ? 14 : 28) { spawnDirt() }
        } else if state.mode == .bubbles { makeBubbles() }
        updateAccessibility()
        needsDisplay = true
    }
    private func makeBubbles() {
        let step: CGFloat = 69
        let radius: CGFloat = 27
        let inset: CGFloat = 38
        let cols = max(1, Int((bounds.width - inset * 2) / step) + 1)
        let rows = max(1, Int((bounds.height - inset * 2) / step) + 1)
        let origin = CGPoint(x: bounds.midX - CGFloat(cols - 1) * step / 2,
                             y: bounds.midY - CGFloat(rows - 1) * step / 2)
        for row in 0..<rows {
            for col in 0..<cols {
                if state.area == .edges && row != 0 && row != rows - 1 && col != 0 && col != cols - 1 { continue }
                let point = CGPoint(x: origin.x + CGFloat(col) * step, y: origin.y + CGFloat(row) * step)
                if CGRect(x: point.x - 29, y: point.y - 29, width: 58, height: 58).intersects(counterRect) { continue }
                bubbles.append(Bubble(point: point,
                                      radius: radius + CGFloat.random(in: -1.3...1.3), seed: CGFloat.random(in: 0...100),
                                      appearedAt: now))
            }
        }
    }
    private func spawnDirt() {
        guard let context = bitmap, bounds.width > 60, bounds.height > 60 else { return }
        let point: CGPoint
        if state.area == .edges {
            switch Int.random(in: 0...3) {
            case 0: point = CGPoint(x: CGFloat.random(in: 30...(bounds.width - 30)), y: CGFloat.random(in: 25...65))
            case 1: point = CGPoint(x: CGFloat.random(in: 30...(bounds.width - 30)), y: bounds.height - CGFloat.random(in: 25...65))
            default: point = CGPoint(x: Bool.random() ? CGFloat.random(in: 25...70) : bounds.width - CGFloat.random(in: 25...70),
                                     y: CGFloat.random(in: 50...max(51, bounds.height - 50)))
            }
        } else {
            point = CGPoint(x: CGFloat.random(in: 45...max(46, bounds.width - 45)),
                            y: CGFloat.random(in: 45...max(46, bounds.height - 45)))
        }
        let radius = CGFloat.random(in: 24...49)
        if Int(dirtBudget).isMultiple(of: 3) {
            let mark = InteractionArtwork.pawPrintPath(center: point, radius: radius, angle: CGFloat.random(in: -0.6...0.6))
            context.saveGState()
            context.setFillColor(NSColor(srgbRed: 0.29, green: 0.34, blue: 0.29, alpha: 0.23).cgColor)
            context.addPath(mark); context.fillPath(); context.restoreGState()
            stains.append(StainProgress(center: point, radius: radius, bounds: bounds, coverage: { mark.contains($0) }))
            dirtBudget += 1
            setNeedsDisplay(CGRect(x: point.x-radius-2, y: point.y-radius-2, width: radius*2+4, height: radius*2+4))
            return
        }
        context.saveGState()
        context.clip(to: CGRect(x: point.x-radius, y: point.y-radius, width: radius*2, height: radius*2))
        context.addEllipse(in: CGRect(x: point.x-radius, y: point.y-radius, width: radius*2, height: radius*2)); context.clip()
        context.translateBy(x: point.x, y: point.y)
        context.rotate(by: CGFloat.random(in: -0.5...0.5))
        let tone = NSColor(srgbRed: 0.32, green: 0.35, blue: 0.30, alpha: 0.13)
        context.setLineCap(.round)
        switch Int.random(in: 0...2) {
        case 0:
            // Fine fingerprint ridges inside a soft oval, never four identical painted strokes.
            context.saveGState(); context.scaleBy(x: 0.72, y: 1)
            let colors = [tone.withAlphaComponent(0.11).cgColor, tone.withAlphaComponent(0).cgColor]
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0,1]) {
                context.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius*0.92, options: [])
            }
            context.setLineWidth(0.6); context.setStrokeColor(tone.withAlphaComponent(0.18).cgColor)
            for index in 0..<9 {
                let r = radius*(0.18+CGFloat(index)*0.075)
                context.addArc(center: CGPoint(x: 0,y: -radius*0.08), radius: r,
                               startAngle: -.pi*0.27, endAngle: .pi*1.23, clockwise: false); context.strokePath()
            }
            context.restoreGState()
        case 1:
            // A broken, thin water mark with a faint deposit along one side.
            context.saveGState(); context.scaleBy(x: 1, y: 0.78)
            context.setStrokeColor(tone.withAlphaComponent(0.20).cgColor); context.setLineWidth(1.1)
            context.addArc(center: .zero, radius: radius*0.78, startAngle: 0.12, endAngle: .pi*1.75, clockwise: false); context.strokePath()
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor); context.setLineWidth(0.8)
            context.addArc(center: .zero, radius: radius*0.78-1, startAngle: 0.7, endAngle: .pi*1.6, clockwise: false); context.strokePath()
            context.restoreGState()
        default:
            context.setShadow(offset: .zero, blur: 3, color: tone.cgColor)
            for index in 0..<3 {
                let y = CGFloat(index-1)*radius*0.27
                context.setLineWidth(radius*0.26)
                context.setStrokeColor(tone.withAlphaComponent(0.07).cgColor)
                context.move(to: CGPoint(x: -radius*0.6,y: y))
                context.addQuadCurve(to: CGPoint(x: radius*0.57,y: y+radius*0.19), control: CGPoint(x: 0,y: y-radius*0.05)); context.strokePath()
            }
            context.setShadow(offset: .zero, blur: 0, color: nil)
        }
        for _ in 0..<38 {
            let a = CGFloat.random(in: 0...(.pi*2)), d = radius*sqrt(CGFloat.random(in: 0...1))
            let size = CGFloat.random(in: 0.4...1.2)
            context.setFillColor(tone.withAlphaComponent(CGFloat.random(in: 0.06...0.18)).cgColor)
            context.fillEllipse(in: CGRect(x: cos(a)*d, y: sin(a)*d, width: size, height: size))
        }
        context.restoreGState()
        dirtBudget += 1
        stains.append(StainProgress(center: point, radius: radius, bounds: bounds))
        setNeedsDisplay(CGRect(x: point.x - 100, y: point.y - 100, width: 200, height: 200))
    }
    fileprivate func tick() {
        guard let window, window.isVisible else { return }
        let time = now
        if state.mode != lastMode || state.area != lastArea || state.resetID != lastReset { sync() }
        advanceInteractionAnimation(at: time)
        if state.isWorking != lastWorking {
            if lastWorking && !state.isWorking && state.followAI { hintUntil = time + 2.5 }
            lastWorking = state.isWorking
            lastSpawn = time
            needsDisplay = true
        }
        if state.isWorking && time - lastSpawn > (state.mode == .wipe ? 2.8 : 0.9) {
            lastSpawn = time
            switch state.mode {
            case .wipe: if dirtBudget < (state.area == .edges ? 28 : 60) { spawnDirt() }
            case .bubbles:
                if let index = bubbles.indices.filter({ bubbles[$0].poppedAt.map { time - $0 > 5 } ?? false })
                    .min(by: { (bubbles[$0].poppedAt ?? 0) < (bubbles[$1].poppedAt ?? 0) }) {
                    bubbles[index].poppedAt = nil; bubbles[index].pressedAt = nil
                    bubbles[index].popPressure = 0; bubbles[index].contact = .zero
                    bubbles[index].appearedAt = time
                    setNeedsDisplay(bubbles[index].rect)
                }
            case .woodfish, .fishing: break
            }
        }
        advanceFishingAnimation(at: time)
        if state.mode == .woodfish {
            if time - woodSwingAt < 0.32 || time - woodHitAt < 0.5 || !floatingStrikes.isEmpty { setNeedsDisplay(woodDrawingRect) }
            floatingStrikes.removeAll { time - $0.time > 0.95 }
            if state.woodDecaySerial != lastDecaySerial {
                lastDecaySerial = state.woodDecaySerial
                floatingStrikes.append(FloatingStrike(time: time, offset: 0, delta: -1))
                setNeedsDisplay(woodDrawingRect)
            }
            if state.woodBalance != lastWoodBalance {
                lastWoodBalance = state.woodBalance; updateAccessibility(); setNeedsDisplay(woodDrawingRect)
            }
        }
        if state.total(for: state.mode) != lastTotal {
            lastTotal = state.total(for: state.mode)
            setNeedsDisplay(counterRect)
        }
        if time < hintUntil + 0.04 && hintUntil > 0 { setNeedsDisplay(CGRect(x: 0, y: bounds.height - 75, width: bounds.width, height: 70)) }
    }
    /// Advance gameplay once per display callback, immediately before requesting its draw.
    /// Reduce Motion suppresses scenery motion, never the feedback needed to control a fish.
    func advanceFishingAnimation(at time: TimeInterval) {
        guard state.mode == .fishing, state.desktopEnabled else {
            lastFishingTick = nil
            return
        }
        let previous = lastFishingTick
        lastFishingTick = time
        if let previous, time > previous, time - previous <= 0.25 {
            // Small steps keep acceleration stable across refresh rates and brief missed frames.
            var remaining = time - previous
            while remaining > 0.000001 {
                let step = min(remaining, 1.0 / 120)
                state.advanceFishing(delta: step)
                remaining -= step
            }
        }
        // Do not threshold active frames at 1/60: tiny display-link jitter would skip them.
        if state.fishing.engaged || state.castStartedAt != nil || time - lastFishingFrame >= (reduceMotion ? 0.125 : 1.0 / 30) {
            lastFishingFrame = time
            setNeedsDisplay(fishingRect.insetBy(dx: -2, dy: -2))
        }
        if state.fishing.phase != lastFishingPhase {
            lastFishingPhase = state.fishing.phase
            fishingVisualStartedAt = time
            updateAccessibility()
        }
    }
    func advanceInteractionAnimation(at time: TimeInterval) {
        updateToolAnimation(at: time)
        // Sort across *all* gestures, so a fast release cannot revert to array order.
        let due = bubbles.indices.filter { bubbles[$0].deadline.map { $0 <= time } ?? false }
            .sorted { bubbles[$0].deadline! < bubbles[$1].deadline! }
        for index in due { popBubble(index, at: time) }
        for bubble in bubbles where time-bubble.appearedAt < 0.26 ||
            (bubble.pressedAt != nil && bubble.poppedAt == nil) || (bubble.poppedAt.map { time-$0 < 0.28 } ?? false) {
            setNeedsDisplay(bubble.rect)
        }
        let contacts = pendingWoodContacts.filter { $0 <= time }
        pendingWoodContacts.removeAll { $0 <= time }
        for _ in contacts { completeWoodContact(at: time) }
        for gleam in cleanGleams { setNeedsDisplay(CGRect(x: gleam.point.x-42, y: gleam.point.y-38, width: 84, height: 76)) }
        cleanGleams.removeAll { time-$0.time > 0.24 }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // Layer-backed AppKit views may supply an unclipped CGContext. Never repaint
        // translucent neighbouring bubbles outside the pixels we just cleared.
        context.saveGState()
        context.clip(to: dirtyRect)
        defer { context.restoreGState() }
        context.clear(dirtyRect)
        switch state.mode {
        case .wipe:
            if let image = bitmap?.makeImage() { context.draw(image, in: bounds) }
            for gleam in cleanGleams {
                let t = min(1, max(0, (now-gleam.time)/0.24))
                context.saveGState()
                context.setStrokeColor(PlayChrome.accent.withAlphaComponent((1-t)*0.26).cgColor)
                context.setLineWidth(1.3); context.setLineCap(.round)
                let y = gleam.point.y + (reduceMotion ? 0 : CGFloat(t)*9)
                context.move(to: CGPoint(x: gleam.point.x-12, y: y))
                context.addQuadCurve(to: CGPoint(x: gleam.point.x+12, y: y), control: CGPoint(x: gleam.point.x, y: y+3)); context.strokePath()
                context.restoreGState()
            }
        case .bubbles:
            for bubble in bubbles where bubble.rect.intersects(dirtyRect) { drawDesktopBubble(bubble, at: now, context: context) }
        case .woodfish: if woodDrawingRect.intersects(dirtyRect) { drawWoodfish(at: now, context: context) }
        case .fishing: if fishingRect.intersects(dirtyRect) { drawFishing(at: now, context: context) }
        }
        if state.mode == .wipe || state.mode == .bubbles { drawCounter() }
        if wasHeld, let point = hoverPoint {
            switch state.mode {
            case .wipe: InteractionArtwork.cloth(at: point, pressure: toolPressure, angle: toolTilt, drag: clothDrag, snow: state.mascotCoat == .snow, context: context)
            case .bubbles:
                let age = now - toolReboundAt
                let rebound = reduceMotion || age > 0.24 ? 0 : CGFloat(exp(-age * 16) * sin(age * 32))
                InteractionArtwork.finger(at: point, pressure: toolPressure, rebound: rebound,
                                          angle: handOrientation.angle, snow: state.mascotCoat == .snow, context: context)
            case .woodfish, .fishing: break
            }
        }
        if state.mode != .fishing && (wasHeld || now < hintUntil) { drawHint() }
    }
    private var counterRect: CGRect { CGRect(x: bounds.midX - 140, y: 2, width: 280, height: 37) }
    private func drawCounter() {
        let text = state.countLabel(for: state.mode) as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: PlayChrome.ink]
        let size = text.size(withAttributes: attributes)
        let pill = CGRect(x: bounds.midX - size.width / 2 - 12, y: 8, width: size.width + 24, height: 25)
        if let c = NSGraphicsContext.current?.cgContext { PlayChrome.panel(pill, context: c) }
        text.draw(at: CGPoint(x: pill.minX + 12, y: pill.minY + 7), withAttributes: attributes)
    }
    private func drawHint() {
        let text = (now < hintUntil ? "AI 暂时忙完了" : state.mode.hint) as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: PlayChrome.ink]
        let size = text.size(withAttributes: attrs)
        let rect = CGRect(x: bounds.midX - size.width / 2 - 16, y: bounds.height - 56, width: size.width + 32, height: 32)
        if let c = NSGraphicsContext.current?.cgContext { PlayChrome.panel(rect, radius: 16, context: c) }
        text.draw(at: CGPoint(x: rect.minX + 16, y: rect.minY + 9), withAttributes: attrs)
    }
    func toolRect(at point: CGPoint) -> CGRect {
        let radius: CGFloat = state.mode == .bubbles ? 120 : 58
        return CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
    }
    private func updateToolPoint(_ point: CGPoint?) {
        if let old = hoverPoint { setNeedsDisplay(toolRect(at: old)) }
        hoverPoint = point
        if let point {
            handOrientation.update(point: point, bounds: bounds, pressed: mouseIsDown, delta: 0, reduceMotion: reduceMotion)
            setNeedsDisplay(toolRect(at: point))
        }
    }
    private func updateToolAnimation(at time: TimeInterval) {
        let delta = min(0.05, max(0, time - lastToolTick))
        lastToolTick = time
        guard wasHeld, let point = hoverPoint, (state.mode == .wipe || state.mode == .bubbles) else { return }
        let beforePressure = toolPressure, beforeTilt = toolTilt
        let beforeAngle = handOrientation.angle, beforeDrag = clothDrag
        handOrientation.update(point: point, bounds: bounds, pressed: mouseIsDown, delta: delta, reduceMotion: reduceMotion)
        if time-lastClothMove > 0.055 { targetClothDrag = .zero }
        if reduceMotion { clothDrag = .zero }
        else {
            let blend = CGFloat(1-exp(-delta/0.045))
            clothDrag.x += (targetClothDrag.x-clothDrag.x)*blend
            clothDrag.y += (targetClothDrag.y-clothDrag.y)*blend
        }
        let target: CGFloat = mouseIsDown ? 1 : 0
        if reduceMotion { toolPressure = target; toolTilt = -0.12 }
        else {
            toolPressure += (target - toolPressure) * CGFloat(1 - exp(-delta / 0.055))
            toolTilt += (targetToolTilt - toolTilt) * CGFloat(1 - exp(-delta / 0.07))
        }
        if abs(toolPressure - beforePressure) > 0.001 || abs(toolTilt - beforeTilt) > 0.001 ||
            abs(beforeAngle-handOrientation.angle) > 0.001 || hypot(beforeDrag.x-clothDrag.x, beforeDrag.y-clothDrag.y) > 0.002 || time - toolReboundAt < 0.25 {
            setNeedsDisplay(toolRect(at: point))
        }
    }
    override func resetCursorRects() {
        if wasHeld, (state.mode == .wipe || state.mode == .bubbles) { addCursorRect(bounds, cursor: InteractionArtwork.clearCursor) }
        else { addCursorRect(bounds, cursor: .arrow) }
    }
    override func cursorUpdate(with event: NSEvent) {
        guard window != nil else { return }
        if wasHeld, (state.mode == .wipe || state.mode == .bubbles) { InteractionArtwork.clearCursor.set() }
        else { NSCursor.arrow.set() }
    }
    private func popBubble(_ index: Int, at time: TimeInterval) {
        guard bubbles.indices.contains(index), bubbles[index].poppedAt == nil else { return }
        bubbles[index].popPressure = BubblePose(pressedAt: bubbles[index].pressedAt, poppedAt: nil, popPressure: 0,
                                               at: time, reduceMotion: reduceMotion).pressure
        bubbles[index].poppedAt = time
        if let point = hoverPoint, wasHeld,
           hypot(point.x - bubbles[index].point.x, point.y - bubbles[index].point.y) < bubbles[index].radius * 1.4 {
            toolReboundAt = time
            toolPressure = max(toolPressure, 0.75)
            setNeedsDisplay(toolRect(at: point))
        }
        state.poppedBubble()
        bubbles[index].deadline = nil
        if state.soundEnabled { PlayAudio.shared.pop(position: Double(bubbles[index].point.x / bounds.width) * 2 - 1) }
        if window != nil { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
        updateAccessibility()
        setNeedsDisplay(bubbles[index].rect)
    }
    private func pressBubbles(from start: CGPoint, to end: CGPoint, sweeping: Bool) {
        let time = now
        let hits = bubbles.indices.compactMap { index -> (Int, BubbleContact)? in
            guard bubbles[index].poppedAt == nil, bubbles[index].pressedAt == nil,
                  let hit = BubbleContact.hit(center: bubbles[index].point, radius: bubbles[index].radius, from: start, to: end) else { return nil }
            return (index, hit)
        }.sorted { $0.1.entry < $1.1.entry }
        let lastDeadline = bubbles.compactMap(\.deadline).max() ?? time
        for (sequence, item) in hits.enumerated() {
            let (index, hit) = item
            let p = bubbles[index].point
            bubbles[index].pressedAt = time
            bubbles[index].contact = CGPoint(x: hit.point.x-p.x, y: hit.point.y-p.y)
            bubbles[index].deadline = max(time+(sweeping ? 0.055 : 0.095), lastDeadline+0.008) + Double(sequence)*0.008
            setNeedsDisplay(bubbles[index].rect)
        }
    }
    private func wipe(from start: CGPoint, to end: CGPoint, elapsed: TimeInterval) {
        let distance = hypot(end.x - start.x, end.y - start.y)
        guard distance > 0.5 else { return }
        let footprint = ClothContact.sweep(from: start, to: end)
        let dirt = dirtAlpha(in: footprint)
        if let context = bitmap {
            context.saveGState(); context.setBlendMode(.destinationOut)
            context.setFillColor(NSColor.white.cgColor); context.addPath(footprint); context.fillPath(); context.restoreGState()
        }
        if state.soundEnabled { PlayAudio.shared.wipe(speed: Double(distance) / max(0.008, elapsed), dirt: dirt) }
        if dirt > 0.01 { dirtBudget = max(0, dirtBudget - distance / 350) }
        for index in stains.indices {
            if stains[index].erase(where: { footprint.contains($0) }) {
                state.wipedStain()
                cleanGleams.append(CleanGleam(point: end, time: now))
            }
        }
        stains.removeAll { $0.completed }
        setNeedsDisplay(footprint.boundingBoxOfPath.insetBy(dx: -2, dy: -2))
    }
    /// Sample the actual contact area before erasing it. The centre is already clean
    /// on consecutive drag events; only the leading edge may still touch dirt.
    func dirtAlpha(in footprint: CGPath) -> Double {
        guard let bitmap, let data = bitmap.data, bounds.width > 0 else { return 0 }
        let scale = CGFloat(bitmap.width) / bounds.width
        let rect = footprint.boundingBoxOfPath.intersection(bounds)
        guard !rect.isNull, !rect.isEmpty else { return 0 }
        let minX = max(0, Int(floor(rect.minX * scale)))
        let maxX = min(bitmap.width - 1, Int(ceil(rect.maxX * scale)))
        let minY = max(0, Int(floor(rect.minY * scale)))
        let maxY = min(bitmap.height - 1, Int(ceil(rect.maxY * scale)))
        // Bound work for very long coalesced drags, while retaining pixel-scale
        // sampling for ordinary movements and thin ink along the cloth edge.
        let step = max(1, Int(ceil(sqrt(Double((maxX-minX+1)*(maxY-minY+1)) / 16384))))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var maximum: UInt8 = 0
        for y in stride(from: minY, through: maxY, by: step) {
            let row = (bitmap.height - 1 - y) * bitmap.bytesPerRow
            for x in stride(from: minX, through: maxX, by: step) {
                let alpha = bytes[row + x * 4 + 3]
                if alpha > maximum && footprint.contains(CGPoint(x: (CGFloat(x)+0.5)/scale, y: (CGFloat(y)+0.5)/scale)) {
                    maximum = alpha
                    if maximum == 255 { return 1 }
                }
            }
        }
        return Double(maximum) / 255
    }
    private func strikeWood() {
        let time = now
        woodSwingFrom = malletAngle(at: time)
        woodSwingAt = time
        pendingWoodContacts.append(time + (reduceMotion ? 0 : 0.035))
        if reduceMotion { advanceInteractionAnimation(at: time) }
        setNeedsDisplay(woodDrawingRect)
    }
    private func completeWoodContact(at time: TimeInterval) {
        state.strike()
        woodHitAt = time
        if let last = floatingStrikes.last, last.delta > 0, time-last.time < 0.18 {
            floatingStrikes[floatingStrikes.count-1].delta += 1
            floatingStrikes[floatingStrikes.count-1].time = time
        } else { floatingStrikes.append(FloatingStrike(time: time, offset: 0)) }
        if floatingStrikes.count > 16 { floatingStrikes.removeFirst() }
        if state.soundEnabled { PlayAudio.shared.wood(position: Double(woodCenter.x / bounds.width) * 2 - 1) }
        if window != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        updateAccessibility()
        setNeedsDisplay(woodDrawingRect)
    }
    private func updateAccessibility() {
        if state.mode == .woodfish, let window {
            let button = woodAccessibility ?? PlayAccessibilityButton()
            button.setAccessibilityRole(.button)
            button.setAccessibilityEnabled(true)
            button.setAccessibilityLabel("敲木鱼")
            button.setAccessibilityValue("当前 \(state.woodBalance)，累计敲击 \(state.totalStrikes) 次")
            button.setAccessibilityParent(self)
            button.setAccessibilityFrame(window.convertToScreen(convert(woodRect, to: nil)))
            button.action = { [weak self] in self?.strikeWood() }
            woodAccessibility = button
            setAccessibilityChildren([button])
        } else if state.mode == .bubbles, let window, let index = bubbles.firstIndex(where: { $0.poppedAt == nil }) {
            let button = bubbleAccessibility ?? PlayAccessibilityButton()
            button.setAccessibilityRole(.button)
            button.setAccessibilityEnabled(true)
            button.setAccessibilityLabel("捏下一颗气泡")
            button.setAccessibilityValue("已捏破 \(state.totalBubbles) 颗")
            button.setAccessibilityParent(self)
            button.setAccessibilityFrame(window.convertToScreen(convert(bubbles[index].rect, to: nil)))
            button.action = { [weak self] in
                guard let self, let next = self.bubbles.firstIndex(where: { $0.poppedAt == nil }) else { return }
                let point = self.bubbles[next].point
                self.pressBubbles(from: point, to: point, sweeping: false)
            }
            bubbleAccessibility = button
            setAccessibilityChildren([button])
        } else if state.mode == .fishing, let window {
            let button = fishingAccessibility ?? PlayAccessibilityButton()
            button.setAccessibilityRole(.button)
            button.setAccessibilityEnabled(true)
            button.setAccessibilityLabel(state.fishing.phase == .bite ? "提竿" : state.fishing.phase == .fighting ? (state.fishing.pressed ? "松开浮条，向下移动" : "按住浮条，向上移动") : "钓鱼抛竿或收竿")
            button.setAccessibilityValue(state.fishing.phase == .fighting ? "鱼位 \(Int(state.fishing.fish*100))，浮条 \(Int(state.fishing.bar*100))，进度 \(Int(state.fishing.progress*100))%" : "总鱼获 \(state.fishingBook.total)")
            button.setAccessibilityParent(self)
            button.setAccessibilityFrame(window.convertToScreen(convert(fishingRect, to: nil)))
            button.action = { [weak self] in self?.state.fishingAccessiblePress() }
            fishingAccessibility = button
            setAccessibilityChildren([button])
        } else { woodAccessibility = nil; bubbleAccessibility = nil; fishingAccessibility = nil; setAccessibilityChildren([]) }
    }
    override func mouseDown(with event: NSEvent) {
        guard wasHeld else { return }
        let point = convert(event.locationInWindow, from: nil)
        mouseIsDown = true; previousPoint = point; previousTime = event.timestamp
        toolPressure = reduceMotion ? 1 : 0.25
        lastToolTick = now
        updateToolPoint(point)
        cursorUpdate(with: event)
        switch state.mode {
        case .wipe: break // A click without movement does not scrub or make a sound.
        case .bubbles: pressBubbles(from: point, to: point, sweeping: false)
        case .woodfish: if strikeGate.press(onTarget: woodRect.contains(point)) { strikeWood() }
        case .fishing:
            if fishingContains(point) {
                if state.dismissFishingCatch(at: event.timestamp) {
                    // Consume this entire gesture: dragging and releasing cannot start a cast.
                    setNeedsDisplay(fishingRect)
                    updateAccessibility()
                } else if [.ready, .escaped].contains(state.fishing.phase) {
                    state.castStartedAt = event.timestamp
                    updateCastAim(point)
                } else { state.fishingPress() }
            }
        }
        setNeedsDisplay(toolRect(at: point))
    }
    override func mouseDragged(with event: NSEvent) {
        guard wasHeld, mouseIsDown else { return }
        let point = convert(event.locationInWindow, from: nil)
        if state.castStartedAt != nil { updateCastAim(point) }
        let start = previousPoint ?? point
        if state.mode == .wipe {
            let dx = point.x - start.x, dy = point.y - start.y
            if hypot(dx, dy) > 1 {
                targetToolTilt = -0.10 + min(0.13, max(-0.13, atan2(dy, abs(dx)+8)*0.10))
                let elapsed = max(0.008, event.timestamp-previousTime)
                targetClothDrag = CGPoint(x: -min(4, max(-4, dx/elapsed*0.006)), y: -min(4, max(-4, dy/elapsed*0.006)))
                lastClothMove = now
            }
            wipe(from: start, to: point, elapsed: event.timestamp - previousTime)
        }
        if state.mode == .bubbles { pressBubbles(from: start, to: point, sweeping: true) }
        previousPoint = point; previousTime = event.timestamp
        updateToolPoint(point)
        cursorUpdate(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        if state.mode == .fishing, state.castStartedAt != nil {
            let landing = castTarget(at: event.timestamp)
            let tip = fishingRodTip(at: event.timestamp)
            state.finishCast(at: event.timestamp, landing: CGPoint(x: landing.x / fishingRect.width, y: landing.y / 195), water: castWater(at: landing),
                             origin: CGPoint(x: tip.x / fishingRect.width, y: tip.y / 195))
        }
        state.fishingRelease()
        // A quick release keeps its brief dent/collapse sequence and traversal order.
        // Deadlines are serviced by the common animation clock, never by array-order mouse-up.
        PlayAudio.shared.endWipe()
        previousPoint = nil; mouseIsDown = false; strikeGate.release()
        targetToolTilt = -0.10; targetClothDrag = .zero
        if let point = hoverPoint { setNeedsDisplay(toolRect(at: point)) }
    }
    override func mouseEntered(with event: NSEvent) {
        guard wasHeld else { return }
        updateToolPoint(convert(event.locationInWindow, from: nil))
        cursorUpdate(with: event)
    }
    override func mouseMoved(with event: NSEvent) {
        guard wasHeld else { return }
        updateToolPoint(convert(event.locationInWindow, from: nil))
        cursorUpdate(with: event)
    }
    override func mouseExited(with event: NSEvent) {
        updateToolPoint(nil)
        cancelInteraction()
    }
}

private final class PlayAccessibilityButton: NSAccessibilityElement {
    var action: (() -> Void)?
    override func accessibilityPerformPress() -> Bool { action?(); return true }
}

/// CADisplayLink retains its target; keep that target weak toward the view.
private final class PlayFrameTarget: NSObject {
    weak var view: PlayView?
    @objc func step(_ link: CADisplayLink) { view?.tick() }
}
