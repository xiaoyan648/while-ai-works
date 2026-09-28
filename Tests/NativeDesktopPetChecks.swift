import AppKit
import SwiftUI

@main enum NativeDesktopPetChecks {
    static func main() {
        _ = NSApplication.shared
        let detailScroll = PetDetailScrollView()
        detailScroll.frame = CGRect(x: 0, y: 0, width: 240, height: 80)
        var moreBelow = false
        detailScroll.onOverflow = { moreBelow = $0 }
        detailScroll.setContent(AnyView(VStack { ForEach(0..<20) { Text("会话 \($0) 正在调用工具") } }))
        detailScroll.layoutSubtreeIfNeeded()
        precondition(!detailScroll.hasVerticalScroller && !detailScroll.hasHorizontalScroller)
        precondition(moreBelow, "overflow prompts a bottom fade")
        detailScroll.contentView.scroll(to: CGPoint(x: 0, y: detailScroll.documentView!.frame.height - 80))
        detailScroll.reflectScrolledClipView(detailScroll.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(!moreBelow, "bottom reached removes the fade")
        detailScroll.setContent(AnyView(Text("等待开始")))
        detailScroll.layoutSubtreeIfNeeded()
        precondition(!moreBelow && detailScroll.contentView.bounds.minY == 0, "short content clears fading and stale scroll offset")
        let suite = "WhileAIWorks.DesktopPetChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(defaults: defaults)
        state.soundEnabled = false
        precondition(state.desktopPetSize == .medium, "existing installs keep the original cat size")
        state.desktopPetSize = .large
        precondition(AppState(defaults: defaults).desktopPetSize == .large, "size persists across launch")
        defaults.set("unknown", forKey: "mascot.desktop.size")
        precondition(AppState(defaults: defaults).desktopPetSize == .medium, "invalid size falls back safely")
        state.desktopPetSize = .medium
        precondition(!state.desktopPetEnabled && !state.desktopPetShowsStatus && !state.desktopEnabled)
        state.desktopPetEnabled = true; state.desktopPetShowsStatus = true
        defaults.set(true, forKey: "mascot.desktop.status")
        state.desktopPetPosition = DesktopPetPosition(screenID: "external", x: 0.42, y: 0.73)
        let reopened = AppState(defaults: defaults)
        precondition(reopened.desktopPetEnabled && !reopened.desktopPetShowsStatus && !reopened.desktopEnabled)
        precondition(reopened.desktopPetPosition == state.desktopPetPosition)

        state.selectedSources = [.codex, .qoder]
        precondition(state.desktopPetStatus(for: .codex) == "正在读取")
        precondition(state.desktopPetStatus(for: .workbuddy) == "未关注")
        state.activeSessionCounts = [.codex: 2, .qoder: 0]; state.detectedWorking = true
        precondition(state.desktopPetMood == .watch && state.desktopPetHeadline == "Codex 在工作")
        state.activeSessionCounts[.qoder] = 1
        precondition(state.desktopPetHeadline == "2 个工具工作中")
        precondition(state.activeSessionCount == 3, "bubble counts sessions, not tools")
        state.activeSessionCounts = [.codex: 0, .qoder: 0]; state.detectedWorking = false
        state.workSourceDetails = [.codex: "读取失败", .qoder: "等待监听状态"]
        precondition(state.desktopPetStatus(for: .codex) == "状态不可用")
        precondition(state.desktopPetStatus(for: .qoder) == "等待连接")
        state.workSourceDetails = [:]
        precondition(state.desktopPetStatus(for: .qoder) == "未检测到工作")

        let size = DesktopPetView.size(showsStatus: true)
        for visible in [CGRect(x:0,y:25,width:1512,height:920), CGRect(x:-1920,y:-120,width:1920,height:1080), CGRect(x:40,y:80,width:340,height:410)] {
            let origin = DesktopPetPlacement.clamp(CGPoint(x:-9999,y:9999),size:size,to:visible)
            let frame = CGRect(origin:origin,size:size)
            precondition(visible.contains(frame), "clamp respects display origin and menu bar/Dock")
            let saved = DesktopPetPlacement.saved(frame:frame,visible:visible,screenID:"test")
            let restored = DesktopPetPlacement.origin(saved:saved,size:size,visible:visible)
            precondition(abs(restored.x-origin.x) < 0.001 && abs(restored.y-origin.y) < 0.001)
            let corrupt = DesktopPetPosition(screenID:"missing",x:Double.infinity,y:Double.nan)
            precondition(visible.contains(CGRect(origin:DesktopPetPlacement.origin(saved:corrupt,size:size,visible:visible),size:size)))
        }

        state.desktopPetShowsStatus = true
        let pet = DesktopPetController(state: state, mascot: MascotController(bundle: nil))
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        settle()
        precondition(pet.panel.isVisible && !pet.panel.canBecomeKey && !pet.panel.canBecomeMain)
        precondition(!state.desktopEnabled, "showing the cat never starts gameplay")
        precondition(pet.panel.frame.size == size)
        let rootView = pet.panel.contentView!
        precondition(rootView.hitTest(CGPoint(x: 168, y: 167)) != nil && rootView.hitTest(CGPoint(x: 168, y: 167)) !== rootView,
                     "bubble routes clicks to its button, never petting")
        precondition(rootView.hitTest(CGPoint(x: 70, y: 260)) != nil && rootView.hitTest(CGPoint(x: 70, y: 260)) !== rootView,
                     "detail routes clicks and scrolling to the SwiftUI card")
        precondition(rootView.hitTest(CGPoint(x: 90, y: 90)) === rootView, "cat keeps drag and pet interaction")
        let originalOrigin = pet.panel.frame.origin
        pet.dismissOutsideClick(at: pet.panel.convertPoint(toScreen: CGPoint(x: 90, y: 90)))
        precondition(state.desktopPetShowsStatus, "inside clicks preserve expanded detail")
        pet.dismissOutsideClick(at: CGPoint(x: pet.panel.frame.maxX + 50, y: pet.panel.frame.maxY + 50))
        precondition(!state.desktopPetShowsStatus, "outside clicks collapse")
        settle()
        precondition(pet.panel.frame.origin == originalOrigin, "expansion preserves the cat anchor away from display edges")
        state.desktopPetShowsStatus = false; settle()
        precondition(pet.panel.frame.size == DesktopPetView.size(showsStatus:false))
        for sizeChoice in DesktopPetSize.allCases {
            state.desktopPetSize = sizeChoice; settle()
            let compact = DesktopPetView.size(showsStatus: false, petSize: sizeChoice)
            precondition(pet.panel.frame.size == compact)
            let bounds = CGRect(origin: .zero, size: compact)
            precondition(bounds.contains(DesktopPetView.catFrame(sizeChoice)))
            precondition(bounds.contains(DesktopPetView.bubbleFrame(sizeChoice)))
            let point = CGPoint(x: DesktopPetView.catHitFrame(sizeChoice).midX, y: DesktopPetView.catHitFrame(sizeChoice).midY)
            precondition(pet.panel.contentView!.hitTest(point) === pet.panel.contentView!, "resized cat keeps its drag hit region")
            state.desktopPetShowsStatus = true; settle()
            precondition(pet.panel.frame.size == DesktopPetView.size(showsStatus: true, petSize: sizeChoice))
            precondition(pet.panel.contentView!.bounds.contains(DesktopPetView.cardFrame(sizeChoice)))
            state.desktopPetShowsStatus = false; settle()
        }
        state.desktopPetSize = .medium; settle()
        let reset = state.desktopPetResetID
        state.resetDesktopPetPosition(); settle()
        precondition(state.desktopPetPosition == nil && reset != state.desktopPetResetID)
        state.desktopPetEnabled = false; settle()
        precondition(!pet.panel.isVisible)
        state.desktopPetEnabled = true; settle()
        precondition(pet.panel.isVisible && !state.desktopEnabled)
        state.desktopPetEnabled = false; settle()
        withExtendedLifetime(pet) {}
        state.followAI = false; state.mode = .fishing; state.desktopEnabled = true
        state.fishingPress()
        for _ in 0..<21 { state.advanceFishing(delta: 0.1, random: { 0 }) }
        state.fishingPress(); state.fishingRelease()
        var previousBar = state.fishing.bar
        for _ in 0..<1950 {
            let velocity = (state.fishing.bar-previousBar)*30
            previousBar = state.fishing.bar
            if state.fishing.bar + velocity*0.24 < state.fishing.fish {
                if !state.fishing.pressed { state.fishingPress() }
            } else { state.fishingRelease() }
            state.advanceFishing(delta: 1.0/30, random: { 0.5 })
            if state.fishing.phase == .landed || state.fishing.phase == .escaped { break }
        }
        precondition(state.fishingReward != nil, "fixture lands a real catch")
        settle()
        precondition(!state.desktopPetEnabled && pet.panel.isVisible, "nonresident cat appears briefly for a real catch")
        precondition(state.companionMood(at: state.fishingReward!.caughtAt+0.4) == .proud)
        precondition(state.companionCatch(at: state.fishingReward!.caughtAt+3.0) != nil, "ordinary catch remains visible for the reward card duration")
        let showOrigin = pet.panel.frame.origin
        let savedPosition = state.desktopPetPosition
        state.desktopPetEnabled = true; settle()
        precondition(pet.panel.frame.origin == showOrigin, "resident cat also presents beside fishing on the target display")
        precondition(pet.panel.ignoresMouseEvents, "catch performance cannot intercept the next fishing gesture")
        precondition(state.desktopPetPosition == savedPosition, "temporary presentation never overwrites resident position")
        state.desktopPetEnabled = false; settle()
        RunLoop.main.run(until: Date().addingTimeInterval(3.9))
        precondition(!pet.panel.isVisible && !state.desktopPetEnabled, "transient catch hides without enabling resident pet")
        state.mode = .wipe; state.desktopEnabled = false
        print("NativeDesktopPetChecks: actual catch presents once with resident off, then hides; size setting and game storage remain independent")
        print("NativeDesktopPetChecks: default collapsed including legacy preference, session sum, outside dismiss, stable cat anchor, placement and visibility passed")
        if ProcessInfo.processInfo.arguments.contains("--no-capture") { return }
        // Exercise the actual Metal view, not a still: an offscreen SwiftUI render
        // cannot catch a live Rive canvas disappearing in a transparent panel.
        let bundle = Bundle(path: "dist/While AI Works.app")!
        let liveMascot = MascotController(bundle: bundle)
        precondition(liveMascot.isAvailable, "the built app must contain a loadable Rive cat")
        state.desktopPetShowsStatus = true
        state.activeSessionCounts = [.codex: 1]; state.detectedWorking = true
        state.desktopPetEnabled = true
        let live = DesktopPetController(state: state, mascot: liveMascot)
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        func capture() -> (NSBitmapImageRep, [UInt8]) {
            let image = (PetWindowCapture() as PetWindowImaging).image(of: CGWindowID(live.panel.windowNumber))!
            let bitmap = NSBitmapImageRep(cgImage: image)
            var opaque = 0, samples: [UInt8] = []
            for y in stride(from: 0, to: Int(Double(bitmap.pixelsHigh) * 0.6), by: 3) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                    let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                    if color.alphaComponent > 0.5 { opaque += 1 }
                    samples.append(contentsOf: [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
                        .map { UInt8(min(255, max(0, $0 * 255))) })
                }
            }
            precondition(opaque > 300, "live Rive must draw visible pixels above the status card")
            return (bitmap, samples)
        }
        let first = capture()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let second = capture()
        precondition(first.1 != second.1, "visible cat must animate, not freeze at a still")
        let output = URL(fileURLWithPath: ".build/ui-review")
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try! second.0.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("desktop-pet-live.png"))
        state.desktopPetEnabled = false; settle()
        withExtendedLifetime(live) {}
        print("NativeDesktopPetChecks: persistence, independent mood/status, display geometry, visibility, nonactivating panel, compact mode and recovery passed")
        print("NativeDesktopPetChecks: bundled Rive draws and advances in a real transparent companion window")
    }
}

private protocol PetWindowImaging { func image(of window: CGWindowID) -> CGImage? }
private struct PetWindowCapture: PetWindowImaging {
    @available(macOS, deprecated: 14.0)
    func image(of window: CGWindowID) -> CGImage? {
        CGWindowListCreateImage(.null, .optionIncludingWindow, window, [.boundsIgnoreFraming, .bestResolution])
    }
}
