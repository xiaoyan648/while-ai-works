import AppKit
import WhileCore

/// Deterministic mouse-event regression checks. Never posts events to the OS or uses real saves.
@main enum NativeMotionChecks {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { fputs("NativeMotionChecks failed: \(message)\n",stderr); exit(1) }
    }
    static func main() throws {
        _ = NSApplication.shared
        let suite = "WhileAIWorks.MotionChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(defaults: defaults)
        state.soundEnabled = false; state.followAI = false; state.area = .fullScreen
        var time: TimeInterval = 10
        var reduced = false
        let view = PlayView(state: state, clock: { time }, reduceMotion: { reduced })
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 480)
        view.layout(); view.sync(); view.setInteractionEnabled(true)
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: x,y: y), modifierFlags: [], timestamp: time,
                               windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        func advance(_ delta: Double) {
            let end = time+delta
            while time < end { time = min(end,time+1.0/60); view.advanceInteractionAnimation(at: time) }
        }
        func bubbles() {
            // Deliberately store right, left, middle to expose accidental array-order processing.
            view.bubbles = [320,120,220].map { PlayView.Bubble(point: CGPoint(x: $0,y: 220), radius: 27, seed: 3, appearedAt: 0) }
        }
        state.mode = .bubbles; view.sync(); bubbles()
        view.setInteractionEnabled(false)
        let raster = CGContext(data: nil,width: 800,height: 480,bitsPerComponent: 8,bytesPerRow: 3200,
                               space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext:raster,flipped:false)
        view.draw(view.bounds)
        let cleanPixels = Data(bytes:raster.data!,count:3200*480)
        for _ in 0..<20 { view.draw(CGRect(x:100,y:202,width:20,height:25)) }
        let repeatedPixels = Data(bytes:raster.data!,count:3200*480)
        NSGraphicsContext.restoreGraphicsState()
        let changedOutside = zip(cleanPixels,repeatedPixels).enumerated().contains { byte in
            let pixel = byte.offset/4, x = pixel%800, y = 479-pixel/800
            return (x < 100 || x >= 120 || y < 202 || y >= 227) && byte.element.0 != byte.element.1
        }
        expect(!changedOutside, "partial redraws must not accumulate translucent rims outside the cleared rectangle")
        expect(cleanPixels == repeatedPixels, "cached resting bubbles remain identical after repeated partial redraws")
        view.setInteractionEnabled(true)
        view.mouseDown(with: event(.leftMouseDown, 65, 220))
        view.mouseDragged(with: event(.leftMouseDragged, 375, 220))
        let left = view.bubbles[1].deadline!, middle = view.bubbles[2].deadline!, right = view.bubbles[0].deadline!
        expect(left < middle && middle < right, "left swipe follows path order regardless of array storage")
        view.mouseUp(with: event(.leftMouseUp, 375, 220))
        expect(state.totalBubbles == 0, "quick release retains the compression frames")
        time = left; view.advanceInteractionAnimation(at: time)
        expect(state.totalBubbles == 1 && view.bubbles[1].poppedAt != nil, "first crossed bubble ruptures first")
        time = middle; view.advanceInteractionAnimation(at: time)
        expect(state.totalBubbles == 2 && view.bubbles[2].poppedAt != nil, "middle bubble ruptures second")
        time = right; view.advanceInteractionAnimation(at: time)
        expect(state.totalBubbles == 3, "each traversal hit emits exactly one event")
        advance(1)
        expect(state.totalBubbles == 3, "animation settling cannot emit a second rupture")
        bubbles()
        view.mouseDown(with: event(.leftMouseDown, 375, 220))
        view.mouseDragged(with: event(.leftMouseDragged, 65, 220))
        expect(view.bubbles[0].deadline! < view.bubbles[2].deadline! && view.bubbles[2].deadline! < view.bubbles[1].deadline!, "reverse swipe reverses the rupture order")
        view.cancelInteraction(); advance(1)
        expect(state.totalBubbles == 3 && view.bubbles.allSatisfy { $0.poppedAt == nil && $0.pressedAt == nil }, "leaving or switching cancels all pending ruptures")
        view.mouseDown(with: event(.leftMouseDown, 129, 226))
        expect(view.bubbles[1].contact == CGPoint(x: 9,y: 6), "local dent follows the actual off-centre contact")
        let locked = view.handOrientation.angle
        view.mouseDragged(with: event(.leftMouseDragged, 775, 40)); advance(0.12)
        expect(view.handOrientation.angle == locked, "orientation stays locked during a press across both edges")
        view.mouseUp(with: event(.leftMouseUp, 775, 40)); advance(1.0/60)
        expect(abs(view.handOrientation.angle-locked) < 0.8 && view.handOrientation.angle != locked, "released hand turns gradually about its fixed fingertip")
        var orientation = HandOrientation()
        orientation.update(point: CGPoint(x: 300,y: 85), bounds: view.bounds, pressed: false, delta: 1, reduceMotion: false)
        let bottomTarget = orientation.target
        orientation.update(point: CGPoint(x: 300,y: 110), bounds: view.bounds, pressed: false, delta: 0.01, reduceMotion: false)
        expect(orientation.target == bottomTarget, "hysteresis prevents orientation chatter near the lower edge")
        view.cancelInteraction()

        for duration in [0.005, 0.03, 0.095] {
            let before = BubblePose(pressedAt: 0, poppedAt: nil, popPressure: 0, at: duration, reduceMotion: false)
            let contact = BubblePose(pressedAt: 0, poppedAt: duration, popPressure: before.pressure, at: duration, reduceMotion: false)
            expect(before.pressure == contact.pressure && contact.collapse == 0, "rupture starts from the current pressed shape, including fast taps")
        }
        let staticPress = BubblePose(pressedAt: 0, poppedAt: nil, popPressure: 0, at: 0, reduceMotion: true)
        let staticPop = BubblePose(pressedAt: 0, poppedAt: 0, popPressure: 0, at: 0, reduceMotion: true)
        expect(staticPress.pressure == 1 && staticPop.collapse == 1 && staticPop.settle == 0, "Reduce Motion preserves informative static press and rupture states")
        let settledA = BubblePose(pressedAt: 0, poppedAt: 0.1, popPressure: 1, at: 1, reduceMotion: false)
        let settledB = BubblePose(pressedAt: 0, poppedAt: 0.1, popPressure: 1, at: 2, reduceMotion: false)
        expect(settledA.collapse == settledB.collapse && settledA.settle == 0 && settledB.settle == 0, "a settled membrane is still")

        state.mode = .wipe; view.sync()
        let start = CGPoint(x: 110,y: 160), end = CGPoint(x: 640,y: 260)
        let patch = ClothContact.sweep(from: start, to: end)
        let reverse = ClothContact.sweep(from: end, to: start)
        for fraction in [0.0,0.25,0.5,0.75,1.0] {
            let point = CGPoint(x: start.x+(end.x-start.x)*fraction, y: start.y+(end.y-start.y)*fraction)
            for y in stride(from: -20, through: 20, by: 5) {
                let contact = CGPoint(x: point.x,y: point.y+CGFloat(y))
                expect(patch.contains(contact) && reverse.contains(contact), "fast diagonal wipes have no holes and work in both directions")
            }
        }
        expect(!patch.contains(CGPoint(x: 375,y: 255)), "outside the visible contact surface remains untouched")
        let bitmap = view.bitmap!
        bitmap.setFillColor(NSColor.brown.cgColor); bitmap.fill(view.bounds)
        view.stains = [StainProgress(center: CGPoint(x: 375,y: 210),radius: 21)]
        view.mouseDown(with: event(.leftMouseDown, start.x,start.y))
        advance(0.016)
        view.mouseDragged(with: event(.leftMouseDragged, end.x,end.y))
        expect(view.hoverPoint == end && state.totalWipes == 1, "cursor contact follows immediately and the same footprint completes the stain")
        advance(0.016)
        expect(view.clothDrag.x < 0 && view.clothDrag.y < 0, "only cloth edges trail the stroke")
        view.mouseUp(with: event(.leftMouseUp, end.x,end.y)); advance(0.5)
        expect(hypot(view.clothDrag.x,view.clothDrag.y) < 0.1, "cloth drag settles on release")
        let bytes = bitmap.data!.assumingMemoryBound(to: UInt8.self)
        let scale = CGFloat(bitmap.width)/view.bounds.width
        func alpha(_ p: CGPoint) -> UInt8 {
            bytes[(bitmap.height-1-Int(p.y*scale))*bitmap.bytesPerRow+Int(p.x*scale)*4+3]
        }
        expect(alpha(CGPoint(x: 375,y: 210)) == 0 && alpha(CGPoint(x: 375,y: 255)) == 255,
               "rendered erasure agrees with coverage at the centre and beyond the edge")

        // Consecutive short drags used to go silent: all nine centre samples
        // were inside the previous erasure, despite fresh ink at the leading edge.
        bitmap.clear(view.bounds)
        bitmap.setFillColor(NSColor(calibratedWhite: 0.3, alpha: 0.23).cgColor)
        bitmap.fill(CGRect(x: 70, y: 100, width: 300, height: 100))
        view.mouseDown(with: event(.leftMouseDown, 110, 160))
        advance(0.016)
        view.mouseDragged(with: event(.leftMouseDragged, 112, 160))
        for x in stride(from: CGFloat(114), through: 140, by: 2) {
            let next = ClothContact.sweep(from: CGPoint(x: x-2,y: 160), to: CGPoint(x: x,y: 160))
            expect(view.dirtAlpha(in: next) > 0.15, "fresh ink under the leading cloth edge remains audible on small consecutive drags")
            advance(0.016)
            view.mouseDragged(with: event(.leftMouseDragged, x, 160))
        }
        view.mouseUp(with: event(.leftMouseUp, 140, 160))
        expect(view.dirtAlpha(in: CGPath(rect: CGRect(x: 95,y: 145,width: 45,height: 25), transform: nil)) == 0,
               "fully erased contact area stays silent even with dirt nearby")
        bitmap.clear(view.bounds)
        bitmap.fill(CGRect(x: 200, y: 300, width: 10, height: 10))
        expect(view.dirtAlpha(in: ClothContact.sweep(from: CGPoint(x: 195,y: 170), to: CGPoint(x: 210,y: 170))) == 0,
               "vertically mirrored dirt must not trigger wiping sound")

        state.mode = .woodfish; view.sync()
        let wood = view.woodCenter
        let idle = view.malletAngle(at: time)
        view.mouseDown(with: event(.leftMouseDown, wood.x,wood.y)); advance(0.02)
        expect(view.malletAngle(at: time) > idle && state.totalStrikes == 0, "mallet responds before contact without early count or sound")
        advance(0.016)
        expect(state.totalStrikes == 1 && view.woodHitAt == time && abs(view.malletAngle(at: time)+0.065) < 0.001, "count and body impulse share the contact frame")
        view.mouseUp(with: event(.leftMouseUp,wood.x,wood.y))
        let priorAngle = view.malletAngle(at: time)
        view.mouseDown(with: event(.leftMouseDown,wood.x,wood.y))
        expect(abs(view.malletAngle(at: time)-priorAngle) < 0.001, "rapid retrigger continues from the current mallet pose")
        view.mouseUp(with: event(.leftMouseUp,wood.x,wood.y)); advance(0.04)
        expect(state.totalStrikes == 2 && view.floatingStrikes.last?.delta == 2, "rapid taps count separately but merge the visual +2")
        advance(0.4)
        expect(abs(view.malletAngle(at: time)-idle) < 0.001, "mallet settles fully at rest")
        reduced = true
        view.mouseDown(with: event(.leftMouseDown,wood.x,wood.y))
        expect(state.totalStrikes == 3 && view.malletAngle(at: time) == idle, "reduced motion strikes immediately without swinging")
        view.mouseUp(with: event(.leftMouseUp,wood.x,wood.y))
        state.mode = .wipe; view.sync()
        view.mouseDown(with: event(.leftMouseDown,200,180)); view.mouseDragged(with: event(.leftMouseDragged,300,180)); advance(0.016)
        expect(view.toolPressure == 1 && view.clothDrag == .zero, "reduced motion keeps contact feedback but removes trailing corners")
        view.cancelInteraction(); state.desktopEnabled = false
        let fishingWindow = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        fishingWindow.isReleasedWhenClosed = false
        fishingWindow.contentView = view
        fishingWindow.orderFrontRegardless()
        defer { fishingWindow.orderOut(nil) }
        state.desktopEnabled = true; state.mode = .fishing; view.sync()
        state.fishingPress()
        for _ in 0..<120 {
            state.advanceFishing(delta: 1.0 / 30, random: { 0 })
            if state.fishing.phase == .bite { break }
        }
        state.fishingPress()
        expect(state.fishing.phase == .fighting, "frame pacing fixture reaches an actual fight")
        view.advanceFishingAnimation(at: time)
        for reducedMotion in [false, true] {
            reduced = reducedMotion
            for delta in [0.0164, 0.0169, 0.0165, 1.0 / 120] {
                let previousElapsed = state.fishing.elapsed
                view.needsDisplay = false
                time += delta; view.advanceFishingAnimation(at: time)
                expect(abs(state.fishing.elapsed - previousElapsed - delta) < 0.00001,
                       "gameplay advances on every display callback, including sub-1/60 jitter")
                expect(view.needsDisplay, "active fishing redraws every frame even with Reduce Motion")
            }
        }
        let heldBar = state.fishing.bar
        state.fishingRelease()
        for _ in 0..<45 { time += 1.0 / 60; view.advanceFishingAnimation(at: time) }
        expect(state.fishing.bar < heldBar, "release is consumed by the same animation clock and the bar falls")
        let elapsedBeforePause = state.fishing.elapsed
        time += 10; view.advanceFishingAnimation(at: time)
        expect(state.fishing.elapsed == elapsedBeforePause, "resuming after suspension cannot jump or lose a fish")
        state.desktopEnabled = false
        let paw = InteractionArtwork.pawPrintPath(center: CGPoint(x: 150, y: 150), radius: 40, angle: 0.3)
        var pawStain = StainProgress(center: CGPoint(x: 150, y: 150), radius: 40, coverage: { paw.contains($0) })
        expect(!pawStain.erase(where: { !paw.contains($0) }), "empty gaps around a paw print never count")
        expect(pawStain.erase(where: { paw.contains($0) }), "erasing only visible paw ink completes it")
        expect(!pawStain.erase(where: { _ in true }), "paw print is counted exactly once")
        print("NativeMotionChecks: \(checks) checks passed (sweep order, contact geometry, fast taps, pose continuity, cancellation, mallet timing, Reduce Motion).")
    }
}
