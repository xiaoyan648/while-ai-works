import AppKit
import SwiftUI
import WhileCore

@main enum NativeDesktopDockChecks {
    static func main() throws {
        _ = NSApplication.shared
        let suite = "WhileAIWorks.DesktopDockChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(defaults: defaults)
        state.soundEnabled = false
        precondition(state.desktopPetPresentation == .dock && state.desktopDockOrientation == .vertical && state.desktopDockEdge == .right)
        precondition(state.desktopCompanionAppearance == .system && !state.desktopPetShowsStatus && state.desktopDockAttachment == .attached)
        state.desktopDockOrientation = .horizontal
        precondition(state.desktopDockEdge == .bottom)
        state.dock(on: .top)
        state.desktopDockPosition = DesktopDockPosition(screenID: "external", fraction: 0.72)
        state.desktopCompanionAppearance = .dark
        state.desktopDockAttachment = .floating
        let restored = AppState(defaults: defaults)
        precondition(restored.desktopDockOrientation == .horizontal && restored.desktopDockEdge == .top)
        precondition(restored.desktopDockPosition == state.desktopDockPosition && restored.desktopCompanionAppearance == .dark)
        precondition(restored.desktopDockAttachment == .floating)
        state.desktopPetPosition = DesktopPetPosition(screenID: "cat", x: 0.2, y: 0.3)
        state.desktopPetPresentation = .companion
        state.resetDesktopPetPosition()
        precondition(state.desktopPetPosition == nil && state.desktopDockPosition != nil, "forms own independent saved positions")
        state.desktopPetPresentation = .dock
        state.resetDesktopPetPosition()
        precondition(state.desktopDockPosition == nil)

        for visible in [CGRect(x: 0, y: 25, width: 1512, height: 920),
                        CGRect(x: -1920, y: -120, width: 1920, height: 1080),
                        CGRect(x: 40, y: 80, width: 440, height: 510)] {
            for attachment in DesktopDockAttachment.allCases {
            for edge in DesktopDockEdge.allCases {
                for fraction in [0.0, 0.5, 1.0, Double.nan] {
                    let size = DesktopDockGeometry.size(orientation: edge.orientation, sources: 4)
                    let origin = DesktopDockGeometry.origin(size: size, edge: edge, fraction: fraction, visible: visible, attachment: attachment)
                    let dock = CGRect(origin: origin, size: size)
                    precondition(visible.contains(dock), "dock fits negative screen origins and usable edges")
                    if attachment == .attached {
                        let contact: CGFloat
                        switch edge {
                        case .left: contact = dock.minX - visible.minX
                        case .right: contact = dock.maxX - visible.maxX
                        case .top: contact = dock.maxY - visible.maxY
                        case .bottom: contact = dock.minY - visible.minY
                        }
                        precondition(abs(contact) < 0.01, "attached panel meets the usable edge exactly")
                    }
                    let outline = CatDockContour(orientation: edge.orientation, edge: edge, attachment: attachment)
                        .path(in: CGRect(origin: .zero, size: size))
                    let value = DesktopDockGeometry.fraction(origin: origin, size: size, edge: edge, visible: visible)
                    precondition(value.isFinite && value >= 0 && value <= 1)
                    let roundtrip = DesktopDockGeometry.origin(size: size, edge: edge, fraction: value, visible: visible, attachment: attachment)
                    precondition(abs(roundtrip.x - origin.x) < 0.01 && abs(roundtrip.y - origin.y) < 0.01)
                    for index in 0..<4 {
                        let tile = DesktopDockGeometry.tileFrame(index: index, orientation: edge.orientation)
                        precondition(CGRect(origin: .zero, size: size).contains(tile))
                        precondition(outline.contains(CGPoint(x: tile.midX, y: tile.midY)), "logo targets remain inside the silhouette")
                        let anchor = CGPoint(x: origin.x + tile.midX, y: origin.y + size.height - tile.midY)
                        let detail = DesktopDockGeometry.detailFrame(dock: dock, anchor: anchor, edge: edge, visible: visible)
                        precondition(visible.contains(detail), "every entry's card fits at both ends of every edge")
                        precondition(!dock.intersects(detail), "detail never covers the dock's input targets")
                    }
                }
            }
        }
        }
        for name in ["chatgpt", "claude", "qoder", "qoder-dark", "workbuddy"] {
            precondition(AgentMarkAssets.image(name) != nil, "client mark resource must be available")
        }
        state.desktopDockOrientation = .vertical
        state.desktopDockAttachment = .floating
        state.desktopCompanionAppearance = .dark
        state.selectedSources = Set(WorkSource.allCases)
        state.desktopPetEnabled = true
        state.activeSessionCounts = [.codex: 2, .claude: 1, .qoder: 0, .workbuddy: 0]
        state.detectedWorking = true
        state.desktopWorkSessions = [
            .init(id: "fixture-codex-tool", source: .codex, phase: .tool),
            .init(id: "fixture-codex-reply", source: .codex, phase: .replying),
            .init(id: "fixture-claude", source: .claude, phase: .thinking)
        ]
        state.workSourceDetails = [.qoder: "等待 Qoder 监听状态", .workbuddy: "等待 WorkBuddy 监听状态"]
        let bundle = Bundle(path: "dist/While AI Works.app")!
        let mascot = MascotController(bundle: bundle), cardMascot = MascotController(bundle: bundle)
        precondition(mascot.isAvailable && cardMascot.isAvailable)
        let dock = DesktopDockController(state: state, mascot: mascot, cardMascot: cardMascot)
        func settle(_ seconds: Double = 0.15) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        settle(1.2)
        if ProcessInfo.processInfo.environment["CAT_LAYOUT_TRACE"] == "1" {
            func dump(_ view: NSView, _ depth: Int = 0) {
                print(String(repeating: " ", count: depth), type(of: view), view.frame, view.isHidden)
                view.subviews.forEach { dump($0, depth + 1) }
            }
            dump(dock.panel.contentView!)
            if let view = mascot.riveViewModel?.riveView {
                fputs("Rive: playing=\(mascot.riveViewModel!.isPlaying) drawable=\(view.drawableSize) frame=\(view.frame) device=\(String(describing: view.device)) layer=\(String(describing: view.layer))\n", stderr)
            }
        }
        precondition(dock.panel.isVisible && !dock.detailPanel.isVisible)
        precondition(!dock.panel.canBecomeKey && !dock.detailPanel.canBecomeKey && !dock.panel.canBecomeMain)
        let nativeRoot = dock.panel.contentView!
        let catRect = DesktopDockGeometry.catFrame(orientation: .vertical)
        let catPoint = CGPoint(x: catRect.midX, y: nativeRoot.bounds.height - catRect.midY)
        precondition(nativeRoot.hitTest(catPoint) === nativeRoot, "flipped native host routes the top cat to drag/pet")
        let entryRect = DesktopDockGeometry.tileFrame(index: 0, orientation: .vertical)
        let entryPoint = CGPoint(x: entryRect.midX, y: nativeRoot.bounds.height - entryRect.midY)
        precondition(nativeRoot.hitTest(entryPoint) != nil && nativeRoot.hitTest(entryPoint) !== nativeRoot,
                     "actual window coordinates route an agent entry to SwiftUI")
        precondition(nativeRoot.hitTest(CGPoint(x: 2, y: 2)) == nil, "shadow padding passes through")
        let initialFrame = dock.panel.frame
        let initialKey = NSApp.keyWindow
        dock.hover(.codex, entered: true)
        dock.hover(.codex, entered: false)
        settle(0.14)
        precondition(!dock.detailPanel.isVisible, "passing through an entry does not open a card")
        dock.hover(.codex, entered: true)
        dock.hover(.claude, entered: true)
        dock.hover(.codex, entered: false)
        settle(0.2)
        precondition(dock.detailPanel.isVisible && state.desktopDockSource == .claude,
                     "latest entry wins even when the previous exit arrives late")
        let visibleCard = dock.detailPanel.contentView!
        for source in [WorkSource.qoder, .workbuddy, .codex, .claude, .codex] {
            let previous = state.desktopDockSource!
            dock.hover(source, entered: true)
            dock.hover(previous, entered: false)
            precondition(state.desktopDockSource == source && dock.detailPanel.isVisible,
                         "an open card switches immediately without another dwell")
            precondition(dock.detailPanel.contentView === visibleCard,
                         "rapid switching retains the native card and its Rive canvas")
        }
        settle(0.5)
        precondition(state.desktopDockSource == .codex && dock.detailPanel.isVisible,
                     "cancelled opening/closing work cannot revert the latest target")
        precondition(dock.panel.frame == initialFrame && NSApp.keyWindow === initialKey,
                     "hover preserves rail position and keyboard focus")
        dock.select(.codex)
        dock.hover(.claude, entered: true)
        settle(0.14)
        precondition(state.desktopDockSource == .codex, "a pinned card ignores pointer switching")
        dock.dismiss()
        if ProcessInfo.processInfo.arguments.contains("--hover-only") {
            print("Native dock hover passed: cancelled dwell, latest target, immediate switching, retained canvas, focus preservation and pinning")
            return
        }
        dock.select(.codex); settle(0.6)
        precondition(dock.detailPanel.isVisible && state.desktopDockSource == .codex)
        let cardRoot = dock.detailPanel.contentView!
        let cardRect = DesktopDockGeometry.cardFrame(in: cardRoot.bounds.size)
        let cardPoint = CGPoint(x: cardRect.midX, y: cardRoot.bounds.height - cardRect.midY)
        precondition(cardRoot.hitTest(cardPoint) != nil && cardRoot.hitTest(cardPoint) !== cardRoot, "native card routes scrolling and buttons")
        precondition(dock.panel.frame == initialFrame && NSApp.keyWindow === initialKey, "opening preserves the dock and keyboard focus")
        state.agentComposeSessionID = "fixture-local-draft"
        dock.refresh(); state.focusAgentComposer(); settle()
        precondition(dock.detailPanel.canBecomeKey && dock.detailPanel.isKeyWindow, "only explicitly opened input receives keyboard focus")
        state.agentComposeSessionID = nil; dock.refresh(); settle()
        precondition(!dock.detailPanel.canBecomeKey && !dock.detailPanel.isKeyWindow, "closing input releases keyboard focus")
        dock.select(.claude); settle()
        precondition(dock.detailPanel.isVisible && state.desktopDockSource == .claude)
        dock.select(.claude); settle()
        precondition(!dock.detailPanel.isVisible, "clicking the pinned source again collapses")
        dock.select(.codex); settle()
        dock.dismissOutsideClick(at: CGPoint(x: dock.panel.frame.midX, y: dock.panel.frame.midY))
        precondition(state.desktopPetShowsStatus, "dock click remains inside the same control")
        dock.dismissOutsideClick(at: CGPoint(x: initialFrame.minX - 600, y: initialFrame.minY - 600))
        precondition(!state.desktopPetShowsStatus && !dock.detailPanel.isVisible)

        let output = URL(fileURLWithPath: ".build/ui-review/cat-dock")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let captureEnabled = !ProcessInfo.processInfo.arguments.contains("--no-capture")
        for appearance in [DesktopCompanionAppearance.light, .dark] {
            state.desktopCompanionAppearance = appearance
            for attachment in DesktopDockAttachment.allCases {
            state.desktopDockAttachment = attachment
            for orientation in DesktopDockOrientation.allCases {
                state.desktopDockOrientation = orientation
                settle()
                dock.select(.codex); settle(0.65)
                if captureEnabled {
                    let first = try capture(dock, output: output, name: "\(orientation.rawValue)-\(appearance.rawValue)-\(attachment.rawValue)")
                    settle(0.3)
                    let second = try capture(dock, output: output, name: "\(orientation.rawValue)-\(appearance.rawValue)-\(attachment.rawValue)")
                    precondition(first.1 != second.1, "the real perched Rive canvas must advance; the quiet rail is intentionally static")
                }
                precondition(dock.panel.appearance?.name == appearance.native?.name)
            }
        }
        }
        let companion = DesktopPetController(state: state, mascot: MascotController(bundle: bundle))
        state.desktopPetPresentation = .companion; settle(0.6)
        precondition(companion.panel.isVisible && !companion.dockController.panel.isVisible)
        state.desktopPetPresentation = .dock; settle(0.6)
        precondition(!companion.panel.isVisible && companion.dockController.panel.isVisible, "mode switch shows exactly one resident form")
        state.selectedSources = []; settle()
        dock.select(nil); settle()
        precondition(dock.panel.isVisible && dock.detailPanel.isVisible, "empty selection still provides settings and overview")
        state.desktopPetEnabled = false; settle()
        precondition(!dock.panel.isVisible && !dock.detailPanel.isVisible && !companion.panel.isVisible)
        withExtendedLifetime((dock, companion)) {}
        print("NativeDesktopDockChecks: defaults, persistence, independent forms, 4 edges, screen boundaries, stable anchor, nonactivating input and light/dark appearance passed")
        print(captureEnabled ? "NativeDesktopDockChecks: live perched Rive verified, static rail marks captured; real window captures in \(output.path) (isolated sample sessions)" : "NativeDesktopDockChecks: live capture SKIPPED (--no-capture); no visual acceptance claimed")
    }
    private static func capture(_ dock: DesktopDockController, output: URL, name: String) throws -> (Data, Data) {
        let camera = DockWindowCapture() as DockWindowImaging
        guard let strip = camera.image(of: CGWindowID(dock.panel.windowNumber)),
              let card = camera.image(of: CGWindowID(dock.detailPanel.windowNumber)) else {
            fatalError("live desktop dock capture unavailable")
        }
        let bounds = dock.panel.frame.union(dock.detailPanel.frame)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        for (image, frame) in [(strip, dock.panel.frame), (card, dock.detailPanel.frame)] {
            NSImage(cgImage: image, size: frame.size).draw(in: frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY))
        }
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
        func catPixels(_ image: CGImage, logical: CGRect, window: NSPanel) -> Data {
            let scale = CGFloat(image.width) / window.frame.width
            let crop = logical.applying(CGAffineTransform(scaleX: scale, y: scale))
            let head = image.cropping(to: crop)!
            let rep = NSBitmapImageRep(cgImage: head)
            var count = 0
            for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
                for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                    if rep.colorAt(x: x, y: y)!.alphaComponent > 0.5 { count += 1 }
                }
            }
            if count <= 20 {
                fputs("NativeDesktopDockChecks: Rive viewport has no visible pixels; unlock the Mac before live capture.\n", stderr)
                exit(2)
            }
            return rep.representation(using: .png, properties: [:])!
        }
        return (catPixels(strip, logical: DesktopDockGeometry.catFrame(orientation: dock.panel.frame.height > dock.panel.frame.width ? .vertical : .horizontal), window: dock.panel),
                catPixels(card, logical: DesktopDockGeometry.perchedCatFrame(in: dock.detailPanel.frame.size), window: dock.detailPanel))
    }
}

private protocol DockWindowImaging { func image(of window: CGWindowID) -> CGImage? }
private struct DockWindowCapture: DockWindowImaging {
    @available(macOS, deprecated: 14.0)
    func image(of window: CGWindowID) -> CGImage? {
        CGWindowListCreateImage(.null, .optionIncludingWindow, window, [.boundsIgnoreFraming, .bestResolution])
    }
}
