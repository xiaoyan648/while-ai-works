import AppKit
import WhileCore

final class PlayView: NSView {
    struct Bubble {
        var point: CGPoint
        var radius: CGFloat
        var seed: CGFloat
        var poppedAt: TimeInterval?
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
    var stains: [StainProgress] = []
    var hoverPoint: CGPoint?
    var woodHitAt: TimeInterval = -100
    var floatingStrikes: [FloatingStrike] = []
    private var ticker: Timer?
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
    private var lastTotal = -1
    private var lastDecaySerial = 0
    private var lastWoodBalance = 0
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var woodCenter: CGPoint {
        state.area == .edges ? CGPoint(x: bounds.maxX - 121, y: 103) : CGPoint(x: bounds.midX, y: bounds.midY - 12)
    }
    var woodRect: CGRect { CGRect(x: woodCenter.x - 89, y: woodCenter.y - 55, width: 178, height: 122) }
    var woodDrawingRect: CGRect { CGRect(x: woodCenter.x - 130, y: woodCenter.y - 91, width: 275, height: 270) }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(state: AppState) {
        self.state = state
        super.init(frame: .zero)
        lastDecaySerial = state.woodDecaySerial
        lastWoodBalance = state.woodBalance
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("桌面解压")
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { ticker?.invalidate() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil { sync() } }
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
        stains.removeAll()
        lastDecaySerial = state.woodDecaySerial
        floatingStrikes.removeAll()
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
        context.saveGState()
        let tone = CGFloat.random(in: 0.31...0.43)
        for _ in 0..<6 {
            let center = CGPoint(x: point.x + CGFloat.random(in: -radius * 0.4...radius * 0.4),
                                 y: point.y + CGFloat.random(in: -radius * 0.4...radius * 0.4))
            let colors = [NSColor(srgbRed: tone + 0.09, green: tone + 0.025, blue: tone - 0.035, alpha: 0.22).cgColor,
                          NSColor(srgbRed: tone + 0.09, green: tone + 0.025, blue: tone - 0.035, alpha: 0).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                           endCenter: center, endRadius: radius * CGFloat.random(in: 0.6...1.2), options: [])
            }
        }
        for _ in 0..<230 {
            let angle = CGFloat.random(in: 0...(2 * .pi))
            let distance = radius * sqrt(CGFloat.random(in: 0...1))
            let size = CGFloat.random(in: 0.4...1.9)
            let p = CGPoint(x: point.x + cos(angle) * distance, y: point.y + sin(angle) * distance * 0.8)
            context.setFillColor(NSColor(srgbRed: tone, green: tone - 0.02, blue: tone - 0.06,
                                        alpha: CGFloat.random(in: 0.08...0.3) * (1 - distance / radius)).cgColor)
            context.fillEllipse(in: CGRect(x: p.x, y: p.y, width: size, height: size))
        }
        context.restoreGState()
        dirtBudget += 1
        stains.append(StainProgress(center: point, radius: radius, bounds: bounds))
        setNeedsDisplay(CGRect(x: point.x - 100, y: point.y - 100, width: 200, height: 200))
    }
    private func tick() {
        guard let window, window.isVisible else { return }
        let time = now
        updateToolAnimation(at: time)
        if state.mode != lastMode || state.area != lastArea || state.resetID != lastReset { sync() }
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
                    bubbles[index].appearedAt = time
                    setNeedsDisplay(bubbles[index].rect)
                }
            case .woodfish, .fishing: break
            }
        }
        for index in bubbles.indices {
            if let deadline = bubbles[index].deadline, time >= deadline, bubbles[index].poppedAt == nil { popBubble(index) }
            if time - bubbles[index].appearedAt < 0.32 || bubbles[index].pressedAt != nil && bubbles[index].poppedAt == nil ||
                (bubbles[index].poppedAt.map { time - $0 < 0.34 } ?? false) { setNeedsDisplay(bubbles[index].rect) }
        }
        if state.mode == .fishing {
            let interval = reduceMotion ? 0.125 : (state.fishing.engaged ? 1.0 / 60 : 1.0 / 30)
            if time - lastFishingFrame >= interval {
                lastFishingFrame = time
                setNeedsDisplay(fishingRect.insetBy(dx: -2, dy: -2))
            }
            if state.fishing.phase != lastFishingPhase {
                lastFishingPhase = state.fishing.phase; fishingVisualStartedAt = time; updateAccessibility()
            }
        }
        if state.mode == .woodfish {
            if time - woodHitAt < 0.5 || !floatingStrikes.isEmpty { setNeedsDisplay(woodDrawingRect) }
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
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(dirtyRect)
        switch state.mode {
        case .wipe: if let image = bitmap?.makeImage() { context.draw(image, in: bounds) }
        case .bubbles:
            for bubble in bubbles where bubble.rect.intersects(dirtyRect) { drawBubble(bubble, at: now, context: context) }
        case .woodfish: if woodDrawingRect.intersects(dirtyRect) { drawWoodfish(at: now, context: context) }
        case .fishing: if fishingRect.intersects(dirtyRect) { drawFishing(at: now, context: context) }
        }
        if state.mode == .wipe || state.mode == .bubbles { drawCounter() }
        if wasHeld, let point = hoverPoint {
            switch state.mode {
            case .wipe: InteractionArtwork.cloth(at: point, pressure: toolPressure, angle: toolTilt, context: context)
            case .bubbles:
                let age = now - toolReboundAt
                let rebound = reduceMotion || age > 0.24 ? 0 : CGFloat(exp(-age * 16) * sin(age * 32))
                InteractionArtwork.finger(at: point, pressure: toolPressure, rebound: rebound,
                                          flipped: point.y < 105, mirrored: point.x > bounds.width - 85, context: context)
            case .woodfish, .fishing: break
            }
        }
        if state.mode != .fishing && (wasHeld || now < hintUntil) { drawHint() }
    }
    private var counterRect: CGRect { CGRect(x: bounds.midX - 140, y: 2, width: 280, height: 37) }
    private func drawCounter() {
        let text = state.countLabel(for: state.mode) as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attributes)
        let pill = CGRect(x: bounds.midX - size.width / 2 - 12, y: 8, width: size.width + 24, height: 25)
        NSColor.playInk.withAlphaComponent(0.86).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 12, yRadius: 12).fill()
        text.draw(at: CGPoint(x: pill.minX + 12, y: pill.minY + 7), withAttributes: attributes)
    }
    private func drawHint() {
        let text = (now < hintUntil ? "AI 暂时忙完了" : state.mode.hint) as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attrs)
        let rect = CGRect(x: bounds.midX - size.width / 2 - 16, y: bounds.height - 56, width: size.width + 32, height: 32)
        NSColor.playInk.withAlphaComponent(0.86).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16).fill()
        text.draw(at: CGPoint(x: rect.minX + 16, y: rect.minY + 9), withAttributes: attrs)
    }
    func toolRect(at point: CGPoint) -> CGRect {
        let radius: CGFloat = state.mode == .bubbles ? 120 : 58
        return CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
    }
    private func updateToolPoint(_ point: CGPoint?) {
        if let old = hoverPoint { setNeedsDisplay(toolRect(at: old)) }
        hoverPoint = point
        if let point { setNeedsDisplay(toolRect(at: point)) }
    }
    private func updateToolAnimation(at time: TimeInterval) {
        let delta = min(0.05, max(0, time - lastToolTick))
        lastToolTick = time
        guard wasHeld, let point = hoverPoint, (state.mode == .wipe || state.mode == .bubbles) else { return }
        let beforePressure = toolPressure, beforeTilt = toolTilt
        let target: CGFloat = mouseIsDown ? 1 : 0
        if reduceMotion { toolPressure = target; toolTilt = -0.12 }
        else {
            toolPressure += (target - toolPressure) * CGFloat(1 - exp(-delta / 0.055))
            toolTilt += (targetToolTilt - toolTilt) * CGFloat(1 - exp(-delta / 0.07))
        }
        if abs(toolPressure - beforePressure) > 0.001 || abs(toolTilt - beforeTilt) > 0.001 || time - toolReboundAt < 0.25 {
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
    private func popBubble(_ index: Int) {
        guard bubbles.indices.contains(index), bubbles[index].poppedAt == nil else { return }
        bubbles[index].poppedAt = now
        if let point = hoverPoint, wasHeld,
           hypot(point.x - bubbles[index].point.x, point.y - bubbles[index].point.y) < bubbles[index].radius * 1.4 {
            toolReboundAt = now
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
        let dx = end.x - start.x, dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        var sequence = 0
        for index in bubbles.indices where bubbles[index].poppedAt == nil && bubbles[index].pressedAt == nil {
            let p = bubbles[index].point
            let t = lengthSquared > 0 ? min(1, max(0, ((p.x - start.x) * dx + (p.y - start.y) * dy) / lengthSquared)) : 0
            let contact = CGPoint(x: start.x + dx * t, y: start.y + dy * t)
            if hypot(contact.x - p.x, contact.y - p.y) < bubbles[index].radius {
                bubbles[index].pressedAt = now
                bubbles[index].contact = CGPoint(x: (contact.x - p.x) * 0.2, y: (contact.y - p.y) * 0.2)
                bubbles[index].deadline = now + (sweeping ? 0.055 + Double(sequence) * 0.01 : 0.12)
                sequence += 1
                setNeedsDisplay(bubbles[index].rect)
            }
        }
    }
    private func wipe(from start: CGPoint, to end: CGPoint, elapsed: TimeInterval) {
        let distance = hypot(end.x - start.x, end.y - start.y)
        guard distance > 0.5 else { return }
        let steps = min(600, max(1, Int(distance / 5)))
        var dirt = 0.0
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            dirt = max(dirt, dirtAlpha(near: point))
            erase(at: point)
        }
        if state.soundEnabled { PlayAudio.shared.wipe(speed: Double(distance) / max(0.008, elapsed), dirt: dirt) }
        if dirt > 0.01 { dirtBudget = max(0, dirtBudget - distance / 350) }
        for index in stains.indices {
            if stains[index].erase(from: start, to: end, radius: 22) { state.wipedStain() }
        }
        stains.removeAll { $0.completed }
        let rect = CGRect(x: min(start.x, end.x) - 33, y: min(start.y, end.y) - 33,
                          width: abs(end.x - start.x) + 66, height: abs(end.y - start.y) + 66)
        setNeedsDisplay(rect)
    }
    private func dirtAlpha(near point: CGPoint) -> Double {
        guard let bitmap, let data = bitmap.data else { return 0 }
        let scale = CGFloat(bitmap.width) / bounds.width
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var maximum: UInt8 = 0
        for dx: CGFloat in [-18, 0, 18] {
            for dy: CGFloat in [-18, 0, 18] {
                let x = min(bitmap.width - 1, max(0, Int((point.x + dx) * scale)))
                // Bitmap memory row 0 corresponds to the image's top row.
                let y = min(bitmap.height - 1, max(0, bitmap.height - 1 - Int((point.y + dy) * scale)))
                maximum = max(maximum, bytes[y * bitmap.bytesPerRow + x * 4 + 3])
            }
        }
        return Double(maximum) / 255
    }
    private func erase(at point: CGPoint) {
        guard let context = bitmap else { return }
        context.saveGState(); context.setBlendMode(.destinationOut)
        let colors = [NSColor.white.cgColor, NSColor.white.cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.72, 1]) {
            context.drawRadialGradient(gradient, startCenter: point, startRadius: 0, endCenter: point, endRadius: 29, options: [])
        }
        context.restoreGState()
    }
    private func strikeWood() {
        state.strike()
        woodHitAt = now
        floatingStrikes.append(FloatingStrike(time: now, offset: CGFloat.random(in: -17...17)))
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
        toolPressure = 0.25
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
            if hypot(dx, dy) > 1 { targetToolTilt = -0.12 + atan2(dy, abs(dx) + 8) * 0.20 }
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
        if state.mode == .bubbles {
            for index in bubbles.indices where bubbles[index].pressedAt != nil && bubbles[index].poppedAt == nil { popBubble(index) }
        }
        PlayAudio.shared.endWipe()
        previousPoint = nil; mouseIsDown = false; strikeGate.release()
        targetToolTilt = -0.12
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
