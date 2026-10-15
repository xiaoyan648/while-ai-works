import AppKit
import SwiftUI
import CoreText

/// An anchored, read-only hover tooltip. No title bar, resizing, pinning or keyboard focus.
final class AgentReplyPreviewController {
    let panel: DesktopPetPanel
    private(set) var source: WorkSource?
    private(set) var replyText: String?
    private weak var anchor: NSView?
    private var work: DispatchWorkItem?
    private var pointerInside = false
    var didHide: () -> Void = {}
    init() {
        panel = DesktopPetPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true; panel.level = .popUpMenu
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        panel.allowsKeyboard = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setAccessibilityLabel("完整回复悬停预览")
    }
    func show(_ session: AgentDockSession, from anchor: NSView) {
        guard let reply = session.reply, !reply.isEmpty, anchor.window?.isVisible == true else { return }
        work?.cancel()
        let work = DispatchWorkItem { [weak self, weak anchor] in
            guard let self, let anchor, let window = anchor.window, window.isVisible else { return }
            self.anchor = anchor; self.source = session.source; self.replyText = reply
            let marker = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? marker.insetBy(dx: -500, dy: -400)
            let width = min(360, max(160, visible.width - 24))
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 3
            let contentHeight = (reply as NSString).boundingRect(with: CGSize(width: width - 24, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 12), .paragraphStyle: paragraph]).height
            let height = min(max(48, ceil(contentHeight) + 24), min(300, visible.height - 24))
            var origin = CGPoint(x: marker.minX - width - 6, y: marker.maxY - height)
            if origin.x < visible.minX + 12 { origin.x = marker.maxX + 6 }
            origin.x = min(max(origin.x, visible.minX + 12), visible.maxX - width - 12)
            origin.y = min(max(origin.y, visible.minY + 12), visible.maxY - height - 12)
            self.panel.appearance = window.appearance
            self.panel.contentView = ReplyPreviewHost(reply: reply, onHover: { [weak self] inside in
                self?.pointerInside = inside
                if inside { self?.work?.cancel() } else { self?.hideAfterDelay() }
            })
            self.panel.setFrame(CGRect(origin: origin, size: CGSize(width: width, height: height)), display: true)
            self.panel.orderFrontRegardless()
        }
        self.work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
    func hideAfterDelay() {
        work?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.pointerInside else { return }
            // The pointer may already have crossed into the tooltip before its tracking event arrived.
            guard !self.panel.isVisible || !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.dismiss()
        }
        self.work = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }
    func dismiss() {
        let wasVisible = panel.isVisible
        work?.cancel(); work = nil; pointerInside = false
        panel.orderOut(nil); panel.contentView = nil
        source = nil; replyText = nil; anchor = nil
        if wasVisible { didHide() }
    }
    deinit { work?.cancel(); panel.orderOut(nil) }
}

/// The ellipsis is part of the last typeset line, not a separate control column.
struct AgentReplySummary: NSViewRepresentable {
    let session: AgentDockSession
    let show: (AgentDockSession, NSView) -> Void
    let hide: () -> Void
    func makeNSView(context: Context) -> ReplySummaryView { ReplySummaryView(session: session, show: show, hide: hide) }
    func updateNSView(_ view: ReplySummaryView, context: Context) { view.configure(session: session, show: show, hide: hide) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ReplySummaryView, context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? 300)
        return CGSize(width: width, height: nsView.summaryHeight(width: width))
    }
}

final class ReplySummaryView: NSView {
    private var session: AgentDockSession
    private var show: (AgentDockSession, NSView) -> Void
    private var hide: () -> Void
    private let font = NSFont.systemFont(ofSize: 11)
    private let ellipsisAttribute = NSAttributedString.Key("AgentReplyEllipsis")
    private let anchor = ReplyEllipsisAnchor()
    private var pointerInside = false
    private(set) var ellipsisRect: CGRect?
    private var summary: String { (session.reply ?? "").split(whereSeparator: \.isNewline).joined(separator: " ") }
    private var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) }
    override var isFlipped: Bool { true }
    init(session: AgentDockSession, show: @escaping (AgentDockSession, NSView) -> Void, hide: @escaping () -> Void) {
        self.session = session; self.show = show; self.hide = hide
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
        setAccessibilityIdentifier("agent-reply-summary")
        addSubview(anchor); configure(session: session, show: show, hide: hide)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(session: AgentDockSession, show: @escaping (AgentDockSession, NSView) -> Void, hide: @escaping () -> Void) {
        if self.session.reply != session.reply || self.session.id != session.id || self.session.source != session.source {
            if pointerInside { hide(); pointerInside = false }
        }
        self.session = session; self.show = show; self.hide = hide
        setAccessibilityValue(session.reply ?? "")
        anchor.press = { [weak self] in guard let self, self.ellipsisRect != nil else { return false }
            self.show(self.session, self.anchor); return true
        }
        needsDisplay = true; needsLayout = true; invalidateIntrinsicContentSize()
    }
    private func lines(width: CGFloat) -> [CTLine] {
        guard width > 0, !summary.isEmpty else { return [] }
        let color = NSColor.secondaryLabelColor.usingColorSpace(.deviceRGB) ?? .gray
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let text = NSAttributedString(string: summary, attributes: attributes)
        let typesetter = CTTypesetterCreateWithAttributedString(text)
        let count = text.length
        let firstCount = max(1, CTTypesetterSuggestLineBreak(typesetter, 0, Double(width)))
        let first = CTTypesetterCreateLine(typesetter, CFRange(location: 0, length: min(count, firstCount)))
        if firstCount >= count { return [first] }
        let remainder = CTTypesetterCreateLine(typesetter, CFRange(location: firstCount, length: count - firstCount))
        if CTLineGetTypographicBounds(remainder, nil, nil, nil) <= Double(width) { return [first, remainder] }
        var tokenAttributes = attributes; tokenAttributes[ellipsisAttribute] = true
        let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: tokenAttributes))
        let truncated = CTLineCreateTruncatedLine(remainder, Double(width), .end, token) ?? token
        return [first, truncated]
    }
    func summaryHeight(width: CGFloat) -> CGFloat { CGFloat(lines(width: width).count) * lineHeight }
    override func layout() {
        super.layout()
        var rect: CGRect?
        let content = lines(width: bounds.width)
        for (index, line) in content.enumerated() {
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard attributes[ellipsisAttribute] as? Bool == true else { continue }
                var position = CGPoint.zero
                CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
                let width = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil))
                let candidate = CGRect(x: position.x, y: CGFloat(index) * lineHeight, width: width, height: lineHeight).intersection(bounds)
                rect = candidate.isEmpty ? nil : candidate
            }
        }
        if rect != ellipsisRect, pointerInside { hide(); pointerInside = false }
        ellipsisRect = rect
        anchor.isHidden = rect == nil; anchor.frame = rect ?? .zero
        updateTrackingAreas()
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); context.clip(to: bounds)
        defer { context.restoreGState() }
        for (index, line) in lines(width: bounds.width).enumerated() {
            context.saveGState()
            context.translateBy(x: 0, y: CGFloat(index) * lineHeight + font.ascender)
            context.scaleBy(x: 1, y: -1); context.textMatrix = .identity
            context.textPosition = .zero; CTLineDraw(line, context)
            context.restoreGState()
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); for area in trackingAreas { removeTrackingArea(area) }
        if let rect = ellipsisRect {
            addTrackingArea(NSTrackingArea(rect: rect.insetBy(dx: -3, dy: -2).intersection(bounds),
                options: [.mouseEnteredAndExited, .activeAlways], owner: self))
        }
    }
    override func mouseEntered(with event: NSEvent) { pointerInside = true; show(session, anchor) }
    override func mouseExited(with event: NSEvent) { pointerInside = false; hide() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, pointerInside { hide(); pointerInside = false }
    }
}

/// An invisible geometry/accessibility anchor over the actual typeset ellipsis.
private final class ReplyEllipsisAnchor: NSView {
    var press: () -> Bool = { false }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityLabel("查看完整回复"); setAccessibilityIdentifier("agent-reply-hover")
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityPerformPress() -> Bool { press() }
}

private final class ReplyPreviewHost: NSView {
    private let content: NSView
    private let onHover: (Bool) -> Void
    init(reply: String, onHover: @escaping (Bool) -> Void) {
        self.onHover = onHover
        content = NSHostingView(rootView: AgentReplyPreviewContent(reply: reply))
        super.init(frame: .zero); addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); content.frame = bounds }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
}

struct AgentReplyPreviewContent: View {
    let reply: String
    var body: some View {
        ScrollView {
            Text(reply).font(.system(size: 12)).lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("agent-reply-full-text")
        }.padding(12).background(CompanionMaterial(radius: 10))
    }
}
