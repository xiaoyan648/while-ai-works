import AppKit
import SwiftUI
import WhileCore
import AgentHUDCore

/// Renders the menu bar panel, settings and collection offscreen, in light and dark,
/// into `.build/ui-review` for design review. Uses an isolated defaults store.
/// The live cat needs Metal, so these renders use stills from `design/mascot/stills.sh`
/// when present and the SF Symbol fallback otherwise.
@main enum NativeUIReviewChecks {
    static let output = URL(fileURLWithPath: ".build/ui-review")
    static let stills = URL(fileURLWithPath: "design/mascot/build/stills")

    static func main() throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "WhileAIWorks.UIReview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var book = FishingBook()
        for (index, species) in CatchSpecies.catalog.enumerated() where (index < 8 && !species.isSecret) || (!species.isFish && index % 2 == 0) {
            let share = index % 3 == 0 ? 0.97 : 0.62
            book.record(.init(species: species, sizeCM: species.minCM + (species.maxCM - species.minCM) * share))
            if index % 2 == 0 { book.record(.init(species: species, sizeCM: species.minCM)) }
        }
        book.save(defaults: defaults)
        let state = AppState(defaults: defaults)
        state.soundEnabled = false
        state.selectedSources = [.codex, .qoder]

        let panels: [(String, MascotMood, (AppState) -> Void)] = [
            ("idle", .idle, { $0.desktopEnabled = false; $0.followAI = true; $0.mode = .fishing }),
            ("sleep", .sleep, { $0.followAI = true; $0.desktopEnabled = true; $0.detectedWorking = false; $0.mode = .fishing }),
            ("watch", .watch, { $0.followAI = true; $0.desktopEnabled = true; $0.detectedWorking = true
                $0.activeSessionCounts = [.codex: 2]; $0.workIntensity = 0.8; $0.mode = .fishing }),
            ("play", .play, { $0.followAI = true; $0.desktopEnabled = true; $0.detectedWorking = true
                $0.activeSessionCounts = [.codex: 1]; $0.mode = .woodfish })
        ]
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            for (name, mood, configure) in panels {
                configure(state)
                precondition(state.mascotMood == mood, "panel fixture \(name) must put the cat in \(mood)")
                state.mascotCoat = .ink
                let mascot = MascotController(bundle: nil, placeholder: still(state.mascotCoat, mood.rawValue))
                try render(MenuBarView(state: state, mascot: mascot), name: "panel-\(name)-\(theme)", dark: dark,
                           background: NSColor(white: dark ? 0.17 : 0.93, alpha: 1))
            }
            state.desktopEnabled = false
            state.desktopPetEnabled = true
            state.detectedWorking = false
            for presentation in DesktopPetPresentation.allCases {
                state.desktopPetPresentation = presentation
                try render(MenuBarView(state: state, mascot: MascotController(bundle: nil, placeholder: still(.ink, "idle"))),
                           name: "panel-cat-\(presentation.rawValue)-\(theme)", dark: dark,
                           background: NSColor(white: dark ? 0.17 : 0.93, alpha: 1))
            }
            state.desktopPetPresentation = .companion
            state.desktopPetShowsStatus = true
            state.activeSessionCounts = [.codex: 2, .qoder: 0]
            state.workSourceDetails = [.qoder: "等待 Qoder 监听状态"]
            state.detectedWorking = true
            try render(DesktopPetView(state: state, mascot: MascotController(bundle: nil, placeholder: still(.ink, "watch"))),
                       name: "desktop-pet-\(theme)", dark: dark, background: .clear)
            state.desktopPetShowsStatus = false
            try render(DesktopPetView(state: state, mascot: MascotController(bundle: nil, placeholder: still(.snow, "sleep"))),
                       name: "desktop-pet-compact-\(theme)", dark: dark, background: .clear)
            state.desktopPetShowsStatus = true
            state.desktopPetPresentation = .dock
            state.selectedSources = Set(WorkSource.allCases)
            state.activeSessionCounts = [.codex: 2, .claude: 1, .qoder: 0, .workbuddy: 0]
            state.desktopDockSource = .codex
            state.desktopWorkSessions = [.init(id: "sample-tool", source: .codex, phase: .tool),
                                         .init(id: "sample-reply", source: .codex, phase: .replying)]
            state.agentReplyPreviews = true
            state.agentDashboard = AgentDockData(
                quotas: [.init(id: "sample-window", source: .codex, title: "每周", remaining: 79,
                               resetAt: Date().addingTimeInterval(7200), observedAt: Date(), stale: false, window: .weekly)],
                sessions: [.init(id: "sample-session", source: .codex, title: "猫条布局与原生交互", project: "While AI Works",
                                 status: "已回复", running: false, tokensIn: 12800, tokensOut: 2400, cacheRead: 9600,
                                 reply: "已完成竖向猫条和卡片布局。浅色与深色外观都支持，桌面小猫也可以随时切换。窗口切换、键盘焦点与原会话同步检查均已通过；完整回复可在文字末尾的省略号上悬停查看。",
                                 observedAt: Date(), navigationURL: nil, resumeCommand: nil, event: .finished, eventAt: Date()),
                           .init(id: "sample-running", source: .codex, title: "调整小猫的趴姿", project: "While AI Works",
                                 status: "工作中", running: true, tokensIn: 3100, tokensOut: 400, cacheRead: 2000, reply: nil,
                                 observedAt: Date(), navigationURL: nil, resumeCommand: nil, event: .working, eventAt: Date())], updatedAt: Date())
            state.desktopDockTab = .sessions
            for attachment in DesktopDockAttachment.allCases {
            state.desktopDockAttachment = attachment
            for orientation in DesktopDockOrientation.allCases {
                state.desktopDockOrientation = orientation
                state.desktopPetShowsStatus = true
                try render(DockReviewComposition(state: state,
                    perch: MascotController(bundle: nil, placeholder: still(.ink, "perched"))),
                    name: "cat-dock-\(orientation.rawValue)-\(theme)-\(attachment.rawValue)", dark: dark,
                    background: NSColor(rgb: dark ? 0x5265A1 : 0xCCD2EE))
            }
            }
            state.desktopDockTab = .quota
            try render(DockReviewComposition(state: state, perch: MascotController(bundle: nil, placeholder: still(.ink, "perched"))),
                       name: "cat-dock-quota-\(theme)", dark: dark, background: NSColor(rgb: dark ? 0x5265A1 : 0xCCD2EE))
            let savedDashboard = state.agentDashboard
            state.desktopDockSource = .claude
            state.agentDashboard = AgentDockData(quotas: [
                .init(id: "sample-claude-session", source: .claude, title: "当前会话", remaining: 61, resetAt: Date().addingTimeInterval(6200), observedAt: Date(), stale: false, window: .session),
                .init(id: "sample-claude-week", source: .claude, title: "每周限制 · 所有模型", remaining: 77, resetAt: Date().addingTimeInterval(86400 * 3), observedAt: Date(), stale: false, window: .weekly),
                .init(id: "sample-claude-model", source: .claude, title: "每周限制 · Sonnet", remaining: 92, resetAt: Date().addingTimeInterval(86400 * 3), observedAt: Date(), stale: false, window: .modelWeekly)
            ], sessions: [.init(id: "sample-heavy-cache", source: .claude, title: "fixture", project: nil, status: "已完成", running: false,
                tokensIn: 14_800_000, tokensOut: 1_240_000, cacheRead: 372_000_000, reply: nil, observedAt: Date(), navigationURL: nil, resumeCommand: nil)],
                plans: [.claude: "Pro"], updatedAt: Date())
            try render(DockReviewComposition(state: state, perch: MascotController(bundle: nil, placeholder: still(.ink, "perched"))),
                       name: "cat-dock-quota-claude-\(theme)", dark: dark, background: NSColor(rgb: dark ? 0x5265A1 : 0xCCD2EE))
            try render(AgentDockUsageView(usage: AgentLocalUsage(sessions: state.agentDashboard.sessions)).padding(14),
                       name: "cat-token-usage-large-\(theme)", dark: dark, size: NSSize(width: 316, height: 152), background: NSColor(rgb: dark ? 0x060708 : 0xFAFAFC))
            try render(AgentDockUsageView(usage: AgentLocalUsage(sessions: [])).padding(14),
                       name: "cat-token-usage-empty-\(theme)", dark: dark, size: NSSize(width: 316, height: 100), background: NSColor(rgb: dark ? 0x060708 : 0xFAFAFC))
            state.agentDashboard = savedDashboard; state.desktopDockSource = .codex
            state.desktopDockTab = .sessions
            try render(AgentReplyPreviewContent(reply: state.agentDashboard.sessions[0].reply ?? ""), name: "agent-reply-hover-\(theme)", dark: dark,
                       size: NSSize(width: 360, height: 160), background: .windowBackgroundColor)
            let question = PermissionQuestion(id: "sample-question", question: "回复应该在哪里展示？",
                options: [.init(label: "在详情卡中", description: "简短问题就地处理"), .init(label: "打开独立浮窗", description: "适合长内容")])
            let request = PermissionRequest(id: "sample-native-question", source: .codex, sessionID: "sample-session",
                toolName: "request_user_input_async", summary: question.question, detail: nil, cwd: "/fixture/While AI Works",
                questions: [question], nativeApproval: .asynchronousQuestion(turnID: "sample-turn"), at: Date())
            state.agentInteractions = [.init(request: request)]
            state.desktopDockSource = .codex
            for orientation in DesktopDockOrientation.allCases {
                state.desktopDockOrientation = orientation
                try render(DockReviewComposition(state: state, perch: MascotController(bundle: nil, placeholder: still(.ink, "perched"))),
                    name: "cat-interaction-\(orientation.rawValue)-\(theme)", dark: dark,
                    background: NSColor(rgb: dark ? 0x5265A1 : 0xCCD2EE))
            }
            state.agentInteractionDrafts[request.id] = .init(custom: [question.answerKey: "希望直接在对应会话里回答。"])
            state.agentInteractionInputID = request.id
            try render(DockReviewComposition(state: state, perch: MascotController(bundle: nil, placeholder: still(.ink, "perched"))),
                       name: "cat-dock-question-input-\(theme)", dark: dark, background: NSColor(rgb: dark ? 0x5265A1 : 0xCCD2EE))
            state.agentInteractionInputID = nil
            state.agentInteractions[0].phase = .confirming
            try render(DockReviewComposition(state: state, perch: MascotController(bundle: nil, placeholder: still(.ink, "perched"))),
                       name: "cat-dock-question-confirming-\(theme)", dark: dark, background: NSColor(rgb: dark ? 0x5265A1 : 0xCCD2EE))
            state.agentInteractions[0].phase = .ready
            try render(AgentInteractionWindowView(state: state, id: request.id, dismiss: {}), name: "agent-interaction-window-\(theme)",
                       dark: dark, size: NSSize(width: 480, height: 500), background: .windowBackgroundColor)
            state.agentInteractions = [.init(request: .init(id: "sample-claude-approval", source: .claude,
                sessionID: "fixture-session", toolName: "Bash", summary: "允许 Claude 使用 Bash？",
                detail: "{\"command\":\"npm test -- --runInBand\",\"description\":\"运行项目检查\"}", cwd: "/fixture/project", at: Date()), viaHook: true)]
            state.desktopDockSource = .claude
            state.desktopDockTab = .sessions
            try render(DockReviewComposition(state: state, perch: MascotController(bundle: nil, placeholder: still(.ink, "perched"))),
                       name: "cat-dock-approval-\(theme)", dark: dark, background: NSColor(rgb: dark ? 0x5265A1 : 0xCCD2EE))
            state.agentInteractionDrafts["sample-claude-approval"] = .init(reviewedDetail: state.agentInteractions[0].request.detail)
            try render(DockReviewComposition(state: state, perch: MascotController(bundle: nil, placeholder: still(.ink, "perched"))),
                       name: "cat-dock-approval-reviewed-\(theme)", dark: dark, background: NSColor(rgb: dark ? 0x5265A1 : 0xCCD2EE))
            try render(AgentInteractionWindowView(state: state, id: "sample-claude-approval", dismiss: {}),
                       name: "agent-interaction-approval-\(theme)", dark: dark, size: NSSize(width: 480, height: 500), background: .windowBackgroundColor)
            state.agentInteractions = []
            state.mascotCoat = .snow
            try render(SettingsView(state: state, preview: MascotController(bundle: nil, placeholder: still(state.mascotCoat, "idle"))),
                       name: "settings-\(theme)", dark: dark, size: NSSize(width: 520, height: 1040), background: .windowBackgroundColor)
            for section in [FishingGuide.Section.book, .rods, .achievements] {
                try render(FishingGuide(state: state, section: section), name: "collection-\(section)-\(theme)", dark: dark,
                           size: NSSize(width: 940, height: 700), background: .windowBackgroundColor)
            }
            let koi = CatchSpecies.catalog.first { book.records[$0.id] != nil && $0.isFish }!
            try render(SpeciesDetail(state: state, species: koi), name: "species-detail-\(theme)", dark: dark, background: .windowBackgroundColor)
        }
        try renderStatusIcons()
        print("NativeUIReviewChecks: panel moods, settings, collection pages and menu bar icons rendered to \(output.path) in light and dark.")
    }

    /// Off, playing, and playing while the AI works; on light and dark menu bars at 4x.
    static func renderStatusIcons() throws {
        let variants: [(filled: Bool, working: Bool)] = [(false, false), (true, false), (true, true)]
        let cell = NSSize(width: 44, height: 28), scale: CGFloat = 4
        let size = NSSize(width: cell.width * CGFloat(variants.count), height: cell.height * 2)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (row, dark) in [false, true].enumerated() {
            NSColor(white: dark ? 0.16 : 0.93, alpha: 1).setFill()
            NSRect(x: 0, y: CGFloat(row) * cell.height, width: size.width, height: cell.height).fill()
            for (index, variant) in variants.enumerated() {
                let icon = StatusIcon.image(filled: variant.filled, working: variant.working)
                let tinted = NSImage(size: icon.size, flipped: false) { rect in
                    icon.draw(in: rect)
                    (dark ? NSColor.white : NSColor.black).set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: CGFloat(index) * cell.width + 13, y: CGFloat(row) * cell.height + 5, width: 18, height: 18))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("status-icons.png"))
    }

    static func still(_ coat: MascotCoat, _ pose: String) -> NSImage? {
        NSImage(contentsOf: stills.appendingPathComponent("\(coat.rawValue)-\(pose).png"))
    }

    static func render<V: View>(_ view: V, name: String, dark: Bool, size: NSSize? = nil, background: NSColor) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let host = NSHostingView(rootView: view.background(Color(nsColor: background)))
        host.appearance = appearance
        let bounds = NSRect(origin: .zero, size: size ?? host.fittingSize)
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = bounds
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = bounds.size
        appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
        try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
        window.close()
    }
}

/// Offscreen layout review uses the actual authored Rive stills. Live animation
/// and native pointer handling remain the separate desktop-dock gate.
private struct DockReviewComposition: View {
    @ObservedObject var state: AppState
    let perch: MascotController
    private var strip: some View {
        DesktopDockSurface(state: state)
    }
    private var card: some View {
        let size = DesktopDockGeometry.detailSize
        let card = DesktopDockGeometry.cardFrame(in: size)
        let cat = DesktopDockGeometry.perchedCatFrame(in: size)
        return ZStack(alignment: .topLeading) {
            DesktopDockDetailView(state: state).frame(width: card.width, height: card.height).offset(x: card.minX, y: card.minY)
            PerchedReviewSnapshot(mascot: perch).frame(width: cat.width, height: cat.height).offset(x: cat.minX, y: cat.minY)
        }.frame(width: size.width, height: size.height, alignment: .topLeading)
    }
    var body: some View {
        Group {
            if state.desktopDockOrientation == .vertical {
                HStack(alignment: .bottom, spacing: 2) { card; strip }
            } else {
                VStack(alignment: .trailing, spacing: 2) { card; strip }
            }
        }.padding(22)
    }
}

private struct PerchedReviewSnapshot: NSViewRepresentable {
    let mascot: MascotController
    func makeNSView(context: Context) -> PerchedMascotHost { PerchedMascotHost(mascot: mascot) }
    func updateNSView(_ view: PerchedMascotHost, context: Context) { view.rim = CGPoint(x: 22, y: 80); view.needsLayout = true }
}
