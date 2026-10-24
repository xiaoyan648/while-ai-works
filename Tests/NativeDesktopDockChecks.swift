import AppKit
import SwiftUI
import WhileCore
import AgentHUDCore

/// Like `precondition`, but says which check failed even in optimized builds.
private func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "unexpected state",
                   line: UInt = #line) {
    guard condition() else {
        fputs("NativeDesktopDockChecks line \(line): \(message())\n", stderr)
        exit(1)
    }
}

@main enum NativeDesktopDockChecks {
    static func main() throws {
        _ = NSApplication.shared
        let suite = "WhileAIWorks.DesktopDockChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(defaults: defaults)
        state.soundEnabled = false
        check(state.desktopPetPresentation == .dock && state.desktopDockOrientation == .vertical && state.desktopDockEdge == .right)
        check(state.desktopCompanionAppearance == .system && !state.desktopPetShowsStatus && state.desktopDockAttachment == .attached)
        state.desktopDockOrientation = .horizontal
        check(state.desktopDockEdge == .bottom)
        state.dock(on: .top)
        state.desktopDockPosition = DesktopDockPosition(screenID: "external", fraction: 0.72)
        state.desktopCompanionAppearance = .dark
        state.desktopDockAttachment = .floating
        let restored = AppState(defaults: defaults)
        check(restored.desktopDockOrientation == .horizontal && restored.desktopDockEdge == .top)
        check(restored.desktopDockPosition == state.desktopDockPosition && restored.desktopCompanionAppearance == .dark)
        check(restored.desktopDockAttachment == .floating)
        state.desktopPetPosition = DesktopPetPosition(screenID: "cat", x: 0.2, y: 0.3)
        state.desktopPetPresentation = .companion
        state.resetDesktopPetPosition()
        check(state.desktopPetPosition == nil && state.desktopDockPosition != nil, "forms own independent saved positions")
        state.desktopPetPresentation = .dock
        state.resetDesktopPetPosition()
        check(state.desktopDockPosition == nil)

        for visible in [CGRect(x: 0, y: 25, width: 1512, height: 920),
                        CGRect(x: -1920, y: -120, width: 1920, height: 1080),
                        CGRect(x: 40, y: 80, width: 440, height: 510)] {
            for attachment in DesktopDockAttachment.allCases {
            for edge in DesktopDockEdge.allCases {
                for fraction in [0.0, 0.5, 1.0, Double.nan] {
                    let size = DesktopDockGeometry.size(orientation: edge.orientation, sources: 4)
                    let origin = DesktopDockGeometry.origin(size: size, edge: edge, fraction: fraction, visible: visible, attachment: attachment)
                    let dock = CGRect(origin: origin, size: size)
                    check(visible.contains(dock), "dock fits negative screen origins and usable edges")
                    if attachment == .attached {
                        let contact: CGFloat
                        switch edge {
                        case .left: contact = dock.minX - visible.minX
                        case .right: contact = dock.maxX - visible.maxX
                        case .top: contact = dock.maxY - visible.maxY
                        case .bottom: contact = dock.minY - visible.minY
                        }
                        check(abs(contact) < 0.01, "attached panel meets the usable edge exactly")
                    }
                    let outline = CatDockContour(orientation: edge.orientation, edge: edge, attachment: attachment)
                        .path(in: CGRect(origin: .zero, size: size))
                    let value = DesktopDockGeometry.fraction(origin: origin, size: size, edge: edge, visible: visible)
                    check(value.isFinite && value >= 0 && value <= 1)
                    let roundtrip = DesktopDockGeometry.origin(size: size, edge: edge, fraction: value, visible: visible, attachment: attachment)
                    check(abs(roundtrip.x - origin.x) < 0.01 && abs(roundtrip.y - origin.y) < 0.01)
                    for index in 0..<4 {
                        let tile = DesktopDockGeometry.tileFrame(index: index, orientation: edge.orientation)
                        check(CGRect(origin: .zero, size: size).contains(tile))
                        check(outline.contains(CGPoint(x: tile.midX, y: tile.midY)), "logo targets remain inside the silhouette")
                        let anchor = CGPoint(x: origin.x + tile.midX, y: origin.y + size.height - tile.midY)
                        let detail = DesktopDockGeometry.detailFrame(dock: dock, anchor: anchor, edge: edge, visible: visible)
                        check(visible.contains(detail), "every entry's card fits at both ends of every edge")
                        check(!dock.intersects(detail), "detail never covers the dock's input targets")
                    }
                }
            }
        }
        }
        for name in ["chatgpt", "claude", "qoder", "qoder-dark", "workbuddy"] {
            check(AgentMarkAssets.image(name) != nil, "client mark resource must be available")
        }
        for source in [WorkSource.hermes, .dsh] { check(NSImage(systemSymbolName: source.dockSymbol, accessibilityDescription: nil) != nil, "local client icon exists on this OS") }
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
        check(mascot.isAvailable && cardMascot.isAvailable)
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
        check(dock.panel.isVisible && !dock.cardVisible)
        check(!dock.panel.canBecomeKey && !dock.detailPanel.canBecomeKey && !dock.panel.canBecomeMain)
        let nativeRoot = dock.panel.contentView!
        let catRect = DesktopDockGeometry.catFrame(orientation: .vertical)
        let catPoint = CGPoint(x: catRect.midX, y: nativeRoot.bounds.height - catRect.midY)
        check(nativeRoot.hitTest(catPoint) === nativeRoot, "flipped native host routes the top cat to drag/pet")
        let entryRect = DesktopDockGeometry.tileFrame(index: 0, orientation: .vertical)
        let entryPoint = CGPoint(x: entryRect.midX, y: nativeRoot.bounds.height - entryRect.midY)
        check(nativeRoot.hitTest(entryPoint) != nil && nativeRoot.hitTest(entryPoint) !== nativeRoot,
                     "actual window coordinates route an agent entry to SwiftUI")
        check(nativeRoot.hitTest(CGPoint(x: 2, y: 2)) == nil, "shadow padding passes through")
        let initialFrame = dock.panel.frame
        let initialKey = NSApp.keyWindow
        dock.hover(.codex, entered: true)
        dock.hover(.codex, entered: false)
        settle(0.14)
        check(!dock.cardVisible, "passing through an entry does not open a card")
        dock.hover(.codex, entered: true)
        dock.hover(.claude, entered: true)
        dock.hover(.codex, entered: false)
        settle(0.2)
        check(dock.cardVisible && state.desktopDockSource == .claude,
                     "latest entry wins even when the previous exit arrives late")
        let visibleCard = dock.detailPanel.contentView!
        for source in [WorkSource.qoder, .workbuddy, .codex, .claude, .codex] {
            let previous = state.desktopDockSource!
            dock.hover(source, entered: true)
            dock.hover(previous, entered: false)
            check(state.desktopDockSource == source && dock.cardVisible,
                         "an open card switches immediately without another dwell")
            check(dock.detailPanel.contentView === visibleCard,
                         "rapid switching retains the native card and its Rive canvas")
        }
        settle(0.5)
        check(state.desktopDockSource == .codex && dock.cardVisible,
                     "cancelled opening/closing work cannot revert the latest target")
        check(dock.panel.frame == initialFrame && NSApp.keyWindow === initialKey,
                     "hover preserves rail position and keyboard focus")
        dock.select(.codex)
        dock.hover(.claude, entered: true)
        settle(0.14)
        check(state.desktopDockSource == .codex, "a pinned card ignores pointer switching")
        dock.dismiss()
        if ProcessInfo.processInfo.arguments.contains("--hover-only") {
            print("Native dock hover passed: cancelled dwell, latest target, immediate switching, retained canvas, focus preservation and pinning")
            return
        }
        dock.select(.codex); settle(0.6)
        check(dock.cardVisible && state.desktopDockSource == .codex)
        let cardRoot = dock.detailPanel.contentView!
        let cardRect = DesktopDockGeometry.cardFrame(in: cardRoot.bounds.size)
        let cardPoint = CGPoint(x: cardRect.midX, y: cardRoot.bounds.height - cardRect.midY)
        check(cardRoot.hitTest(cardPoint) != nil && cardRoot.hitTest(cardPoint) !== cardRoot, "native card routes scrolling and buttons")
        check(dock.panel.frame == initialFrame && NSApp.keyWindow === initialKey, "opening preserves the dock and keyboard focus")
        state.agentComposeSessionID = "fixture-local-draft"
        dock.refresh(); state.focusAgentComposer(); settle()
        check(dock.detailPanel.canBecomeKey && dock.detailPanel.isKeyWindow, "only explicitly opened input receives keyboard focus")
        state.agentComposeSessionID = nil; dock.refresh(); settle()
        check(!dock.detailPanel.canBecomeKey && !dock.detailPanel.isKeyWindow, "closing input releases keyboard focus")
        dock.select(.claude); settle()
        check(dock.cardVisible && state.desktopDockSource == .claude)
        dock.select(.claude); settle()
        check(!dock.cardVisible, "clicking the pinned source again collapses")
        dock.select(.codex); settle()
        dock.dismissOutsideClick(at: CGPoint(x: dock.panel.frame.midX, y: dock.panel.frame.midY))
        check(state.desktopPetShowsStatus, "dock click remains inside the same control")
        dock.dismissOutsideClick(at: CGPoint(x: initialFrame.minX - 600, y: initialFrame.minY - 600))
        check(!state.desktopPetShowsStatus && !dock.cardVisible)

        // Stamps within 1.5 s fall one after another; only the first sounds and twitches.
        let center = DockStampCenter()
        check(center.claim(now: 10) == 0 && center.claim(now: 10.2) == DockStampCenter.stagger && center.claim(now: 12) == 0)
        check(center.contact(sound: false, now: 10) && !center.contact(sound: false, now: 11) && center.contact(sound: false, now: 11.6))

        // Pace: a 5-hour window with an hour left should have 20% remaining when spent
        // evenly. On pace it lasts; spending faster projects the run-out time.
        let resetSoon = Date().addingTimeInterval(3600)
        let onPace = AgentDockQuota(id: "pace", source: .claude, title: "当前会话", remaining: 20, resetAt: resetSoon,
                                    observedAt: Date(), stale: false, window: .session)
        check(abs((onPace.paceRemaining() ?? -1) - 20) < 0.5 && onPace.projectedRunOut() == nil, "on pace lasts the window")
        let burning = AgentDockQuota(id: "burn", source: .claude, title: "当前会话", remaining: 10, resetAt: resetSoon,
                                     observedAt: Date(), stale: false, window: .session)
        check(burning.projectedRunOut().map { abs($0.timeIntervalSinceNow - 1600) < 30 } == true,
                     "90% spent in 4 hours runs out 10% in about 27 minutes")
        check(AgentDockQuota(id: "x", source: .codex, title: "其他", remaining: 50, resetAt: resetSoon, observedAt: Date(),
                                    stale: false, window: .other).paceRemaining() == nil, "no pace without a known window")
        // Tool input reads as a command with every other field kept.
        let readable = AgentInteractionDetail.readable(#"{"command":"npm test","description":"运行检查","timeout":120000,"run_in_background":false}"#)
        check(readable.subject == "npm test" && readable.notes == ["运行检查", "run_in_background：false", "timeout：120000"])
        check(AgentInteractionDetail.readable("rm -rf build").subject == "rm -rf build", "plain text stays as is")

        // Working marks swing in one continuous sine: fastest while passing upright,
        // never pausing there, and neighbouring clients out of step.
        func marks(in view: NSView) -> [AgentActivityMarkView] {
            (view as? AgentActivityMarkView).map { [$0] } ?? view.subviews.flatMap { marks(in: $0) }
        }
        let rail = marks(in: nativeRoot)
        func mark(_ source: WorkSource) -> AgentActivityMarkView { rail.first { $0.source == source }! }
        check(rail.count == WorkSource.allCases.count && mark(.codex).isAnimating && mark(.claude).isAnimating && !mark(.qoder).isAnimating,
                     "only working clients swing")
        settle(AgentActivityMarkView.rampDuration + 0.1)
        var samples: [(time: Double, codex: Double, claude: Double)] = []
        let sampling = CACurrentMediaTime()
        while CACurrentMediaTime() - sampling < Motion.swingPeriod {
            settle(1.0 / 120)
            samples.append((CACurrentMediaTime(), mark(.codex).presentedAngle, mark(.claude).presentedAngle))
        }
        let limit = AgentActivityMarkView.swingAngle
        let widest = samples.map { abs($0.codex) }.max() ?? 0
        check(widest > limit * 0.9 && widest < limit * 1.05, "the swing reaches ±8°")
        let crossings = zip(samples, samples.dropFirst()).filter { ($0.codex < 0) != ($1.codex < 0) }
            .map { abs($1.codex - $0.codex) / ($1.time - $0.time) }
        let peakSpeed = limit * 2 * .pi / Motion.swingPeriod
        check(!crossings.isEmpty && crossings.allSatisfy { $0 > peakSpeed * 0.7 }, "the mark never stops while passing upright")
        check(samples.contains { abs($0.codex - $0.claude) > limit * 0.5 }, "neighbouring clients swing out of step")

        // Work ends with an explicit completion: the swing settles upright, then a paw
        // is stamped on the mark and the ears twitch once.
        let twitches = DockStampCenter.shared.earTwitch
        let done = Date()
        state.activeSessionCounts[.codex] = 0
        state.desktopWorkSessions.removeAll { $0.source == .codex }
        state.agentDashboard.sessions = [AgentDockSession(id: "fixture-codex-done", source: .codex, title: "补齐动效检查", project: "While AI Works",
            status: "已回复", running: false, tokensIn: 0, tokensOut: 0, cacheRead: 0, reply: nil, observedAt: done,
            navigationURL: nil, resumeCommand: nil, event: .finished, eventAt: done)]
        check(state.unseenCompletion(for: .codex) == done && state.unseenCompletion(for: .claude) == nil)
        settle(0.1)
        check(!mark(.codex).isAnimating, "a finished client stops swinging")
        settle(1.0)
        check(abs(mark(.codex).presentedAngle) < 0.01, "the mark comes to rest upright")
        check(DockStampCenter.shared.earTwitch == twitches + 1, "the stamp lands once and twitches the ears")
        let question = PermissionQuestion(id: "fixture-question", question: "选择方向",
            options: [.init(label: "继续", description: "按方案实现")])
        state.agentInteractions = [.init(request: PermissionRequest(id: "fixture-ask", source: .codex, sessionID: "fixture-codex-done",
            toolName: "request_user_input_async", summary: question.question, detail: nil, cwd: "/fixture", questions: [question],
            nativeApproval: .asynchronousQuestion(turnID: "fixture-turn"), at: done))]
        if !ProcessInfo.processInfo.arguments.contains("--no-capture") {
            let stampOutput = URL(fileURLWithPath: ".build/ui-review/cat-dock")
            try FileManager.default.createDirectory(at: stampOutput, withIntermediateDirectories: true)
            for appearance in [DesktopCompanionAppearance.light, .dark] {
                state.desktopCompanionAppearance = appearance; settle(0.6)
                guard let image = (DockWindowCapture() as DockWindowImaging).image(of: CGWindowID(dock.panel.windowNumber)) else { fatalError("dock capture unavailable") }
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                    .write(to: stampOutput.appendingPathComponent("stamp-request-\(appearance.rawValue).png"))
            }
        }
        state.agentInteractions = []
        dock.select(.codex); settle(0.3)
        check(state.unseenCompletion(for: .codex) != nil, "the paw stays while its card is in view")
        dock.select(.claude); settle(0.2)
        check(state.unseenCompletion(for: .codex) == nil, "leaving the card marks the completion seen")
        let seen = defaults.dictionary(forKey: "mascot.dock.completionSeen") as? [String: Double]
        check((seen?["codex"] ?? 0) >= done.timeIntervalSince1970, "seen survives relaunch")
        dock.dismiss(); settle(0.3)
        check(!dock.cardVisible && !dock.detailPanel.isVisible, "the card's exit finishes and releases its window")
        state.agentDashboard.sessions = []
        state.activeSessionCounts[.codex] = 2
        state.desktopWorkSessions = [
            .init(id: "fixture-codex-tool", source: .codex, phase: .tool),
            .init(id: "fixture-codex-reply", source: .codex, phase: .replying),
            .init(id: "fixture-claude", source: .claude, phase: .thinking)
        ]
        state.desktopCompanionAppearance = .dark

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
                    check(first.1 != second.1, "the real perched Rive canvas must advance; the quiet rail is intentionally static")
                }
                check(dock.panel.appearance?.name == appearance.native?.name)
            }
        }
        }
        // The new clients use the same native cards, input surface and child-session hierarchy.
        state.desktopDockOrientation = .vertical; state.desktopDockAttachment = .floating
        state.agentDashboard.sessions = [
            .init(id: "hermes:fixture", source: .hermes, title: "检查网站改动", project: "/fixture/site", status: "工作中", running: true,
                  tokensIn: 3000, tokensOut: 800, cacheRead: 1200, reply: nil, observedAt: Date(), navigationURL: nil, resumeCommand: "hermes --resume fixture", event: .working),
            .init(id: "hermes:child", source: .hermes, title: "检查测试", project: "/fixture/site", status: "工作中", running: true,
                  tokensIn: 600, tokensOut: 200, cacheRead: 0, reply: nil, observedAt: Date(), navigationURL: nil, resumeCommand: nil, event: .working, parentSessionID: "hermes:fixture"),
            .init(id: "deepseek:fixture", source: .dsh, title: "整理改动说明", project: "/fixture/site", status: "已完成", running: false,
                  tokensIn: 2200, tokensOut: 500, cacheRead: 900, reply: nil, observedAt: Date(), navigationURL: nil, resumeCommand: "dsh tui --resume fixture", event: .finished, eventAt: Date())
        ]
        for source in [WorkSource.hermes, .dsh] {
            for appearance in [DesktopCompanionAppearance.light, .dark] {
                state.desktopCompanionAppearance = appearance; dock.dismiss(); settle(0.2); dock.select(source); settle(0.6)
                check(dock.cardVisible && state.dockQuota(for: source) == nil, "local clients have cards without account quota")
                if captureEnabled { _ = try capture(dock, output: output, name: "local-\(source.rawValue)-\(appearance.rawValue)") }
                state.desktopDockTab = .quota; settle(0.3)
                if captureEnabled { _ = try capture(dock, output: output, name: "local-\(source.rawValue)-usage-\(appearance.rawValue)") }
                state.desktopDockTab = .sessions
            }
        }
        let companion = DesktopPetController(state: state, mascot: MascotController(bundle: bundle))
        state.desktopPetPresentation = .companion; settle(0.6)
        check(companion.panel.isVisible && !companion.dockController.panel.isVisible)
        state.desktopPetPresentation = .dock; settle(0.6)
        check(!companion.panel.isVisible && companion.dockController.panel.isVisible, "mode switch shows exactly one resident form")
        state.selectedSources = []; settle()
        dock.select(nil); settle()
        check(dock.panel.isVisible && dock.cardVisible, "empty selection still provides settings and overview")
        state.desktopPetEnabled = false; settle()
        check(!dock.panel.isVisible && !dock.cardVisible && !companion.panel.isVisible)
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
