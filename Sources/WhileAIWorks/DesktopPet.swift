import AppKit
import Combine
import SwiftUI

/// A companion window never takes the keyboard focus from the app being used.
final class DesktopPetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum DesktopPetPlacement {
    static func clamp(_ origin: CGPoint, size: CGSize, to visible: CGRect) -> CGPoint {
        let left = visible.minX + 10, bottom = visible.minY + 10
        return CGPoint(x: min(max(origin.x, left), max(left, visible.maxX - size.width - 10)),
                       y: min(max(origin.y, bottom), max(bottom, visible.maxY - size.height - 10)))
    }

    static func origin(saved: DesktopPetPosition?, size: CGSize, visible: CGRect) -> CGPoint {
        guard let saved, saved.x.isFinite, saved.y.isFinite else {
            // The lower-right corner belongs to fishing; the cat starts on the left.
            return clamp(CGPoint(x: visible.minX + 28, y: visible.minY + 24), size: size, to: visible)
        }
        return clamp(CGPoint(x: visible.minX + CGFloat(saved.x) * max(0, visible.width - size.width),
                             y: visible.minY + CGFloat(saved.y) * max(0, visible.height - size.height)),
                     size: size, to: visible)
    }

    static func saved(frame: CGRect, visible: CGRect, screenID: String) -> DesktopPetPosition {
        DesktopPetPosition(screenID: screenID,
                           x: Double((frame.minX - visible.minX) / max(1, visible.width - frame.width)),
                           y: Double((frame.minY - visible.minY) / max(1, visible.height - frame.height)))
    }
}

/// Cat coordinates stay fixed while the detail card opens above it.
struct DesktopPetView: View {
    @ObservedObject var state: AppState
    let mascot: MascotController
    static func size(showsStatus: Bool, petSize: DesktopPetSize = .medium) -> CGSize {
        let side = 200 * petSize.scale
        return CGSize(width: showsStatus ? max(280, side) : side, height: side + (showsStatus ? 182 : 0))
    }
    static func catFrame(_ size: DesktopPetSize) -> CGRect {
        CGRect(x: 8 * size.scale, y: 8 * size.scale, width: 184 * size.scale, height: 184 * size.scale)
    }
    static func bubbleFrame(_ size: DesktopPetSize) -> CGRect {
        CGRect(x: 200 * size.scale - 76, y: 200 * size.scale - 60, width: 76, height: 56)
    }
    static func cardFrame(_ size: DesktopPetSize) -> CGRect {
        CGRect(x: 8, y: 200 * size.scale - 4, width: 264, height: 178)
    }
    static func catHitFrame(_ size: DesktopPetSize) -> CGRect {
        CGRect(x: 34 * size.scale, y: 26 * size.scale, width: 132 * size.scale, height: 150 * size.scale)
    }
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            MascotView(controller: mascot).frame(width: 184 * state.desktopPetSize.scale, height: 184 * state.desktopPetSize.scale).padding(8 * state.desktopPetSize.scale)
            if state.desktopPetShowsStatus {
                DesktopPetStatusView(state: state).frame(width: 264, height: 178).offset(x: 8, y: -(200 * state.desktopPetSize.scale - 4))
            }
        }.frame(width: Self.size(showsStatus: state.desktopPetShowsStatus, petSize: state.desktopPetSize).width,
                height: Self.size(showsStatus: state.desktopPetShowsStatus, petSize: state.desktopPetSize).height, alignment: .bottomLeading)
    }
}

final class PetBubbleFeedback: ObservableObject {
    @Published var finished = false
}

struct DesktopPetBubbleView: View {
    @ObservedObject var state: AppState
    @ObservedObject var feedback: PetBubbleFeedback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var count: Int { state.activeSessionCount }
    var body: some View {
        Button { state.desktopPetShowsStatus.toggle() } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if feedback.finished && count == 0 {
                        Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                    } else {
                        Circle().fill(count > 0 ? Theme.working : .secondary).frame(width: 5, height: 5)
                        Text(count > 99 ? "99+" : "\(count)")
                            .fixedSize(horizontal: true, vertical: false)
                            .contentTransition(.numericText())
                    }
                }
                .font(Theme.number(15)).foregroundStyle(Color(nsColor: NSColor(rgb: 0x202923)))
                .frame(minWidth: 30, minHeight: 27).padding(.horizontal, 6)
                .background(Color(nsColor: NSColor(rgb: 0xF6F7F0)), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.85), lineWidth: 0.75))
                Circle().fill(Color(nsColor: NSColor(rgb: 0xF6F7F0))).frame(width: 5, height: 5).padding(.leading, 9)
                Circle().fill(Color(nsColor: NSColor(rgb: 0xF6F7F0))).frame(width: 3, height: 3).padding(.leading, 3)
            }
            .padding(6).contentShape(Rectangle())
            .shadow(color: .black.opacity(0.14), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : Theme.quick, value: count)
        .accessibilityLabel(state.desktopPetShowsStatus ? "收起 AI 工作详情" : "展开 AI 工作详情")
        .accessibilityValue("\(count) 个会话进行中")
        .help("\(count) 个会话进行中 · 点击\(state.desktopPetShowsStatus ? "收起" : "展开")")
    }
}

/// Own the native scroll view so the system's “Always show scroll bars” preference
/// cannot reintroduce a gutter in this compact companion card.
struct PetDetailScroll<Content: View>: NSViewRepresentable {
    let content: Content
    @Binding var hasMoreBelow: Bool
    init(hasMoreBelow: Binding<Bool>, @ViewBuilder content: () -> Content) {
        _hasMoreBelow = hasMoreBelow; self.content = content()
    }
    func makeNSView(context: Context) -> PetDetailScrollView {
        let view = PetDetailScrollView()
        view.onOverflow = { value in
            DispatchQueue.main.async { if hasMoreBelow != value { hasMoreBelow = value } }
        }
        return view
    }
    func updateNSView(_ view: PetDetailScrollView, context: Context) {
        view.setContent(AnyView(content))
    }
}

final class PetDetailScrollView: NSScrollView {
    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    private var content = AnyView(EmptyView())
    private var measuredWidth: CGFloat = -1
    private var boundsObserver: NSObjectProtocol?
    var onOverflow: ((Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        drawsBackground = false; borderType = .noBorder
        hasVerticalScroller = false; hasHorizontalScroller = false
        verticalScrollElasticity = .automatic; horizontalScrollElasticity = .none
        documentView = host
        contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: contentView, queue: .main) { [weak self] _ in self?.reportOverflow() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) } }
    func setContent(_ content: AnyView) {
        self.content = content; measuredWidth = -1; needsLayout = true
    }
    override func layout() {
        super.layout()
        let width = contentView.bounds.width
        guard width > 0 else { return }
        if measuredWidth != width {
            measuredWidth = width
            host.rootView = AnyView(content.frame(width: width, alignment: .leading).fixedSize(horizontal: false, vertical: true))
        }
        host.layoutSubtreeIfNeeded()
        let height = host.fittingSize.height
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        if host.frame != frame { host.frame = frame }
        // Clamp an old scroll offset when running sessions disappear.
        let y = min(max(0, contentView.bounds.minY), max(0, height - contentView.bounds.height))
        if abs(y - contentView.bounds.minY) > 0.5 { contentView.scroll(to: CGPoint(x: 0, y: y)) }
        reflectScrolledClipView(contentView)
        reportOverflow()
    }
    private func reportOverflow() {
        onOverflow?(host.frame.maxY - contentView.bounds.maxY > 1)
    }
}

struct DesktopPetStatusView: View {
    @ObservedObject var state: AppState
    @State private var hasMoreBelow = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    private var secondaryInk: Color { scheme == .dark ? .white.opacity(0.74) : .black.opacity(0.55) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(state.activeSessionCount > 0 ? "\(state.activeSessionCount) 个会话进行中" : "AI 工作状态")
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                Spacer()
                Button { state.desktopPetShowsStatus = false } label: {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(secondaryInk).accessibilityLabel("收起 AI 工作详情")
            }
            PetDetailScroll(hasMoreBelow: $hasMoreBelow) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(WorkSource.allCases) { source in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Circle().fill((state.activeSessionCounts[source] ?? 0) > 0 ? Theme.working : secondaryInk.opacity(0.6))
                                    .frame(width: 5, height: 5).accessibilityHidden(true)
                                Text(source.clientName).font(.system(size: 11, weight: .medium))
                                Spacer()
                                Text(state.desktopPetStatus(for: source)).font(.system(size: 10))
                                    .foregroundStyle(secondaryInk).monospacedDigit()
                            }
                            let sessions = state.desktopWorkSessions.filter { $0.source == source }
                            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                                HStack(spacing: 6) {
                                    Text("会话 \(index + 1)").foregroundStyle(secondaryInk)
                                    Text(session.phase.title).foregroundStyle(Theme.accent)
                                }.font(.system(size: 11)).padding(.leading, 11)
                            }
                            if sessions.isEmpty, let detail = state.workSourceDetails[source], !detail.isEmpty {
                                Text(detail).font(.system(size: 10)).foregroundStyle(secondaryInk)
                                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 11)
                            }
                        }
                    }
                }
            }
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, hasMoreBelow ? .clear : .black],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 22)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hasMoreBelow)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(scheme == .dark ? Color(nsColor: NSColor(rgb: 0x17271F)).opacity(0.65) : .white.opacity(0.08))
                }
        }
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.heroEdge, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 7, y: 3)
    }
}

/// Owns a separate Rive instance so closing the menu cannot pause the desktop cat.
final class DesktopPetController: NSObject {
    let panel: DesktopPetPanel
    let mascot: MascotController
    private let state: AppState
    private let showPanel: () -> Void
    private let showSettings: () -> Void
    private var content: DesktopPetContentView!
    private var subscription: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private var pointerTimer: Timer?
    private var lastReset: UUID
    private var lastCelebration: Int
    private var lastSize: CGSize = .zero
    private let feedback = PetBubbleFeedback()
    private var lastCount = 0
    private var lastActiveSources: Set<WorkSource> = []
    private var lastSources: Set<WorkSource> = []
    private var completionWork: DispatchWorkItem?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var compactOrigin: CGPoint?
    private var isShowingCatch = false
    private var wasResident = false

    init(state: AppState, mascot: MascotController = MascotController(),
         showPanel: @escaping () -> Void = {}, showSettings: @escaping () -> Void = {}) {
        self.state = state; self.mascot = mascot
        self.showPanel = showPanel; self.showSettings = showSettings
        lastReset = state.desktopPetResetID; lastCelebration = state.celebrationSerial
        panel = DesktopPetPanel(contentRect: CGRect(origin: .zero, size: DesktopPetView.size(showsStatus: state.desktopPetShowsStatus, petSize: state.desktopPetSize)),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.title = "桌面小猫"
        panel.setAccessibilityLabel("桌面小猫")
        content = DesktopPetContentView(root: DesktopPetView(state: state, mascot: mascot), feedback: feedback)
        content.onPet = { [weak self] in self?.mascot.pet() }
        content.onMove = { [weak self] origin in self?.move(to: origin) }
        content.onSave = { [weak self] in self?.savePosition() }
        content.makeMenu = { [weak self] in self?.contextMenu() ?? NSMenu() }
        panel.contentView = content
        subscription = state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in self?.restorePosition() }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.dismissOutsideClick()
            return event
        }
        // Mouse-only monitoring needs no Accessibility or Input Monitoring permission.
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismissOutsideClick()
        }
        refresh()
    }

    deinit {
        pointerTimer?.invalidate()
        completionWork?.cancel()
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        panel.orderOut(nil)
    }

    private func refresh() {
        let celebration = state.celebrationSerial != lastCelebration
        lastCelebration = state.celebrationSerial
        let count = state.activeSessionCount
        if count > 0 || lastSources != state.selectedSources || !state.desktopPetEnabled {
            completionWork?.cancel(); feedback.finished = false
        } else if lastCount > 0, !state.activeSessionCounts.isEmpty,
                  lastActiveSources.allSatisfy({ (state.workSourceDetails[$0] ?? "").isEmpty }) {
            feedback.finished = true
            let work = DispatchWorkItem { [weak self] in
                self?.feedback.finished = false
                self?.refresh()
            }
            completionWork?.cancel(); completionWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
        }
        lastCount = count; lastSources = state.selectedSources
        lastActiveSources = Set(state.activeSessionCounts.filter { $0.value > 0 }.map(\.key))
        if !state.desktopPetEnabled && state.desktopPetShowsStatus { state.desktopPetShowsStatus = false }
        let presentedCatch = state.companionCatch(at: ProcessInfo.processInfo.systemUptime)
        let wasShowingCatch = isShowingCatch
        isShowingCatch = presentedCatch != nil
        let residentChanged = wasResident != state.desktopPetEnabled
        wasResident = state.desktopPetEnabled
        guard state.desktopPetEnabled || isShowingCatch else {
            panel.orderOut(nil); mascot.setActive(false)
            pointerTimer?.invalidate(); pointerTimer = nil
            content.cancelDrag()
            if state.desktopPetShowsStatus { state.desktopPetShowsStatus = false }
            return
        }
        let showsDetails = state.desktopPetShowsStatus && !isShowingCatch
        let size = DesktopPetView.size(showsStatus: showsDetails, petSize: state.desktopPetSize)
        let wasVisible = panel.isVisible
        if size != lastSize {
            let origin = panel.frame.origin
            if showsDetails { compactOrigin = origin }
            panel.setContentSize(size); content.frame = CGRect(origin: .zero, size: size)
            if wasVisible { move(to: showsDetails ? origin : compactOrigin ?? origin) }
            if !showsDetails { compactOrigin = nil }
            lastSize = size
        }
        if !wasVisible || residentChanged || wasShowingCatch != isShowingCatch || lastReset != state.desktopPetResetID {
            lastReset = state.desktopPetResetID
            restorePosition()
        }
        content.petSize = state.desktopPetSize
        content.showsStatus = showsDetails
        content.showsBubble = !isShowingCatch && state.desktopPetEnabled && (count > 0 || state.desktopPetShowsStatus || feedback.finished)
        content.setAccessibilityLabel("桌面小猫，" + state.desktopPetHeadline)
        content.setAccessibilityValue(WorkSource.allCases.map { $0.clientName + "，" + state.desktopPetStatus(for: $0) }.joined(separator: "；"))
        content.catchView.update(reward: presentedCatch, coat: state.mascotCoat)
        mascot.set(mood: state.desktopPetMood, coat: state.mascotCoat)
        if !wasVisible || (!wasShowingCatch && isShowingCatch) { panel.orderFrontRegardless() }
        mascot.setActive(panel.occlusionState.contains(.visible))
        if celebration && !isShowingCatch { mascot.celebrate() }
        if pointerTimer == nil {
            // Only the cat and its status card intercept input; the clear surround passes through.
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.updateCompanion() }
            RunLoop.main.add(timer, forMode: .common); pointerTimer = timer
        }
        updateHitRegion()
    }

    private func updateCompanion() {
        let reward = state.companionCatch(at: ProcessInfo.processInfo.systemUptime)
        if (reward != nil) != isShowingCatch { refresh(); return }
        content.catchView.update(reward: reward, coat: state.mascotCoat)
        mascot.setActive(panel.occlusionState.contains(.visible))
        mascot.set(mood: state.desktopPetMood, coat: state.mascotCoat)
        mascot.attention = reward != nil ? .zero : (state.desktopEnabled && state.mode == .fishing &&
            (state.fishing.phase == .waiting || state.fishing.engaged) ? CGPoint(x: 0.45, y: 0.6) : nil)
        updateHitRegion()
    }

    func dismissOutsideClick(at screenPoint: CGPoint? = nil) {
        guard state.desktopPetShowsStatus, panel.isVisible else { return }
        let local = panel.convertPoint(fromScreen: screenPoint ?? NSEvent.mouseLocation)
        if !content.containsInteraction(local) { state.desktopPetShowsStatus = false }
    }

    private func preferredScreen() -> NSScreen? {
        if let saved = state.desktopPetPosition,
           let screen = NSScreen.screens.first(where: { DesktopScreenChoice.id(for: $0) == saved.screenID }) { return screen }
        return NSScreen.screens.first { DesktopScreenChoice.id(for: $0) == String(CGMainDisplayID()) } ?? NSScreen.screens.first
    }

    private func restorePosition() {
        if isShowingCatch, let screen = state.targetScreen ?? preferredScreen() {
            let visible = screen.visibleFrame
            let origin = CGPoint(x: visible.maxX-panel.frame.width-24, y: visible.minY+310)
            panel.setFrameOrigin(DesktopPetPlacement.clamp(origin, size: panel.frame.size, to: visible))
            return
        }
        guard let screen = preferredScreen() else { return }
        panel.setFrameOrigin(DesktopPetPlacement.origin(saved: state.desktopPetPosition, size: DesktopPetView.size(showsStatus: false, petSize: state.desktopPetSize), visible: screen.visibleFrame))
        move(to: panel.frame.origin)
        if state.desktopPetShowsStatus { compactOrigin = panel.frame.origin }
    }

    private func move(to origin: CGPoint) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? panel.screen ?? preferredScreen()
        guard let screen else { return }
        panel.setFrameOrigin(DesktopPetPlacement.clamp(origin, size: panel.frame.size, to: screen.visibleFrame))
    }

    private func savePosition() {
        guard state.desktopPetEnabled, !isShowingCatch else { return }
        guard let screen = panel.screen ?? preferredScreen() else { return }
        if state.desktopPetShowsStatus { compactOrigin = panel.frame.origin }
        let frame = CGRect(origin: panel.frame.origin, size: DesktopPetView.size(showsStatus: false, petSize: state.desktopPetSize))
        state.desktopPetPosition = DesktopPetPlacement.saved(frame: frame, visible: screen.visibleFrame,
                                                             screenID: DesktopScreenChoice.id(for: screen))
    }

    private func updateHitRegion() {
        guard panel.isVisible else { return }
        if isShowingCatch { panel.ignoresMouseEvents = true; return }
        if content.hasActiveGesture { panel.ignoresMouseEvents = false; return }
        let local = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !content.containsInteraction(local)
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        for source in WorkSource.allCases {
            let item = NSMenuItem(title: source.clientName + " · " + state.desktopPetStatus(for: source), action: nil, keyEquivalent: "")
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, action) in [("摸摸小猫", #selector(pet)), ("打开菜单栏面板", #selector(openPanel)),
                                (state.desktopPetShowsStatus ? "收起 AI 工作详情" : "展开 AI 工作详情", #selector(toggleStatus)),
                                ("回到屏幕角落", #selector(resetPosition)), ("设置…", #selector(openSettings)),
                                ("收起桌面小猫", #selector(hide))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        return menu
    }
    @objc private func pet() { mascot.pet() }
    @objc private func openPanel() { showPanel() }
    @objc private func openSettings() { showSettings() }
    @objc private func toggleStatus() { state.desktopPetShowsStatus.toggle() }
    @objc private func resetPosition() { state.resetDesktopPetPosition() }
    @objc private func hide() { state.desktopPetEnabled = false }
}

/// Distinguishes a click from a drag before forwarding petting to Rive.
private final class DesktopPetContentView: NSView {
    var onPet: (() -> Void)?
    var onMove: ((CGPoint) -> Void)?
    var onSave: (() -> Void)?
    var makeMenu: (() -> NSMenu)?
    var petSize: DesktopPetSize = .medium { didSet { if oldValue != petSize { needsLayout = true } } }
    var showsStatus = false {
        didSet {
            guard oldValue != showsStatus else { return }
            statusView.isHidden = !showsStatus
            if showsStatus && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                statusView.alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    statusView.animator().alphaValue = 1
                }
            } else { statusView.alphaValue = 1 }
            needsLayout = true
        }
    }
    var showsBubble = false {
        didSet {
            guard oldValue != showsBubble else { return }
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                bubbleView.isHidden = !showsBubble; bubbleView.alphaValue = 1
                return
            }
            if showsBubble { bubbleView.alphaValue = 0; bubbleView.isHidden = false }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                bubbleView.animator().alphaValue = showsBubble ? 1 : 0
            } completionHandler: { [weak self] in
                guard let self, !self.showsBubble else { return }
                self.bubbleView.isHidden = true
            }
        }
    }
    let catchView = MascotCatchView()
    private let catView: NSView
    private let statusView: NSView
    private let bubbleView: NSView
    private var downPoint: CGPoint?
    private var downOrigin: CGPoint = .zero
    private(set) var isDragging = false
    var hasActiveGesture: Bool { downPoint != nil }

    init(root: DesktopPetView, feedback: PetBubbleFeedback) {
        // Host Metal directly in AppKit. The status material has a separate host,
        // so its SwiftUI compositing cannot flatten the live Rive layer.
        catView = root.mascot.isAvailable ? MascotHostView(controller: root.mascot) : NSHostingView(rootView: MascotView(controller: root.mascot))
        statusView = NSHostingView(rootView: DesktopPetStatusView(state: root.state))
        bubbleView = NSHostingView(rootView: DesktopPetBubbleView(state: root.state, feedback: feedback))
        super.init(frame: CGRect(origin: .zero, size: DesktopPetView.size(showsStatus: root.state.desktopPetShowsStatus, petSize: root.state.desktopPetSize)))
        wantsLayer = true; layer?.backgroundColor = NSColor.clear.cgColor
        clipsToBounds = true
        addSubview(catView); addSubview(catchView); addSubview(statusView); addSubview(bubbleView)
        petSize = root.state.desktopPetSize
        showsStatus = root.state.desktopPetShowsStatus
        layout()
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityHelp("点击摸摸小猫，拖动可移动位置，右键打开菜单。")
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "打开小猫菜单", target: self, selector: #selector(accessibleMenu))])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        catView.frame = DesktopPetView.catFrame(petSize)
        catchView.frame = catView.frame
        statusView.frame = DesktopPetView.cardFrame(petSize)
        statusView.isHidden = !showsStatus
        bubbleView.frame = DesktopPetView.bubbleFrame(petSize)
        bubbleView.isHidden = !showsBubble
    }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if showsBubble && bubbleView.frame.contains(point) {
            return bubbleView.hitTest(point)
        }
        if showsStatus && statusView.frame.contains(point) {
            return statusView.hitTest(point)
        }
        return containsInteraction(point) ? self : nil
    }
    func containsInteraction(_ point: CGPoint) -> Bool {
        let cat = DesktopPetView.catHitFrame(petSize)
        let card = DesktopPetView.cardFrame(petSize)
        return cat.contains(point) || (showsStatus && card.contains(point)) || (showsBubble && bubbleView.frame.contains(point))
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        downPoint = NSEvent.mouseLocation; downOrigin = window?.frame.origin ?? .zero; isDragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint else { return }
        let location = NSEvent.mouseLocation
        let dx = location.x - start.x, dy = location.y - start.y
        if hypot(dx, dy) > 4 { isDragging = true }
        if isDragging { onMove?(CGPoint(x: downOrigin.x + dx, y: downOrigin.y + dy)) }
    }
    override func mouseUp(with event: NSEvent) {
        guard downPoint != nil else { return }
        if isDragging { onSave?() } else { onPet?() }
        cancelDrag()
    }
    func cancelDrag() { downPoint = nil; isDragging = false }
    override func rightMouseDown(with event: NSEvent) {
        cancelDrag()
        if let menu = makeMenu?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
    override func accessibilityPerformPress() -> Bool { onPet?(); return true }
    @objc private func accessibleMenu() -> Bool {
        guard let menu = makeMenu?() else { return false }
        menu.popUp(positioning: nil, at: CGPoint(x: bounds.midX, y: bounds.midY), in: self)
        return true
    }
}

/// One fixed cartoon celebration fish sits between the paws above the live Rive chest.
final class MascotCatchView: NSView {
    private var reward: AppState.FishingReward?
    private var coat: MascotCoat = .ink
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func update(reward: AppState.FishingReward?, coat: MascotCoat) {
        let changed = self.reward?.caughtAt != reward?.caughtAt || self.coat != coat
        self.reward = reward; self.coat = coat
        isHidden = reward == nil
        setAccessibilityElement(reward != nil); setAccessibilityRole(.image)
        if let reward { setAccessibilityLabel(reward.catchResult.species.isFish ? "小猫举起卡通小鱼庆祝" : "小猫抱着" + reward.catchResult.species.name) }
        if changed || reward != nil { needsDisplay = true }
    }
    /// A small vector prop, shared by every fish species. Actual species remain on the reward card.
    static func drawCelebrationFish(in rect: CGRect, context c: CGContext) {
        c.saveGState(); defer { c.restoreGState() }
        c.translateBy(x: rect.minX, y: rect.minY)
        c.scaleBy(x: rect.width/100, y: rect.height/52)
        let tail = CGMutablePath()
        tail.move(to: CGPoint(x: 29,y: 26))
        tail.addCurve(to: CGPoint(x: 3,y: 45), control1: CGPoint(x: 17,y: 39), control2: CGPoint(x: 4,y: 49))
        tail.addQuadCurve(to: CGPoint(x: 6,y: 26), control: CGPoint(x: 0,y: 38))
        tail.addQuadCurve(to: CGPoint(x: 3,y: 7), control: CGPoint(x: 0,y: 13))
        tail.addCurve(to: CGPoint(x: 29,y: 26), control1: CGPoint(x: 4,y: 3), control2: CGPoint(x: 17,y: 13))
        tail.closeSubpath()
        c.setFillColor(NSColor(srgbRed:0.45,green:0.68,blue:0.57,alpha:1).cgColor)
        c.addPath(tail); c.fillPath()
        let fin = CGMutablePath()
        fin.move(to: CGPoint(x: 39,y: 40))
        fin.addQuadCurve(to: CGPoint(x: 57,y: 50), control: CGPoint(x: 43,y: 53))
        fin.addQuadCurve(to: CGPoint(x: 70,y: 41), control: CGPoint(x: 66,y: 49))
        fin.closeSubpath(); c.addPath(fin); c.fillPath()
        let body = CGPath(ellipseIn: CGRect(x: 20,y: 7,width: 77,height: 38), transform:nil)
        c.saveGState(); c.setShadow(offset:CGSize(width:0,height:-1),blur:2,color:NSColor.black.withAlphaComponent(0.12).cgColor)
        c.setFillColor(NSColor(srgbRed:0.77,green:0.86,blue:0.71,alpha:1).cgColor); c.addPath(body); c.fillPath(); c.restoreGState()
        c.saveGState(); c.addPath(body); c.clip()
        InteractionArtwork.gradient([NSColor(srgbRed:0.98,green:0.92,blue:0.73,alpha:1),
            NSColor(srgbRed:0.61,green:0.79,blue:0.66,alpha:1)],from:CGPoint(x:55,y:8),to:CGPoint(x:55,y:45),context:c)
        c.restoreGState()
        c.setFillColor(NSColor(srgbRed:0.14,green:0.24,blue:0.21,alpha:1).cgColor)
        c.fillEllipse(in:CGRect(x:78,y:26,width:7,height:8))
        c.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        c.fillEllipse(in:CGRect(x:79.5,y:30,width:2,height:2))
        c.setLineWidth(1.4); c.setLineCap(.round)
        c.setStrokeColor(NSColor(srgbRed:0.33,green:0.51,blue:0.40,alpha:0.6).cgColor)
        c.move(to:CGPoint(x:69,y:31)); c.addQuadCurve(to:CGPoint(x:67,y:18),control:CGPoint(x:63,y:25)); c.strokePath()
        c.setFillColor(NSColor(srgbRed:0.87,green:0.68,blue:0.55,alpha:0.45).cgColor)
        c.fillEllipse(in:CGRect(x:77,y:19,width:8,height:4))
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let reward, let c = NSGraphicsContext.current?.cgContext else { return }
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let age = max(0, ProcessInfo.processInfo.systemUptime - reward.caughtAt)
        let duration = AppState.FishingReward.duration
        let entry = reduced ? 1 : 1 - pow(1 - min(1, age / 0.45), 3)
        let alpha = reduced ? 1 : min(min(1, age / 0.12), max(0, (duration-age) / 0.2))
        let side = bounds.width
        let width = side * (reward.catchResult.species.isFish ? 0.62 : 0.33)
        let height = side * 0.28
        c.saveGState(); defer { c.restoreGState() }
        c.setAlpha(alpha)
        c.translateBy(x: bounds.midX, y: side * 0.42 - (1-entry) * side * 0.19)
        if !reduced { c.rotate(by: sin(age * 2) * 0.025 * min(1, age)) }
        let rect = CGRect(x: -width/2, y: -height/2, width: width, height: height)
        if reward.catchResult.species.isFish {
            Self.drawCelebrationFish(in: rect, context: c)
        } else {
            if reward.catchResult.species.id == "can" {
                let can = rect.insetBy(dx: width * 0.13, dy: height * 0.12)
                let shape = CGPath(roundedRect: can, cornerWidth: 4, cornerHeight: 4, transform: nil)
                c.saveGState(); c.addPath(shape); c.clip()
                InteractionArtwork.gradient([NSColor(srgbRed: 0.56, green: 0.65, blue: 0.63, alpha: 1),
                    NSColor(srgbRed: 0.88, green: 0.91, blue: 0.85, alpha: 1), NSColor(srgbRed: 0.46, green: 0.56, blue: 0.54, alpha: 1)],
                    from: CGPoint(x: can.minX,y: 0), to: CGPoint(x: can.maxX,y: 0), context: c)
                c.restoreGState()
                c.setFillColor(NSColor(srgbRed: 0.35, green: 0.44, blue: 0.41, alpha: 1).cgColor)
                c.fillEllipse(in: CGRect(x: can.minX,y: can.maxY-8,width: can.width,height: 8))
                c.setLineWidth(1); c.setStrokeColor(NSColor.white.withAlphaComponent(0.5).cgColor)
                for f: CGFloat in [0.18, 0.33, 0.65] {
                    c.move(to: CGPoint(x: can.minX+2,y: can.minY+can.height*f)); c.addLine(to: CGPoint(x: can.maxX-2,y: can.minY+can.height*f)); c.strokePath()
                }
            } else if let symbol = NSImage(systemSymbolName: reward.catchResult.species.symbol, accessibilityDescription: reward.catchResult.species.name) {
                let tint = NSColor(calibratedHue: reward.catchResult.species.hue, saturation: 0.35, brightness: 0.67, alpha: 1)
                let configured = symbol.withSymbolConfiguration(.init(paletteColors: [tint])) ?? symbol
                let ratio = min(rect.width/configured.size.width,rect.height/configured.size.height)
                let size = CGSize(width: configured.size.width*ratio,height: configured.size.height*ratio)
                configured.draw(in: CGRect(x: -size.width/2,y: -size.height/2,width: size.width,height: size.height))
            }
        }
        // Tiny forepaws overlap the fish's lower edge, visibly supporting its weight.
        for sign: CGFloat in [-1, 1] {
            c.saveGState(); c.translateBy(x: sign * width * 0.25, y: -height * 0.22)
            c.scaleBy(x: side / 610, y: side / 610)
            InteractionArtwork.paw(at: .zero, pressure: 0.8, angle: -sign * 0.2, snow: coat == .snow, pads: false, context: c)
            c.restoreGState()
        }
    }
}
