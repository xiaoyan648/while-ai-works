import AppKit
import ImageIO
import WhileCore

enum InteractionFailure: Error { case failed(String) }
func verify(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw InteractionFailure.failed(message) }
}

/// Offscreen view tests: events go directly to the test object, never to the OS queue.
@main enum NativeInteractionChecks {
    static func main() throws {
        let suite = "WhileAIWorks.NativeChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let rodSuite = suite + ".rods"
        let rodDefaults = UserDefaults(suiteName: rodSuite)!
        defer { rodDefaults.removePersistentDomain(forName: rodSuite) }
        var rodBook = FishingBook()
        for species in CatchSpecies.catalog.filter(\.isFish).prefix(10) { rodBook.record(.init(species: species, sizeCM: species.maxCM)) }
        for _ in 10..<100 { rodBook.record(.init(species: CatchSpecies.catalog[0], sizeCM: 10)) }
        rodBook.save(defaults: rodDefaults)
        let rodState = AppState(defaults: rodDefaults)
        rodState.soundEnabled = false
        try verify(rodState.fishing.rod == .ocean && rodState.fishingReward == nil, "legacy equipment migrates without reward spam")
        rodState.equipRod(.rain)
        try verify(rodState.fishing.rod == .rain && AppState(defaults: rodDefaults).fishing.rod == .rain, "UI equipment choice reaches game and survives restart")
        rodState.mode = .fishing; rodState.desktopEnabled = true; rodState.followAI = false
        rodState.fishingPress()
        rodState.equipRod(.ocean)
        try verify(rodState.fishing.rod == .rain && !rodState.canEquipRod, "UI cannot swap equipment during an active cast")
        rodState.mode = .woodfish; rodState.mode = .fishing
        try verify(rodState.fishing.rod == .rain && rodState.canEquipRod, "mode switches preserve equipment and release cast lock")
        rodState.desktopEnabled = false
        try verify(rodState.fishing.rod == .rain, "desktop toggle preserves equipment")
        let unlockSuite = suite + ".unlock"
        let unlockDefaults = UserDefaults(suiteName: unlockSuite)!
        defer { unlockDefaults.removePersistentDomain(forName: unlockSuite) }
        var unlockBook = FishingBook()
        for _ in 0..<9 { unlockBook.record(.init(species: CatchSpecies.catalog[0], sizeCM: 8)) }
        unlockBook.save(defaults: unlockDefaults)
        let unlockState = AppState(defaults: unlockDefaults)
        unlockState.soundEnabled = false; unlockState.mode = .fishing
        unlockState.desktopEnabled = true; unlockState.followAI = false
        unlockState.fishingPress()
        var unlockRolls = [0.0, 0.0, 0.9999]
        for _ in 0..<21 {
            unlockState.advanceFishing(delta: 0.1, random: { unlockRolls.isEmpty ? 0.5 : unlockRolls.removeFirst() })
            if unlockState.fishing.phase == .bite { break }
        }
        unlockState.fishingPress(); unlockState.fishingRelease()
        var unlockPreviousBar = unlockState.fishing.bar
        for _ in 0..<1950 {
            let velocity = (unlockState.fishing.bar - unlockPreviousBar) * 30
            unlockPreviousBar = unlockState.fishing.bar
            if unlockState.fishing.bar + velocity * 0.24 < unlockState.fishing.fish {
                if !unlockState.fishing.pressed { unlockState.fishingPress() }
            } else { unlockState.fishingRelease() }
            unlockState.advanceFishing(delta: 1.0 / 30, random: { 0.5 })
            if unlockState.fishing.phase == .landed || unlockState.fishing.phase == .escaped { break }
        }
        try verify(unlockState.fishing.phase == .landed && unlockState.fishingBook.total == 10, "a real catch transition crosses the ten-catch unlock boundary")
        try verify(unlockState.fishingReward?.catchResult.medal == .gold, "catch reward uses the current catch size for its medal")
        try verify(unlockState.fishingReward?.unlockNotices == ["钓竿解锁 · 听雨竿", "成就达成 · 河畔新手", "成就达成 · 第一尾金牌"], "same catch presents new equipment and all new achievements exactly once")
        try verify(unlockState.fishing.rod == .bamboo, "unlock never silently replaces the equipped rod")
        let reopenedUnlock = AppState(defaults: unlockDefaults)
        try verify(reopenedUnlock.fishingReward == nil && reopenedUnlock.fishingProgression.earned.contains(FishingAchievement.firstGold.id), "achievements persist without replaying notifications on launch")
        let unlockView = PlayView(state: unlockState)
        unlockView.frame = CGRect(x: 0, y: 0, width: 700, height: 500)
        unlockView.layout(); unlockView.sync()
        let unlockCapture = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1400, pixelsHigh: 1000, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: unlockCapture)
        NSGraphicsContext.current!.cgContext.scaleBy(x: 2, y: 2)
        unlockView.drawFishing(at: unlockState.fishingReward!.caughtAt + 0.5, context: NSGraphicsContext.current!.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        try unlockCapture.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/fishing-unlock.png"))
        unlockState.desktopEnabled = false
        let state = AppState(defaults: defaults)
        state.soundEnabled = false
        try verify(!state.interactionEnabled, "launch must leave ordinary desktop input available")
        state.desktopEnabled = false
        state.interactionEnabled = true
        try verify(state.desktopEnabled && state.interactionHeld, "interaction toggle enables the surface without a held modifier")
        state.interactionEnabled = false
        try verify(state.desktopEnabled && !state.interactionHeld, "turning input off keeps the artwork visible")
        state.interactionEnabled = true
        state.desktopEnabled = false
        try verify(!state.interactionEnabled && !state.interactionHeld, "hiding the surface disables interaction")
        state.shortcutKey = 40; state.shortcutModifiers = 1
        try verify(defaults.integer(forKey: "interaction.shortcutKey") == 40 && defaults.integer(forKey: "interaction.shortcutModifiers") == 1,
                   "custom shortcut persists independently of counters")
        state.area = .fullScreen
        let view = PlayView(state: state)
        view.frame = CGRect(x: 0, y: 0, width: 700, height: 500)
        view.layout()
        view.sync()
        view.setInteractionEnabled(true)
        let bitmap = view.bitmap!
        bitmap.clear(view.bounds)
        bitmap.setFillColor(NSColor.brown.cgColor)
        bitmap.fill(CGRect(x: 90, y: 90, width: 180, height: 70))
        view.stains = [StainProgress(center: CGPoint(x: 170, y: 120), radius: 20)]
        func alpha(_ x: Int, _ y: Int) -> UInt8 {
            let scale = bitmap.width / 700
            let bytes = bitmap.data!.assumingMemoryBound(to: UInt8.self)
            return bytes[(bitmap.height - 1 - y * scale) * bitmap.bytesPerRow + x * scale * 4 + 3]
        }
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, _ time: Double) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [.option], timestamp: time,
                               windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: event(.leftMouseDown, 110, 120, 1))
        try verify(alpha(110, 120) == 255, "a stationary click must not erase dirt")
        view.mouseDragged(with: event(.leftMouseDragged, 240, 120, 1.2))
        try verify(alpha(170, 120) < 10, "dragging must erase the stroke center")
        try verify(alpha(170, 158) > 220, "dirt outside the brush must remain")
        view.mouseUp(with: event(.leftMouseUp, 240, 120, 1.3))
        try verify(state.totalWipes == 1, "cleaning one stain increments its own counter")
        view.mouseDown(with: event(.leftMouseDown, 110, 120, 1.4))
        view.mouseDragged(with: event(.leftMouseDragged, 240, 120, 1.5))
        view.mouseUp(with: event(.leftMouseUp, 240, 120, 1.6))
        try verify(state.totalWipes == 1, "repeating the cleaned stroke does not increment again")

        state.mode = .bubbles
        view.sync()
        let fullCount = view.bubbles.count
        try verify(fullCount > 30, "full-screen bubbles should occupy the interior")
        state.area = .edges
        view.sync()
        try verify(view.bubbles.count < fullCount, "edge mode must have fewer bubbles")
        try verify(view.bubbles.allSatisfy { $0.point.x < 80 || $0.point.x > 620 || $0.point.y < 80 || $0.point.y > 420 },
                   "edge bubbles must leave the central workspace clear")
        let point = view.bubbles[0].point
        view.mouseDown(with: event(.leftMouseDown, point.x, point.y, 2))
        try verify(view.bubbles[0].pressedAt != nil && view.bubbles[0].poppedAt == nil, "bubble must depress before rupturing")
        view.mouseUp(with: event(.leftMouseUp, point.x, point.y, 2.05))
        try verify(view.bubbles[0].poppedAt != nil, "releasing the pressed bubble must rupture it")
        let popped = view.bubbles[0].poppedAt
        view.mouseDown(with: event(.leftMouseDown, point.x, point.y, 2.1))
        view.mouseUp(with: event(.leftMouseUp, point.x, point.y, 2.2))
        try verify(view.bubbles[0].poppedAt == popped, "an already ruptured bubble must not pop again")
        try verify(state.totalBubbles == 1 && state.totalWipes == 1, "bubble count increments only once and stays independent")

        state.mode = .woodfish
        view.sync()
        let wood = view.woodCenter
        view.mouseDown(with: event(.leftMouseDown, wood.x, wood.y, 3))
        view.mouseDragged(with: event(.leftMouseDragged, wood.x + 2, wood.y + 2, 3.1))
        view.mouseDragged(with: event(.leftMouseDragged, wood.x + 3, wood.y + 3, 3.2))
        view.mouseUp(with: event(.leftMouseUp, wood.x, wood.y, 3.3))
        try verify(state.totalStrikes == 1 && state.sessionStrikes == 1, "dragging while held must not multiply woodfish strikes")
        view.mouseDown(with: event(.leftMouseDown, wood.x, wood.y, 4))
        view.mouseUp(with: event(.leftMouseUp, wood.x, wood.y, 4.1))
        state.reset(); view.sync()
        try verify(state.totalStrikes == 2, "resetting the play surface must preserve the total count")
        view.setInteractionEnabled(false)
        view.mouseDown(with: event(.leftMouseDown, wood.x, wood.y, 5))
        try verify(state.totalStrikes == 2, "ordinary desktop clicks must pass through without counting")
        state.area = .fullScreen; view.sync()
        try verify(view.woodCenter.x == view.bounds.midX, "full-screen scope should move the woodfish to the center")
        state.desktopEnabled = true
        state.followAI = true; state.selectedSources = [.codex]
        for _ in 0..<5 { state.advanceWorkEffects(delta: 1) }
        try verify(state.woodBalance == 2, "idle Codex must not deduct woodfish balance")
        state.detectedWorking = true
        for _ in 0..<5 { state.advanceWorkEffects(delta: 1) }
        try verify(state.woodBalance == 1 && state.totalStrikes == 2, "AI work deducts balance without erasing earned lifetime strikes")
        state.mode = .bubbles
        for _ in 0..<5 { state.advanceWorkEffects(delta: 1) }
        try verify(state.woodBalance == 1, "other games must not silently deduct woodfish balance")
        state.mode = .woodfish
        state.desktopEnabled = false
        for _ in 0..<5 { state.advanceWorkEffects(delta: 1) }
        try verify(state.woodBalance == 1, "disabled desktop must stop work decay")
        state.desktopEnabled = true
        for _ in 0..<15 { state.advanceWorkEffects(delta: 1) }
        try verify(state.woodBalance == -2, "work decay continues below zero")
        state.strike()
        try verify(state.woodBalance == -1 && state.totalStrikes == 3, "a real strike restores one point and increments its own lifetime count")
        let restored = AppState(defaults: defaults)
        try verify(restored.woodBalance == -1 && restored.totalStrikes == 3 && restored.totalWipes == 1 && restored.totalBubbles == 1,
                   "all three counters and signed balance survive reopening")
        try verify(restored.sessionStrikes == 0 && restored.sessionWipes == 0 && restored.sessionBubbles == 0, "all session counters restart independently")
        func renderRiver(_ name: String, at time: TimeInterval) throws {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1400, pixelsHigh: 1000,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            let c = NSGraphicsContext.current!.cgContext
            c.scaleBy(x: 2, y: 2)
            view.fishingVisualStartedAt = name == "landed-start" ? time : time - 1
            view.drawFishing(at: time, context: c)
            NSGraphicsContext.restoreGraphicsState()
            // Sky above the highest rod/float must remain fully transparent in every phase.
            for x in stride(from: 20, to: 1380, by: 40) {
                try verify(rep.colorAt(x: x, y: 120)!.alphaComponent < 0.01, "river must not draw a background panel across desktop sky")
            }
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/river-\(name).png"))
        }
        state.mode = .fishing
        state.area = .edges
        state.desktopEnabled = true
        state.interactionHeld = true
        state.detectedWorking = true
        view.sync(); view.setInteractionEnabled(true)
        try renderRiver("ready", at: 20)
        let pond = view.fishingRect
        try verify(pond.maxX == view.bounds.maxX && pond.minY == 0 && view.bounds.contains(pond), "edge river anchors to the usable desktop bottom")
        view.mouseDown(with: event(.leftMouseDown, 5, 5, 6))
        view.mouseUp(with: event(.leftMouseUp, 5, 5, 6.1))
        try verify(state.fishing.phase == .ready, "outside the pond does not cast")
        view.mouseDown(with: event(.leftMouseDown, pond.midX, 120, 6.2))
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 6.3,
                                      windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                      isARepeat: false, keyCode: 53)!
        let modifiedEscape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 6.3,
                                              windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                              isARepeat: false, keyCode: 53)!
        try verify(!InteractionShortcut.handleEscape(modifiedEscape, state: state) && state.castStartedAt != nil,
                   "modified Escape remains available to the foreground app")
        try verify(InteractionShortcut.handleEscape(escape, state: state), "plain Escape cancels an active charge")
        view.mouseDragged(with: event(.leftMouseDragged, pond.midX + 20, 140, 6.6))
        view.mouseUp(with: event(.leftMouseUp, pond.midX + 20, 140, 6.8))
        try verify(state.fishing.phase == .ready && state.castStartedAt == nil && state.fishingBook.total == 0,
                   "cancelled charge cannot cast on a later drag or release")
        try verify(!InteractionShortcut.handleEscape(escape, state: state), "Escape is not consumed outside an active charge")
        view.mouseDown(with: event(.leftMouseDown, pond.midX, 80, 7))
        try verify(state.castStartedAt != nil && state.fishing.phase == .ready, "mouse down charges without casting")
        try verify(state.castPower(at: 8.2) > 0.99 && state.castPower(at: 9.4) < 0.01, "charge rises and falls within bounds")
        let restedTip = view.fishingRodTip(at: 7), chargedTip = view.fishingRodTip(at: 8.2)
        try verify(chargedTip.x > restedTip.x && chargedTip.y < restedTip.y, "charge bends the rod tip back")
        view.mouseDragged(with: event(.leftMouseDragged, pond.minX + pond.width * 0.60, 150, 7.5))
        let shortCast = view.castTarget(at: 7.1)
        let longCast = view.castTarget(at: 8.2)
        try verify(longCast.y > shortCast.y && longCast.x < shortCast.x, "charge controls distance and drag controls direction")
        try verify(view.castWater(at: CGPoint(x: pond.width * 0.9, y: 238)) == .reeds && view.castWater(at: CGPoint(x: pond.width * 0.7, y: 150)) == .deep, "visible water features match habitat selection")
        try renderRiver("charging", at: 7.8)
        let releaseTip = view.fishingRodTip(at: 7.9)
        view.mouseUp(with: event(.leftMouseUp, pond.midX, 80, 7.9))
        let launchBob = view.fishingBobber(at: 7.9)
        if !view.reduceMotion {
            try verify(hypot(launchBob.x - releaseTip.x, launchBob.y - releaseTip.y) < 0.001,
                       "float starts at the actual charged rod tip without a jump")
            let midpoint = view.fishingBobber(at: 8.175)
            let end = view.fishingBobber(at: 8.45)
            try verify(midpoint.y > (launchBob.y + end.y) / 2 + 50, "cast follows a visible lifted arc")
        }
        try renderRiver("cast-flight", at: 8.175)
        try verify(state.castStartedAt == nil && state.fishing.water != nil, "release commits the landing habitat")
        try verify(state.fishing.phase == .waiting, "native pond click casts")
        try renderRiver("waiting", at: 22)
        for _ in 0..<21 { state.advanceFishing(delta: 0.1, random: { 0 }) }
        try verify(state.fishing.phase == .bite, "shared fishing clock receives a bite")
        try verify(view.fishingBobber(at: 22).y < state.castLanding.y * 195 - 4, "bite clearly pulls the bobber underwater")
        try renderRiver("bite", at: 22)
        view.mouseDown(with: event(.leftMouseDown, pond.midX, 80, 8))
        view.mouseUp(with: event(.leftMouseUp, pond.midX, 80, 8.1))
        try verify(state.fishing.phase == .fighting, "native click hooks the fish")
        try verify(view.fishingContains(CGPoint(x: view.fishingTrack.midX, y: view.fishingTrack.maxY)), "active float accepts input above the water")
        try renderRiver("fighting", at: 24)
        var previousBar = state.fishing.bar
        for _ in 0..<1000 {
            let velocity = (state.fishing.bar - previousBar) * 30
            previousBar = state.fishing.bar
            if state.fishing.bar + velocity * 0.24 < state.fishing.fish {
                if !state.fishing.pressed { state.fishingPress() }
            } else { state.fishingRelease() }
            state.advanceFishing(delta: 1.0 / 30, random: { 0.5 })
            if state.fishing.phase == .landed || state.fishing.phase == .escaped { break }
        }
        try verify(state.fishing.phase == .landed && state.fishingBook.total == 1, "landed fish records one catch in AppState")
        let reward = state.fishingReward!
        try verify(!reward.canDismiss(at: reward.caughtAt + 0.999) && reward.canDismiss(at: reward.caughtAt + 1),
                   "catch protection lasts exactly one second")
        for offset in [0.1, 0.2] {
            view.mouseDown(with: event(.leftMouseDown, pond.minX + pond.width*0.7, 135, reward.caughtAt + offset))
            view.mouseUp(with: event(.leftMouseUp, pond.minX + pond.width*0.7, 135, reward.caughtAt + offset + 0.04))
        }
        try verify(state.fishing.phase == .landed && state.fishingReward != nil && state.castStartedAt == nil,
                   "rapid double click during protection neither dismisses nor casts")
        // A protected press remains consumed even if its drag/release crosses the deadline.
        view.mouseDown(with: event(.leftMouseDown, pond.minX + pond.width*0.7, 135, reward.caughtAt + 0.8))
        view.mouseDragged(with: event(.leftMouseDragged, pond.minX + pond.width*0.7 + 20, 140, reward.caughtAt + 1.1))
        view.mouseUp(with: event(.leftMouseUp, pond.minX + pond.width*0.7 + 20, 140, reward.caughtAt + 1.2))
        try verify(state.fishing.phase == .landed && state.castStartedAt == nil && !state.fishing.pressed,
                   "holding through the deadline does not dismiss on release or start a cast")
        try verify(reward.firstDiscovery && reward.title == "新图鉴解锁！", "first catch celebrates discovery")
        try verify(reward.isVisible(at: reward.caughtAt + 3) && !reward.isVisible(at: reward.caughtAt + 3.81), "reward expires without clearing catch")
        let recordReward = AppState.FishingReward(catchResult: reward.catchResult, firstDiscovery: false, newRecord: true, caughtAt: 0)
        let repeatReward = AppState.FishingReward(catchResult: reward.catchResult, firstDiscovery: false, newRecord: false, caughtAt: 0)
        try verify(recordReward.title == "新纪录！" && repeatReward.title == "钓到了！", "record and repeat catches have distinct celebration text")
        let rewardPreview = CGContext(data: nil, width: 1400, height: 1000, bitsPerComponent: 8, bytesPerRow: 5600,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        rewardPreview.scaleBy(x: 2, y: 2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: rewardPreview, flipped: false)
        view.drawFishing(at: reward.caughtAt + 0.5, context: rewardPreview)
        NSGraphicsContext.restoreGraphicsState()
        let rewardURL = URL(fileURLWithPath: ".build/fishing-reward.png")
        let rewardOutput = CGImageDestinationCreateWithURL(rewardURL as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(rewardOutput, rewardPreview.makeImage()!, nil)
        try verify(CGImageDestinationFinalize(rewardOutput), "reward rendered through real desktop drawing")
        try renderRiver("landed-start", at: 30)
        try renderRiver("landed", at: 31)
        for _ in 0..<100 { state.advanceFishing(delta: 1.0 / 30) }
        try verify(state.fishingReward?.caughtAt == reward.caughtAt, "later ticks do not replay celebration")
        try verify(state.fishingBook.total == 1, "subsequent ticks do not double count")
        let restoredFishing = AppState(defaults: defaults)
        try verify(restoredFishing.fishingBook.total == 1 && restoredFishing.sessionCatches == 0, "fish guide persists and session restarts")
        try verify(state.totalStrikes == 3 && state.totalBubbles == 1 && state.totalWipes == 1, "fishing leaves the other three counters intact")
        view.mouseDown(with: event(.leftMouseDown, pond.minX + pond.width*0.7, 135, reward.caughtAt + 1.3))
        try verify(state.fishingReward == nil && state.fishing.phase == .ready && state.castStartedAt == nil,
                   "first click dismisses catch without charging")
        view.mouseDragged(with: event(.leftMouseDragged, pond.minX + pond.width*0.7 + 30, 140, reward.caughtAt + 1.4))
        view.mouseUp(with: event(.leftMouseUp, pond.minX + pond.width*0.7 + 30, 140, reward.caughtAt + 1.5))
        try verify(state.fishing.phase == .ready && state.castStartedAt == nil,
                   "dismiss gesture cannot cast even after dragging and releasing")
        try verify(state.fishingBook.total == 1, "dismissing preserves catch records")
        view.mouseDown(with: event(.leftMouseDown, pond.minX + pond.width*0.7, 135, reward.caughtAt + 1.7))
        try verify(state.castStartedAt != nil && state.fishing.phase == .ready, "second press starts charging")
        view.mouseUp(with: event(.leftMouseUp, pond.minX + pond.width*0.7, 135, reward.caughtAt + 2.4))
        try verify(state.fishing.phase == .waiting && state.castStartedAt == nil, "second release casts normally")
        state.reset(); view.sync()
        try verify(state.fishingReward == nil, "reset dismisses reward")
        try verify(state.fishing.phase == .ready && state.fishingBook.total == 1, "recasting preserves catalogue")
        state.area = .fullScreen; view.sync()
        try verify(view.fishingRect.maxX == view.bounds.maxX, "large corner stays anchored to the right")
        try verify(view.fishingRect.width <= 820 && view.fishingRect.minY == 0, "corner river stays bounded at the bottom")
        try verify(!view.fishingContains(CGPoint(x: view.bounds.midX, y: 280)), "transparent sky cannot accidentally cast")
        let preview = CGContext(data: nil, width: 1400, height: 1000, bitsPerComponent: 8, bytesPerRow: 5600,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        preview.scaleBy(x: 2, y: 2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: preview, flipped: false)
        state.fishingPress()
        for _ in 0..<21 { state.advanceFishing(delta: 0.1, random: { 0 }) }
        state.fishingPress()
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let output = URL(fileURLWithPath: ".build/fishing-desktop.png")
        let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, preview.makeImage()!, nil)
        try verify(CGImageDestinationFinalize(destination), "desktop fishing preview exports")
        state.desktopEnabled = false
        try verify(state.fishing.phase == .ready, "disabling desktop abandons live fishing without recording a catch")
        defaults.set("night",forKey:"fishing.timeMode")
        let restoredTime=AppState(defaults:defaults)
        try verify(restoredTime.fishingEnvironment.period == FishingEnvironment.resolve(mode:.system).period,"Legacy manual time cannot override the system clock")
        state.desktopEnabled=true;state.fishingPress()
        let castPeriod=state.fishing.period
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(secondsFromGMT:0)!
        state.refreshFishingEnvironment(date:Date(timeIntervalSince1970:12*3600),calendar:calendar)
        try verify(state.fishing.period == castPeriod,"Light changes cannot change a cast already in flight")
        state.reset();state.area = .edges
        try renderRiver("day",at:20)
        state.refreshFishingEnvironment(date:Date(timeIntervalSince1970:22*3600),calendar:calendar)
        try renderRiver("night",at:20)
        state.refreshFishingEnvironment(date:Date(timeIntervalSince1970:18*3600),calendar:calendar)
        try renderRiver("dusk",at:20)
        state.desktopEnabled = false
        print("NativeInteractionChecks: existing interaction checks and river geometry, transparency, phase rendering and fishing integration checks passed.")
    }
}
