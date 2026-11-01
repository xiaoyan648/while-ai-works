import AppKit
import Combine
import SwiftUI

final class QuickInputPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        TextEditingMenu.performKeyEquivalent(with: event, in: self) || super.performKeyEquivalent(with: event)
    }
}

/// Keys that belong to the panel. While an input method is composing, everything goes to
/// it first: Return only commits the candidate and can never send.
final class QuickInputTextView: NSTextView {
    weak var model: QuickInputModel?
    var onEscape: () -> Void = {}
    override func keyDown(with event: NSEvent) {
        guard let model, !hasMarkedText() else { super.keyDown(with: event); return }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        switch Int(event.keyCode) {
        case 36, 76:
            if modifiers == .shift { insertText("\n", replacementRange: selectedRange()) }
            else { model.submit(alternate: modifiers == .command) }
        case 53:
            if model.pickerVisible { model.closePicker() } else { onEscape() }
        case 48 where modifiers.isEmpty:
            if model.pickerVisible { model.pickSelected() } else { model.togglePicker(.target) }
        case 125 where model.pickerVisible: model.moveSelection(1)
        case 126 where model.pickerVisible: model.moveSelection(-1)
        default: super.keyDown(with: event)
        }
    }
}

struct QuickInputEditor: NSViewRepresentable {
    @ObservedObject var model: QuickInputModel
    @Binding var height: CGFloat
    let focusRequest: Int
    let onEscape: () -> Void
    static let font = NSFont.systemFont(ofSize: 19)
    static var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) + 3 }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let text = QuickInputTextView(frame: .zero)
        text.model = model; text.delegate = context.coordinator
        text.isRichText = false; text.allowsUndo = true; text.drawsBackground = false
        text.font = Self.font; text.textColor = .labelColor; text.insertionPointColor = Theme.accentColor
        let paragraph = NSMutableParagraphStyle(); paragraph.minimumLineHeight = Self.lineHeight; paragraph.maximumLineHeight = Self.lineHeight
        text.defaultParagraphStyle = paragraph
        text.typingAttributes = [.font: Self.font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false; text.isAutomaticSpellingCorrectionEnabled = false
        text.textContainerInset = .zero; text.textContainer?.lineFragmentPadding = 0
        text.isHorizontallyResizable = false; text.isVerticallyResizable = true
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.string = model.draft
        text.setAccessibilityLabel("要交给 Agent 的内容")
        text.setAccessibilityIdentifier("quick-input-text")
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay; scroll.borderType = .noBorder
        scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? QuickInputTextView else { return }
        text.onEscape = onEscape
        if context.coordinator.revision != model.draftRevision {
            context.coordinator.revision = model.draftRevision
            if text.string != model.draft, !text.hasMarkedText() {
                text.string = model.draft
                text.setSelectedRange(NSRange(location: (model.draft as NSString).length, length: 0))
            }
        }
        if context.coordinator.focus != focusRequest {
            context.coordinator.focus = focusRequest
            DispatchQueue.main.async {
                text.window?.makeFirstResponder(text)
                text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
            }
        }
        DispatchQueue.main.async { context.coordinator.measure(text) }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: QuickInputEditor
        var revision = -1
        var focus = -1
        init(_ parent: QuickInputEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? NSTextView else { return }
            parent.model.textChanged(text.string, cursor: text.selectedRange().location)
            measure(text)
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let text = notification.object as? NSTextView, text.string == parent.model.draft else { return }
            parent.model.cursorMoved(text.selectedRange().location)
        }
        func measure(_ text: NSTextView) {
            guard let manager = text.layoutManager, let container = text.textContainer else { return }
            manager.ensureLayout(for: container)
            let line = QuickInputEditor.lineHeight
            let wanted = min(line * 6, max(line, ceil(manager.usedRect(for: container).height)))
            if parent.height != wanted { parent.height = wanted }
        }
    }
}

struct QuickInputKeyCap: View {
    let key: String
    var primary = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Text(key).font(.system(size: 12, weight: primary ? .semibold : .medium))
            .foregroundStyle(primary ? (scheme == .dark ? Theme.accentBadgeInk : .white) : Color.primary.opacity(0.72))
            .frame(minWidth: 20, minHeight: 20)
            .padding(.horizontal, key.count > 1 ? 4 : 0)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(primary ? Theme.accent : Theme.wellStrong))
    }
}

private struct QuickInputHoverFill: ViewModifier {
    var radius: CGFloat = 7
    @State private var hovered = false
    func body(content: Content) -> some View {
        content.background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(hovered ? Theme.well : .clear)).onHover { hovered = $0 }
    }
}

struct QuickInputView: View {
    @ObservedObject var model: QuickInputModel
    @ObservedObject var state: AppState
    let focusRequest: Int
    let onEscape: () -> Void
    @State private var editorHeight = QuickInputEditor.lineHeight
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let warning = model.warning {
                Text(warning).font(.system(size: 13)).foregroundStyle(Theme.attention)
                    .padding(.horizontal, 18).padding(.top, 11)
            }
            ZStack(alignment: .topLeading) {
                if model.draft.isEmpty {
                    Text("要做什么？  @ 选谁   # 选项目").font(.system(size: 19)).foregroundStyle(.secondary).allowsHitTesting(false)
                }
                QuickInputEditor(model: model, height: $editorHeight, focusRequest: focusRequest, onEscape: onEscape)
                    .frame(height: editorHeight)
            }
            .padding(.horizontal, 18).padding(.top, 15).padding(.bottom, 13)
            if model.pickerVisible { list }
            footer
        }
        .frame(width: 640)
        .overlay {
            RoundedRectangle(cornerRadius: QuickInputController.cornerRadius, style: .continuous)
                .strokeBorder(LinearGradient(colors: scheme == .dark ? [.white.opacity(0.22), .white.opacity(0.1)] : [.white.opacity(0.75), .black.opacity(0.1)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
    }

    private var list: some View {
        let rows = model.rows
        let headers = rows.filter { $0.section != nil }.count
        let wanted = CGFloat(rows.count) * 40 + CGFloat(headers) * 25 + 12 + (model.pickerNote == nil ? 0 : 30)
        return VStack(spacing: 0) {
            Rectangle().fill(.separator).frame(height: 0.5)
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let note = model.pickerNote {
                            Text(note).font(.system(size: 13)).foregroundStyle(Theme.attention).padding(.horizontal, 10).padding(.vertical, 7)
                        }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if let section = row.section {
                                Text(section).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 3).frame(height: 25, alignment: .bottomLeading)
                            }
                            rowView(row, selected: index == model.selection).id(row.id)
                        }
                    }
                    .padding(6)
                }
                .scrollIndicators(.never)
                .onChange(of: model.selection) { _, selection in
                    if rows.indices.contains(selection) { reader.scrollTo(rows[selection].id) }
                }
            }
            .frame(height: min(300, wanted))
        }
    }

    private func rowView(_ row: QuickInputRow, selected: Bool) -> some View {
        Button { model.pick(row) } label: {
            HStack(spacing: 10) {
                Group {
                    if let source = row.source { AgentMark(source: source, size: 22).opacity(row.enabled ? 1 : 0.45) }
                    else { Image(systemName: row.kind == .browse ? "folder" : "number").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).frame(width: 22, height: 22) }
                }
                Text(row.title).font(.system(size: 14, weight: .medium)).lineLimit(1).layoutPriority(1)
                    .foregroundStyle(row.enabled ? Color.primary : Color.secondary)
                Text(row.subtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(row.trailing).font(.system(size: 12)).lineLimit(1).fixedSize()
                    .foregroundStyle(row.tone == .working ? Theme.accent : row.tone == .attention ? Theme.attention : Color.secondary)
            }
            .padding(.horizontal, 10).frame(height: 40).contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? Theme.wellStrong : .clear))
        }
        .buttonStyle(.plain).focusable(false)
        .modifier(QuickInputHoverFill(radius: 9))
        .accessibilityIdentifier("quick-input-row-" + row.id)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                sentence
                if let hint = model.hint, !model.pickerVisible {
                    Text(hint).font(.system(size: 12)).foregroundStyle(model.notice == nil ? Color.secondary : Theme.attention)
                        .lineLimit(2).padding(.horizontal, 3).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if let secondary = model.secondaryVerb {
                action(secondary, keys: ["⌘", "↵"], primary: false) { model.submit(alternate: true) }
                    .accessibilityIdentifier("quick-input-secondary")
            }
            action(model.primaryVerb, keys: ["↵"], primary: true) { model.submit() }
                .accessibilityIdentifier("quick-input-primary")
        }
        .frame(minHeight: 48)
        .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 3)
        .background(Theme.well.opacity(0.5))
        .overlay(alignment: .top) { Rectangle().fill(.separator).frame(height: 0.5) }
    }

    private func action(_ title: String, keys: [String], primary: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 7) {
                Text(title).font(.system(size: 13, weight: primary ? .semibold : .medium))
                    .foregroundStyle(primary ? Color.primary : Color.primary.opacity(0.76)).lineLimit(1).fixedSize()
                HStack(spacing: 3) { ForEach(keys, id: \.self) { QuickInputKeyCap(key: $0, primary: primary) } }
            }
            .padding(.leading, 10).padding(.trailing, 6).frame(height: 34).contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusable(false).modifier(QuickInputHoverFill(radius: 8))
    }

    @ViewBuilder private var sentence: some View {
        if model.pickerVisible {
            HStack(spacing: 12) { word("↑↓ 移动"); word("esc 返回") }.padding(.horizontal, 3)
        } else if let session = model.targetSession {
            HStack(spacing: 3) {
                word("继续")
                segment(session.title, source: session.source, filled: true) { model.togglePicker(.target) }
                if let path = QuickInputCatalog.path(of: session) { word(QuickInputProject(path: path).name + " ·") }
                Text(session.running ? "运行中" : "空闲").font(.system(size: 13)).foregroundStyle(session.running ? Theme.accent : Color.secondary)
                Button(action: model.clearSessionTarget) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).focusable(false).modifier(QuickInputHoverFill(radius: 6))
                .help("改回新任务").accessibilityLabel("改回新任务")
            }
        } else {
            HStack(spacing: 3) {
                word("交给")
                segment(model.targetAgent?.clientName ?? "选择 Agent", source: model.targetAgent, filled: model.targetAgent != nil) { model.togglePicker(.target) }
                word("在")
                segment(model.project?.name ?? "选择项目", source: nil, filled: model.project != nil) { model.togglePicker(.project) }
                word("开新任务")
            }
        }
    }
    private func word(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(.secondary).padding(.horizontal, 3).fixedSize()
    }
    private func segment(_ title: String, source: WorkSource?, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let source { AgentMark(source: source, size: 15) }
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1).frame(maxWidth: 180, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).opacity(0.6)
            }
            .foregroundStyle(filled ? Color.primary : Theme.attention)
            .padding(.horizontal, 6).frame(height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusable(false).modifier(QuickInputHoverFill())
    }
}

struct QuickInputReceiptView: View {
    let receipt: QuickInputReceipt
    let perform: (QuickInputReceipt.Action) -> Void
    @Environment(\.colorScheme) private var scheme
    private var titleColor: Color {
        switch receipt.tone {
        case .success: return Theme.accent
        case .warning: return Theme.attention
        case .failure: return Color(nsColor: .adaptive(light: 0xB4472B, dark: 0xF0A08A))
        case .progress, .handedOff: return .primary
        }
    }
    private func label(_ action: QuickInputReceipt.Action) -> String {
        switch action {
        case .open: return "回到会话"
        case .restore: return "打开草稿"
        case .cancelQueue: return "取消排队"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(receipt.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(titleColor)
            Text(receipt.body).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            if !receipt.actions.isEmpty {
                HStack(spacing: 4) {
                    ForEach(receipt.actions.indices, id: \.self) { index in
                        Button { perform(receipt.actions[index]) } label: {
                            Text(label(receipt.actions[index])).font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 8).frame(height: 30).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).modifier(QuickInputHoverFill())
                    }
                }
                .padding(.top, 6).padding(.leading, -8)
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 13)
        .frame(width: 310, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: QuickInputController.cornerRadius, style: .continuous)
                .strokeBorder(scheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.1), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
    }
}

/// The panel, its receipt and the note that flies between them. Nothing here activates
/// WAW, so the app the user was in keeps the menu bar and gets its focus back on close.
final class QuickInputController: NSObject {
    static let cornerRadius: CGFloat = 16
    static let glass = NSVisualEffectView.Material.hudWindow
    let model: QuickInputModel
    let panel: QuickInputPanel
    private let state: AppState
    private let tileCenter: (WorkSource) -> CGPoint?
    private let dockFrame: () -> CGRect?
    private let host: NSHostingView<AnyView>
    private let focus = QuickInputFocusBox()
    private let receiptPanel: DesktopPetPanel
    private var receiptHide: DispatchWorkItem?
    private var flightWindow: NSPanel?
    private var subscriptions: Set<AnyCancellable> = []
    private var mouseMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var frameObserver: NSObjectProtocol?
    private var choosingDirectory = false
    private(set) var isShown = false
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(state: AppState, environment: QuickInputEnvironment = QuickInputEnvironment(),
         tileCenter: @escaping (WorkSource) -> CGPoint?, dockFrame: @escaping () -> CGRect?) {
        self.state = state; self.tileCenter = tileCenter; self.dockFrame = dockFrame
        var environment = environment
        let chooser = QuickInputDirectoryChooser()
        environment.chooseDirectory = { chooser.choose?() }
        model = QuickInputModel(state: state, environment: environment)
        panel = QuickInputPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 76),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        receiptPanel = DesktopPetPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let model = model, focus = focus
        var escape: () -> Void = {}
        host = NSHostingView(rootView: AnyView(QuickInputFocusReader(focus: focus) { request in
            QuickInputView(model: model, state: state, focusRequest: request, onEscape: { escape() })
        }.fixedSize()))
        super.init()
        escape = { [weak self] in self?.dismiss() }
        chooser.choose = { [weak self] in self?.chooseDirectory() }
        configure(panel, level: 2)
        panel.setAccessibilityLabel("快捷输入")
        panel.onCancel = { [weak self] in self?.dismiss() }
        panel.contentView = Self.material(containing: host)
        host.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: host, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.fitToContent(animated: true) }
        }
        configure(receiptPanel, level: 3)
        receiptPanel.allowsKeyboard = false
        receiptPanel.setAccessibilityLabel("快捷输入回执")
        model.onDismiss = { [weak self] in self?.dismiss() }
        model.onDispatch = { [weak self] source, text, finish in
            guard let self else { finish(); return }
            self.fly(text, source: source, finish: finish)
        }
        state.quickInputSummon.receive(on: RunLoop.main).sink { [weak self] in self?.toggle() }.store(in: &subscriptions)
        model.$receipt.dropFirst().receive(on: RunLoop.main).sink { [weak self] in self?.showReceipt($0) }.store(in: &subscriptions)
    }
    deinit {
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        removeMonitors()
    }

    private func configure(_ panel: NSPanel, level: Int) {
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false; panel.animationBehavior = .none
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + level)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }
    private static func material(containing host: NSView) -> NSVisualEffectView {
        let material = NSVisualEffectView()
        material.material = glass; material.state = .active; material.blendingMode = .behindWindow
        material.maskImage = MenuBarPanelController.roundedMask(radius: cornerRadius)
        host.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(host)
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: material.leadingAnchor), host.topAnchor.constraint(equalTo: material.topAnchor)])
        return material
    }

    func toggle() { if isShown { dismiss() } else { show() } }

    func show() {
        guard !isShown else { panel.makeKeyAndOrderFront(nil); return }
        isShown = true
        model.prepareForSummon()
        panel.appearance = state.desktopCompanionAppearance.native
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize.width > 0 ? host.fittingSize : panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let origin = CGPoint(x: visible.midX - size.width / 2, y: visible.maxY - visible.height * 0.2 - size.height)
        let settled = CGRect(origin: origin, size: size)
        panel.setFrame(reduceMotion ? settled : settled.offsetBy(dx: 0, dy: 6), display: true)
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        focus.request += 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.08 : 0.18
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(settled, display: true)
        }
        installMonitors()
    }

    func dismiss() {
        guard isShown else { return }
        isShown = false
        removeMonitors()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduceMotion ? 0.06 : 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.isShown else { return }
            self.panel.orderOut(nil)
        })
    }

    private func fitToContent(animated: Bool) {
        let size = host.fittingSize
        guard isShown, size.width > 0, size.height > 0, size != panel.frame.size else { return }
        var frame = panel.frame
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        if animated && !reduceMotion {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                panel.animator().setFrame(frame, display: true)
            }, completionHandler: { [weak self] in self?.panel.invalidateShadow() })
        } else {
            panel.setFrame(frame, display: true); panel.invalidateShadow()
        }
    }

    private func installMonitors() {
        removeMonitors()
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in self?.dismiss() }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            guard let self, !self.choosingDirectory else { return }
            self.dismiss()
        }
    }
    private func removeMonitors() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    /// The system file chooser needs WAW active; focus returns to the panel afterwards.
    private func chooseDirectory() -> String? {
        choosingDirectory = true
        defer { choosingDirectory = false }
        let open = NSOpenPanel()
        open.canChooseDirectories = true; open.canChooseFiles = false; open.allowsMultipleSelection = false
        open.prompt = "选择项目"
        NSApp.activate(ignoringOtherApps: true)
        let answer = open.runModal() == .OK ? open.url?.path : nil
        panel.makeKeyAndOrderFront(nil)
        focus.request += 1
        return answer
    }

    /// The note leaves the panel's middle and lands on the agent's tile, which is where
    /// the user should look next. Without a visible tile on this screen it simply arrives.
    private func fly(_ text: String, source: WorkSource, finish: @escaping () -> Void) {
        let start = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        guard !reduceMotion, let end = tileCenter(source),
              let screen = NSScreen.screens.first(where: { $0.frame.contains(start) }), screen.frame.contains(end) else { finish(); return }
        let scale = screen.backingScaleFactor
        let dark = panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let rendered: CGImage? = MainActor.assumeIsolated {
            let note = ImageRenderer(content: QuickInputNote(text: text, source: source).environment(\.colorScheme, dark ? .dark : .light))
            note.scale = scale
            return note.cgImage
        }
        guard let image = rendered else { finish(); return }
        let overlay = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configure(overlay, level: 4)
        overlay.hasShadow = false; overlay.ignoresMouseEvents = true
        let root = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        root.wantsLayer = true
        overlay.contentView = root
        let layer = CALayer()
        layer.contents = image; layer.contentsScale = scale
        layer.bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let from = CGPoint(x: start.x - screen.frame.minX, y: start.y - screen.frame.minY)
        let to = CGPoint(x: end.x - screen.frame.minX, y: end.y - screen.frame.minY)
        layer.position = from
        root.layer?.addSublayer(layer)
        overlay.orderFrontRegardless()
        flightWindow = overlay
        let path = CGMutablePath()
        path.move(to: from)
        path.addQuadCurve(to: to, control: CGPoint(x: from.x + (to.x - from.x) * 0.45, y: max(from.y, to.y) + 56))
        let position = CAKeyframeAnimation(keyPath: "position"); position.path = path; position.calculationMode = .paced
        let size = CABasicAnimation(keyPath: "transform.scale"); size.fromValue = 1; size.toValue = 0.16
        let fade = CAKeyframeAnimation(keyPath: "opacity"); fade.values = [1, 1, 0]; fade.keyTimes = [0, 0.72, 1]
        let group = CAAnimationGroup(); group.animations = [position, size, fade]; group.duration = 0.46
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0.05, 0.3, 1)
        group.fillMode = .forwards; group.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.flightWindow?.orderOut(nil); self?.flightWindow = nil
            finish()
        }
        layer.add(group, forKey: "flight")
        CATransaction.commit()
    }

    private func showReceipt(_ receipt: QuickInputReceipt?) {
        receiptHide?.cancel(); receiptHide = nil
        guard let receipt else { hideReceipt(); return }
        receiptPanel.appearance = state.desktopCompanionAppearance.native
        let view = NSHostingView(rootView: QuickInputReceiptView(receipt: receipt, perform: { [weak self] in self?.model.perform($0) }).fixedSize())
        receiptPanel.contentView = Self.material(containing: view)
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        let wasVisible = receiptPanel.isVisible && receiptPanel.alphaValue > 0
        let settled = receiptFrame(size: size)
        let edgeOffset: CGFloat = dockFrame() == nil || reduceMotion ? 0 : state.desktopDockEdge == .right ? 14 : state.desktopDockEdge == .left ? -14 : 0
        receiptPanel.setFrame(wasVisible ? settled : settled.offsetBy(dx: edgeOffset, dy: 0), display: true)
        receiptPanel.contentView?.frame = NSRect(origin: .zero, size: size)
        if !wasVisible { receiptPanel.alphaValue = 0 }
        receiptPanel.orderFrontRegardless()
        receiptPanel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.08 : 0.26
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.1, 0.4, 1)
            receiptPanel.animator().alphaValue = 1
            receiptPanel.animator().setFrame(settled, display: true)
        }
        guard !receipt.lingers, !receipt.pending else { return }
        let hide = DispatchWorkItem { [weak self] in self?.model.dismissReceipt() }
        receiptHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: hide)
    }
    private func hideReceipt() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            receiptPanel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.model.receipt == nil else { return }
            self.receiptPanel.orderOut(nil)
        })
    }
    private func receiptFrame(size: CGSize) -> CGRect {
        let gap: CGFloat = 10
        guard let dock = dockFrame() else {
            let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            return CGRect(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16, width: size.width, height: size.height)
        }
        let visible = (NSScreen.screens.first { $0.frame.intersects(dock) } ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        var origin: CGPoint
        switch state.desktopDockEdge {
        case .right: origin = CGPoint(x: dock.minX - size.width - gap, y: dock.midY - size.height / 2)
        case .left: origin = CGPoint(x: dock.maxX + gap, y: dock.midY - size.height / 2)
        case .top: origin = CGPoint(x: dock.midX - size.width / 2, y: dock.minY - size.height - gap)
        case .bottom: origin = CGPoint(x: dock.midX - size.width / 2, y: dock.maxY + gap)
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        return CGRect(origin: origin, size: size)
    }
}

private final class QuickInputDirectoryChooser {
    var choose: (() -> String?)?
}

final class QuickInputFocusBox: ObservableObject {
    @Published var request = 0
}

private struct QuickInputFocusReader<Content: View>: View {
    @ObservedObject var focus: QuickInputFocusBox
    @ViewBuilder let content: (Int) -> Content
    var body: some View { content(focus.request) }
}

/// The small label the outgoing text folds into on its way to the dock.
private struct QuickInputNote: View {
    let text: String
    let source: WorkSource
    var body: some View {
        HStack(spacing: 8) {
            AgentMark(source: source, size: 20)
            Text(text.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 13)).lineLimit(1).frame(maxWidth: 170, alignment: .leading)
        }
        .padding(.horizontal, 12).frame(height: 40)
        .background(Capsule().fill(Theme.surface))
        .padding(12)
    }
}
