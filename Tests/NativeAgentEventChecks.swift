import AppKit
import SwiftUI
import AgentHUDCore

@main enum NativeAgentEventChecks {
    static func main() {
        _ = NSApplication.shared
        func check(_ condition: @autoclosure () -> Bool, _ message: String = "unexpected native state", line: UInt = #line) {
            guard condition() else {
                fputs("NativeAgentEventChecks line \(line): \(message)\n", stderr)
                exit(1)
            }
        }
        let suite = "WhileAIWorks.NativeAgentEvents." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(defaults: defaults)
        state.soundEnabled = false; state.selectedSources = [.codex, .claude]
        state.desktopPetEnabled = true; state.desktopPetPresentation = .dock
        state.dock(on: .left)
        state.activeSessionCounts = [.codex: 1, .claude: 0]
        let dock = DesktopDockController(state: state, mascot: MascotController(bundle: nil), cardMascot: MascotController(bundle: nil))
        func settle(_ seconds: Double = 0.2) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        settle()
        func marks(_ view: NSView) -> [AgentActivityMarkView] {
            (view as? AgentActivityMarkView).map { [$0] } ?? view.subviews.flatMap(marks)
        }
        let icons = marks(dock.panel.contentView!)
        check(icons.count == 2, "both agent marks are retained")
        let active = icons.filter { $0.isAnimating }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            check(active.count == 1, "only the working logo animates")
            let logoLayer = active[0].layer!.sublayers!.first!
            check(logoLayer.anchorPoint == CGPoint(x: 0.5, y: 0.5), "logo motion stays centered")
            var scales: [CGFloat] = [], angles: [CGFloat] = []
            for _ in 0..<20 {
                settle(0.1)
                guard let frame = logoLayer.presentation() else { continue }
                scales.append(hypot(frame.transform.m11, frame.transform.m12))
                angles.append(atan2(frame.transform.m12, frame.transform.m11))
                check(frame.position == logoLayer.position, "activity never moves the logo's center or hit target")
            }
            check(scales.count >= 16 && scales.max()! - scales.min()! > 0.08,
                  "the visible logo has a noticeable breathing range")
            check(angles.count >= 16 && angles.max()! > 0.15 && angles.min()! < -0.15,
                  "the visible compositor rocks the logo in both directions")
            active[0].configure(source: .codex, dark: true, working: true, reduceMotion: true)
            check(!active[0].isAnimating, "reduced motion leaves a static logo")
            check(CATransform3DIsIdentity(logoLayer.transform), "reduced motion restores an upright, full-size logo")
            active[0].configure(source: .codex, dark: true, working: true, reduceMotion: false)
            check(active[0].isAnimating)
            active[0].configure(source: .codex, dark: true, working: false, reduceMotion: false)
            check(!active[0].isAnimating, "completion stops the logo animation")
            check(CATransform3DIsIdentity(logoLayer.transform), "completion leaves no rotation or scale behind")
            active[0].configure(source: .codex, dark: true, working: true, reduceMotion: false)
        } else { check(active.isEmpty) }
        let longReply = "已完成猫条交互与布局调整。详细检查覆盖多种状态，以及窗口切换、键盘焦点和原会话同步。Mixed English 👩🏽‍💻 内容会按真实文字宽度截断，不留额外按钮列。"
        func fixture(_ reply: String) -> AgentDockSession {
            .init(id: "inline-reply", source: .codex, title: "原生文字检查", project: nil,
                  status: "已回复", running: false, tokensIn: 0, tokensOut: 0, cacheRead: 0,
                  reply: reply, observedAt: Date(), navigationURL: nil, resumeCommand: nil)
        }
        var preview: String?; var previewAnchor: NSView?
        let show: (AgentDockSession, NSView) -> Void = { preview = $0.reply; previewAnchor = $1 }
        let summary = ReplySummaryView(session: fixture(longReply), show: show, hide: {})
        summary.frame = CGRect(x: 0, y: 0, width: 280, height: 28)
        summary.layoutSubtreeIfNeeded()
        let twoLineHeight = summary.summaryHeight(width: 280)
        check(twoLineHeight > 20 && twoLineHeight <= 28, "long replies occupy only two compact lines")
        check(summary.ellipsisRect != nil && summary.ellipsisRect!.minY == twoLineHeight / 2, "ellipsis belongs to the second text line")
        check(summary.ellipsisRect!.maxX <= 280 && summary.trackingAreas.count == 1)
        check(summary.trackingAreas[0].rect.width < 22, "hover targets the inline ellipsis, not the whole text or a button column")
        check(summary.subviews[0].accessibilityPerformPress())
        check(preview == longReply && previewAnchor?.frame == summary.ellipsisRect, "preview retains the full original reply and exact inline anchor")
        summary.configure(session: fixture("完整短回复。"), show: show, hide: {})
        summary.layoutSubtreeIfNeeded()
        check(summary.summaryHeight(width: 280) == twoLineHeight / 2 && summary.ellipsisRect == nil && summary.trackingAreas.isEmpty,
              "short replies need no extra ellipsis or hover target")
        summary.configure(session: fixture(longReply), show: show, hide: {})
        summary.frame.size.width = 1600; summary.layoutSubtreeIfNeeded()
        check(summary.ellipsisRect == nil, "widening reflows the summary and removes a redundant preview")
        summary.frame.size.width = 160; summary.layoutSubtreeIfNeeded()
        check(summary.ellipsisRect != nil && summary.ellipsisRect!.maxX <= 160, "narrow layouts reanchor to their own text ellipsis")
        summary.frame.size.height = 0; summary.layoutSubtreeIfNeeded()
        check(summary.ellipsisRect == nil, "a collapsed summary has no invisible hover target")
        let screen = NSScreen.main!.visibleFrame
        let replyHost = DesktopPetPanel(contentRect: CGRect(x: screen.midX - 140, y: screen.midY, width: 280, height: 28),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        replyHost.isReleasedWhenClosed = false; replyHost.allowsKeyboard = false
        replyHost.contentView = summary; replyHost.orderFrontRegardless(); settle()
        summary.layoutSubtreeIfNeeded()
        let reader = AgentReplyPreviewController()
        reader.show(fixture(longReply), from: summary.subviews[0]); settle(0.4)
        check(reader.panel.isVisible && !reader.panel.isKeyWindow && reader.replyText == longReply,
              "the real inline anchor opens a complete read-only tooltip without taking keyboard focus")
        reader.dismiss(); replyHost.orderOut(nil)
        check(!reader.panel.isVisible && reader.replyText == nil, "closing clears the reply preview")
        dock.hover(.codex, entered: true); settle()
        state.desktopDockTab = .quota
        dock.hover(.claude, entered: true)
        check(state.desktopDockTab == .sessions, "switching agent returns to session events")
        state.desktopDockTab = .quota; state.desktopPetPresentation = .companion; dock.refresh()
        state.desktopPetPresentation = .dock; dock.refresh()
        check(!state.desktopPetShowsStatus && !dock.detailPanel.isVisible, "mode changes keep the card collapsed")
        state.desktopPetShowsStatus = true; dock.refresh()
        check(state.desktopDockTab == .sessions, "reopening after a presentation change returns to sessions")
        dock.dismiss(); dock.select(.claude)
        let destination = URL(string: "claude://claude.ai/epitaxy/local_00000000-0000-0000-0000-000000000001")!
        func navigationFixture(_ title: String, event: AgentSessionEvent, url: URL?, command: String? = nil) -> AgentDockSession {
            .init(id: title, source: .claude, title: title, project: nil, status: "最近会话", running: event == .working,
                  tokensIn: 0, tokensOut: 0, cacheRead: 0, reply: nil, observedAt: Date(), navigationURL: url,
                  resumeCommand: command, event: event)
        }
        state.agentDashboard.sessions = [
            navigationFixture("运行中的桌面会话", event: .working, url: destination),
            navigationFixture("最近的桌面会话", event: .recent, url: destination),
            navigationFixture("终端会话", event: .recent, url: nil, command: "claude --resume fixture"),
            navigationFixture("缺少入口", event: .finished, url: nil)
        ]
        dock.refresh(); settle(0.4)
        let navigationRoot = dock.detailPanel.contentView!
        navigationRoot.layoutSubtreeIfNeeded()
        let navigationBitmap = navigationRoot.bitmapImageRepForCachingDisplay(in: navigationRoot.bounds)!
        navigationRoot.cacheDisplay(in: navigationRoot.bounds, to: navigationBitmap)
        let navigationOutput = URL(fileURLWithPath: ".build/ui-review/session-navigation.png")
        try! FileManager.default.createDirectory(at: navigationOutput.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! navigationBitmap.representation(using: .png, properties: [:])!.write(to: navigationOutput)
        print("Session navigation fixture captured: \(navigationOutput.path)")
        state.agentDashboard.sessions = []
        dock.dismiss(); dock.select(.codex)
        let question = PermissionQuestion(id: "native-question", question: "选择布局方式", options: [.init(label: "就地处理"), .init(label: "独立浮窗")])
        let request = PermissionRequest(id: "native-question-request", source: .codex, sessionID: "native-question-session",
            toolName: "request_user_input_async", summary: question.question, detail: nil, cwd: "/fixture/project",
            questions: [question], nativeApproval: .asynchronousQuestion(turnID: "native-fixture-turn"), at: Date())
        state.agentInteractions = [.init(request: request)]
        state.agentInteractionSelectionID = request.id
        state.agentInteractionInputID = request.id
        state.agentInteractionDrafts[request.id] = .init(custom: [question.answerKey: "保留草稿"])
        dock.refresh(); state.focusAgentComposer(); settle(0.35)
        check(dock.detailPanel.isKeyWindow && dock.detailPanel.firstResponder is NSTextView,
                     "an explicit answer receives the native field editor")
        let editor = dock.detailPanel.firstResponder as! NSTextView
        check(editor.visibleRect.height >= editor.bounds.height - 1, "the whole answer field must be visible")
        let newer = PermissionRequest(id: "native-newer-request", source: .codex, sessionID: "native-other-session",
            toolName: "Bash", summary: "运行另一个检查", detail: "npm test", cwd: "/fixture/other", at: Date().addingTimeInterval(1))
        state.agentInteractions.append(.init(request: newer, viaHook: true)); settle()
        check(state.agentInteractionSelectionID == request.id && state.agentInteractionInputID == request.id &&
                     dock.detailPanel.firstResponder === editor, "new events cannot retarget an edited answer")
        check(editor.visibleRect.height >= editor.bounds.height - 1, "new events cannot push the field behind the viewport fade")
        state.agentInteractionInputID = nil; dock.refresh(); settle()
        check(!dock.detailPanel.canBecomeKey && !dock.detailPanel.isKeyWindow, "closing input releases keyboard focus")
        dock.dismiss(); dock.select(.codex); settle()
        check(!dock.detailPanel.canBecomeKey && state.agentInteractionDrafts[request.id]?.custom[question.answerKey] == "保留草稿",
                     "reopening a saved answer previews it without automatic keyboard focus")
        state.desktopPetEnabled = false; dock.refresh(); settle()
        check(icons.allSatisfy { !$0.isAnimating }, "hidden windows stop activity rendering")
        print("NativeAgentEventChecks: inline text truncation/reflow/full reply, working-logo animation/reduced motion, session default, fully visible answer, incoming-event focus stability and draft reopening passed; no real answer sent")
        withExtendedLifetime(dock) {}
    }
}
