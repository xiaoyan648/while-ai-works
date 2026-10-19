import AppKit
import Combine
import SwiftUI
import WhileCore
import AgentHUDCore

extension WorkSource {
    static var dockOrder: [WorkSource] { [.codex, .claude, .qoder, .workbuddy] }
    var dockSymbol: String {
        switch self {
        case .codex: return "terminal"
        case .claude: return "sparkles"
        case .qoder: return "chevron.left.forwardslash.chevron.right"
        case .workbuddy: return "person.2"
        }
    }
    var dockName: String { self == .claude ? "Claude" : clientName }
}

/// All screen placement is in AppKit screen coordinates. Content rectangles are
/// top-down, matching the dock's flipped native host and SwiftUI layout.
enum DesktopDockGeometry {
    static let margin: CGFloat = 8
    static let padding: CGFloat = 10
    static let head: CGFloat = 36
    static let foot: CGFloat = 40
    static let tile: CGFloat = 50
    static let thickness: CGFloat = 52
    static let detailSize = CGSize(width: 460, height: 520)
    /// The card window grows with its content between these heights.
    static let minDetailHeight: CGFloat = 300
    /// Window height around the card itself: room for the perched cat above, shadow below.
    static let cardChrome: CGFloat = 90

    static func size(orientation: DesktopDockOrientation, sources: Int) -> CGSize {
        let length = head + CGFloat(max(1, sources)) * tile + foot
        return orientation == .vertical
            ? CGSize(width: thickness + padding * 2, height: length + padding * 2)
            : CGSize(width: length + padding * 2, height: thickness + padding * 2)
    }
    static func catFrame(orientation: DesktopDockOrientation) -> CGRect {
        orientation == .vertical
            ? CGRect(x: padding, y: padding, width: thickness, height: head)
            : CGRect(x: padding, y: padding, width: head, height: thickness)
    }
    static func tileFrame(index: Int, orientation: DesktopDockOrientation) -> CGRect {
        orientation == .vertical
            ? CGRect(x: padding, y: padding + head + CGFloat(index) * tile, width: thickness, height: tile)
            : CGRect(x: padding + head + CGFloat(index) * tile, y: padding, width: tile, height: thickness)
    }
    static func handleFrame(size: CGSize, orientation: DesktopDockOrientation) -> CGRect {
        orientation == .vertical
            ? CGRect(x: padding, y: size.height - 16, width: thickness, height: 16)
            : CGRect(x: size.width - 16, y: padding, width: 16, height: thickness)
    }
    static func origin(size: CGSize, edge: DesktopDockEdge, fraction: Double, visible: CGRect,
                       attachment: DesktopDockAttachment = .floating) -> CGPoint {
        let f = fraction.isFinite ? min(1, max(0, fraction)) : 0.5
        let x = visible.minX + margin, y = visible.minY + margin
        let dx = max(0, visible.width - size.width - margin * 2)
        let dy = max(0, visible.height - size.height - margin * 2)
        let inset: CGFloat = attachment == .attached ? 0 : margin
        switch edge {
        case .left: return CGPoint(x: visible.minX + inset, y: y + dy * f)
        case .right: return CGPoint(x: visible.maxX - size.width - inset, y: y + dy * f)
        case .bottom: return CGPoint(x: x + dx * f, y: visible.minY + inset)
        case .top: return CGPoint(x: x + dx * f, y: visible.maxY - size.height - inset)
        }
    }
    static func fraction(origin: CGPoint, size: CGSize, edge: DesktopDockEdge, visible: CGRect) -> Double {
        let value = edge.orientation == .vertical
            ? (origin.y - visible.minY - margin) / max(1, visible.height - size.height - margin * 2)
            : (origin.x - visible.minX - margin) / max(1, visible.width - size.width - margin * 2)
        return Double(min(1, max(0, value)))
    }
    /// A 44pt edge band plus hysteresis keeps corner drags from flickering.
    /// Signed distance lets a continued push through the usable top/bottom edge
    /// rotate even when the pointer is still close to the previous side.
    static func dragEdge(to point: CGPoint, current: DesktopDockEdge, visible: CGRect) -> DesktopDockEdge {
        let distances: [DesktopDockEdge: CGFloat] = [
            .left: point.x - visible.minX, .right: visible.maxX - point.x,
            .bottom: point.y - visible.minY, .top: visible.maxY - point.y]
        let nearest = DesktopDockEdge.allCases.min { distances[$0]! < distances[$1]! }!
        guard distances[nearest]! <= 44, distances[nearest]! + 18 < distances[current]! else { return current }
        return nearest
    }
    static func touchesEdge(_ point: CGPoint, edge: DesktopDockEdge, visible: CGRect) -> Bool {
        switch edge {
        case .left: return point.x <= visible.minX + 8
        case .right: return point.x >= visible.maxX - 8
        case .top: return point.y >= visible.maxY - 8
        case .bottom: return point.y <= visible.minY + 8
        }
    }
    static func detailFrame(dock: CGRect, anchor: CGPoint, edge: DesktopDockEdge, visible: CGRect, height: CGFloat? = nil) -> CGRect {
        let wanted = height.map { min(detailSize.height, max(minDetailHeight, $0)) } ?? detailSize.height
        let size = CGSize(
            width: min(detailSize.width, visible.width - margin * 2 - (edge.orientation == .vertical ? dock.width + 2 : 0)),
            height: min(wanted, visible.height - margin * 2 - (edge.orientation == .horizontal ? dock.height + 2 : 0)))
        var origin: CGPoint
        switch edge {
        case .right: origin = CGPoint(x: dock.minX - size.width - 2, y: anchor.y - size.height * 0.55)
        case .left: origin = CGPoint(x: dock.maxX + 2, y: anchor.y - size.height * 0.55)
        case .bottom: origin = CGPoint(x: anchor.x - size.width * 0.65, y: dock.maxY + 2)
        case .top: origin = CGPoint(x: anchor.x - size.width * 0.65, y: dock.minY - size.height - 2)
        }
        origin.x = min(max(origin.x, visible.minX + margin), visible.maxX - size.width - margin)
        origin.y = min(max(origin.y, visible.minY + margin), visible.maxY - size.height - margin)
        return CGRect(origin: origin, size: size)
    }
    static func cardFrame(in size: CGSize) -> CGRect {
        CGRect(x: 26, y: 80, width: size.width - 36, height: size.height - 90)
    }
    static func perchedCatFrame(in size: CGSize) -> CGRect {
        CGRect(x: 4, y: 0, width: 180, height: 120)
    }
}

/// Ink rather than tinted vibrancy keeps the rail and its expanded card quiet.
struct CompanionMaterial: View {
    var radius: CGFloat = 22
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Theme.surface)
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(scheme == .dark ? .white.opacity(0.07) : .black.opacity(0.06), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0.20 : 0.10), radius: 8, y: 3)
    }
}

/// The cat is the window silhouette. Rounded ears and a small hooked tail extend
/// the capsule; contact fillets reach the chosen usable screen edge without a gap.
/// This path also defines native pointer passthrough, including transparent gaps.
struct CatDockContour: Shape {
    var orientation: DesktopDockOrientation
    var edge: DesktopDockEdge
    var attachment: DesktopDockAttachment
    var ears = true
    /// The body and tail alone, for drawing beneath separately animated ears.
    var withoutEars: CatDockContour { var copy = self; copy.ears = false; return copy }
    /// One ear in the vertical layout's coordinates, turned about its root.
    static func ear(width: CGFloat, left: Bool, angle: Double) -> Path {
        let base: CGFloat = left ? 10 : width - 10, sign: CGFloat = left ? 1 : -1
        var ear = Path()
        ear.move(to: CGPoint(x: base + sign * 3, y: 29))
        ear.addLine(to: CGPoint(x: base + sign * 5, y: 6))
        ear.addQuadCurve(to: CGPoint(x: base + sign * 11, y: 3), control: CGPoint(x: base + sign * 6, y: 0))
        ear.addLine(to: CGPoint(x: base + sign * 25, y: 23))
        ear.closeSubpath()
        guard angle != 0 else { return ear }
        // Ears turn outward together: "back" for the left ear is anticlockwise.
        let root = CGPoint(x: base + sign * 14, y: 26)
        let turn = CGAffineTransform(translationX: root.x, y: root.y)
            .rotated(by: CGFloat(angle) * .pi / 180 * sign)
            .translatedBy(x: -root.x, y: -root.y)
        return ear.applying(turn)
    }
    func path(in rect: CGRect) -> Path {
        let vertical = orientation == .vertical
        let width = vertical ? rect.width : rect.height
        let length = vertical ? rect.height : rect.width
        let core = CGRect(x: 10, y: 12, width: width - 20, height: length - 30)
        var path = Path(roundedRect: core, cornerRadius: 26)
        let l = core.minX, r = core.maxX
        if attachment == .attached {
            // One continuous body reaches the edge. The two contact shoulders
            // are concave; the two inward corners keep the capsule's radius.
            var body = Path()
            body.move(to: CGPoint(x: width, y: 0))
            body.addQuadCurve(to: CGPoint(x: width - 12, y: 12), control: CGPoint(x: width, y: 12))
            body.addLine(to: CGPoint(x: l + 26, y: 12))
            body.addQuadCurve(to: CGPoint(x: l, y: 38), control: CGPoint(x: l, y: 12))
            body.addLine(to: CGPoint(x: l, y: length - 38))
            body.addQuadCurve(to: CGPoint(x: l + 26, y: length - 12), control: CGPoint(x: l, y: length - 12))
            body.addLine(to: CGPoint(x: width - 12, y: length - 12))
            body.addQuadCurve(to: CGPoint(x: width, y: length), control: CGPoint(x: width, y: length - 12))
            body.closeSubpath()
            let contactRight = vertical ? edge == .right : edge == .bottom
            path = contactRight ? body : body.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: width, ty: 0))
        }
        // These native contour extensions share the capsule fill, with no seams.
        if ears {
            for left in [true, false] {
                path = Path(path.cgPath.union(Self.ear(width: width, left: left, angle: 0).cgPath))
            }
        }
        // A narrow curl begins inside the rounded base and turns inward.
        var tail = Path()
        tail.move(to: CGPoint(x: l + 24, y: core.maxY - 9))
        tail.addCurve(to: CGPoint(x: l + 17, y: length - 7), control1: CGPoint(x: l + 9, y: core.maxY + 1), control2: CGPoint(x: l + 9, y: length - 13))
        tail.addCurve(to: CGPoint(x: r - 5, y: length - 11), control1: CGPoint(x: l + 26, y: length + 1), control2: CGPoint(x: r + 5, y: length - 1))
        tail.addQuadCurve(to: CGPoint(x: r - 10, y: length - 8), control: CGPoint(x: r - 8, y: length - 15))
        tail.addCurve(to: CGPoint(x: l + 23, y: length - 9), control1: CGPoint(x: r - 3, y: length - 2), control2: CGPoint(x: l + 23, y: length - 1))
        tail.addCurve(to: CGPoint(x: l + 33, y: core.maxY - 6), control1: CGPoint(x: l + 20, y: length - 16), control2: CGPoint(x: l + 28, y: core.maxY))
        tail.closeSubpath(); path = Path(path.cgPath.union(tail.cgPath))
        if !vertical { path = path.applying(CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)) }
        return path.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }
}

/// Content for one client swaps in place: the new content fades in from 6 pt
/// along the dock while the old fades out, without re-running the card's entrance.
final class CardHeightMeter {
    var card: CGFloat = 0
    var viewport: CGFloat = 0
    var content: CGFloat = 0
    var reported: CGFloat = 0
}

private struct DockCardHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct DockViewportHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct SourceSwap: ViewModifier {
    let source: WorkSource?
    let offset: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        ZStack(alignment: .topLeading) {
            content.id(source)
                .transition(.asymmetric(insertion: .offset(offset).combined(with: .opacity), removal: .opacity))
        }
        // Scoped to this swap: the rest of the card does not animate with it.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: source)
    }
}

/// A dock ear drawn on its own, matching the contour's ear when `angle` is zero.
struct CatDockEar: Shape {
    var orientation: DesktopDockOrientation
    var left: Bool
    var angle: Double
    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }
    func path(in rect: CGRect) -> Path {
        let vertical = orientation == .vertical
        var ear = CatDockContour.ear(width: vertical ? rect.width : rect.height, left: left, angle: angle)
        if !vertical { ear = ear.applying(CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)) }
        return ear.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }
}

/// Ears flick back 8°, overshoot 4° and settle; the second ear follows 40 ms later.
struct EarTwitch {
    var left = 0.0
    var right = 0.0
    @KeyframeTrackContentBuilder<Double> static var flick: some KeyframeTrackContent<Double> {
        CubicKeyframe(-8, duration: 0.12)
        CubicKeyframe(4, duration: 0.1)
        SpringKeyframe(0, duration: 0.2, spring: .snappy)
    }
}

enum AgentMarkAssets {
    private static var cache: [String: NSImage] = [:]
    static func image(_ name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        let paths = [MascotController.resources.url(forResource: name, withExtension: "png", subdirectory: "AgentMarks"),
                     URL(fileURLWithPath: "Sources/WhileAIWorks/Resources/AgentMarks/" + name + ".png")]
        let image = paths.compactMap { $0 }.compactMap { NSImage(contentsOf: $0) }.first
        cache[name] = image
        return image
    }
}

struct AgentMark: View {
    let source: WorkSource
    var size: CGFloat = 24
    @Environment(\.colorScheme) private var scheme
    private var name: String {
        switch source {
        case .codex: return "chatgpt"
        case .claude: return "claude"
        case .qoder: return scheme == .dark ? "qoder-dark" : "qoder"
        case .workbuddy: return "workbuddy"
        }
    }
    var body: some View {
        Group {
            if let mark = AgentMarkAssets.image(name) {
                if source == .codex {
                    Image(nsImage: mark).resizable().renderingMode(.template).foregroundStyle(Theme.accent)
                } else { Image(nsImage: mark).resizable() }
            } else { Image(systemName: source.dockSymbol).resizable().scaledToFit() }
        }.scaledToFit().frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct DesktopDockSurface: View {
    @ObservedObject var state: AppState
    var select: (WorkSource?) -> Void = { _ in }
    var hover: (WorkSource, Bool) -> Void = { _, _ in }
    var settings: () -> Void = {}
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var stamps = DockStampCenter.shared
    @State private var optionsHovered = false
    private var vertical: Bool { state.desktopDockOrientation == .vertical }
    var sources: [WorkSource] { WorkSource.dockOrder.filter { state.selectedSources.contains($0) } }
    private var contour: CatDockContour {
        CatDockContour(orientation: state.desktopDockOrientation, edge: state.desktopDockEdge, attachment: state.desktopDockAttachment)
    }
    private var size: CGSize { DesktopDockGeometry.size(orientation: state.desktopDockOrientation, sources: sources.count) }
    var body: some View {
        Group {
            if vertical {
                VStack(spacing: 0) {
                    head.frame(width: DesktopDockGeometry.thickness, height: DesktopDockGeometry.head)
                    entries
                    menu.frame(width: DesktopDockGeometry.thickness, height: DesktopDockGeometry.foot)
                }
            } else {
                HStack(spacing: 0) {
                    head.frame(width: DesktopDockGeometry.head, height: DesktopDockGeometry.thickness)
                    entries
                    menu.frame(width: DesktopDockGeometry.foot, height: DesktopDockGeometry.thickness)
                }
            }
        }
        .padding(DesktopDockGeometry.padding)
        .frame(width: size.width, height: size.height)
        .background { selectionWell }
        .background {
            // The ears are drawn apart from the body so they can twitch when a
            // stamp lands; the contour (with ears) still defines hit testing.
            KeyframeAnimator(initialValue: EarTwitch(), trigger: reduceMotion ? 0 : stamps.earTwitch) { twitch in
                ZStack {
                    contour.withoutEars.fill(Theme.surface)
                    CatDockEar(orientation: state.desktopDockOrientation, left: true, angle: twitch.left).fill(Theme.surface)
                    CatDockEar(orientation: state.desktopDockOrientation, left: false, angle: twitch.right).fill(Theme.surface)
                }
                .compositingGroup()
                .shadow(color: .black.opacity(scheme == .dark ? 0.24 : 0.12), radius: 5, x: 0, y: 2)
            } keyframes: { _ in
                KeyframeTrack(\.left) { EarTwitch.flick }
                KeyframeTrack(\.right) { LinearKeyframe(0, duration: 0.04); EarTwitch.flick }
            }
        }
        .contentShape(contour)
    }
    /// One well behind the tiles slides to the shown agent. Only it animates: an
    /// animation on the whole rail would recompute every tile on every frame.
    private var selectionWell: some View {
        let index = state.desktopDockSource.flatMap { sources.firstIndex(of: $0) }
        let tile = DesktopDockGeometry.tileFrame(index: index ?? 0, orientation: state.desktopDockOrientation)
        return Circle().fill(Theme.wellStrong).frame(width: 44, height: 44)
            .position(x: tile.midX, y: tile.midY)
            .animation(reduceMotion ? nil : Motion.snap, value: index)
            .opacity(index != nil && state.desktopPetShowsStatus ? 1 : 0)
            .animation(reduceMotion ? nil : Motion.fast, value: state.desktopPetShowsStatus)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
    private var head: some View {
        // The native host handles this region as an overview button and drag grip.
        Image(systemName: "pawprint.fill").font(.system(size: 12, weight: .regular))
            .foregroundStyle(scheme == .dark ? .white.opacity(0.32) : .black.opacity(0.35))
            .accessibilityHidden(true)
    }
    @ViewBuilder private var entries: some View {
        if sources.isEmpty {
            Button(action: settings) {
                Image(systemName: "plus").font(.system(size: 17, weight: .medium))
                    .frame(width: vertical ? 52 : 50, height: vertical ? 50 : 52)
            }.buttonStyle(.plain).help("选择要关注的 AI").accessibilityLabel("选择要关注的 AI")
        } else {
            ForEach(sources) { source in
                DesktopDockTile(state: state, source: source, vertical: vertical,
                                action: { select(source) }, hover: { hover(source, $0) })
            }
        }
    }
    private var menu: some View {
        Menu {
            Button("桌面小猫") { state.desktopPetPresentation = .companion }
            Divider()
            Picker("方向", selection: $state.desktopDockOrientation) {
                ForEach(DesktopDockOrientation.allCases) { Text($0.title).tag($0) }
            }
            ForEach(DesktopDockEdge.allCases.filter { $0.orientation == state.desktopDockOrientation }) { edge in
                Button("停靠在" + edge.title) { state.dock(on: edge) }
            }
            Picker("边缘形态", selection: $state.desktopDockAttachment) {
                ForEach(DesktopDockAttachment.allCases) { Text($0.title).tag($0) }
            }
            Divider()
            Picker("外观", selection: $state.desktopCompanionAppearance) {
                ForEach(DesktopCompanionAppearance.allCases) { Text($0.title).tag($0) }
            }
            Button("设置…", action: settings)
            Button("收起猫条") { state.desktopPetEnabled = false }
        } label: {
            Color.clear
                .frame(width: vertical ? 44 : 32, height: vertical ? 32 : 44)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        // Draw outside the native Menu label so AppKit's inactive/template tint
        // cannot dim this control against the rail's explicit light/dark fill.
        .overlay {
            HStack(spacing: 3) {
                ForEach(0..<3) { _ in
                    Circle().fill(Theme.inkSecondary)
                        .frame(width: 3, height: 3)
                }
            }
            .frame(width: 28, height: 28)
            .background {
                Circle().fill(scheme == .dark ? Color.white.opacity(optionsHovered ? 0.10 : 0) : Color.black.opacity(optionsHovered ? 0.06 : 0))
            }
            .allowsHitTesting(false).accessibilityHidden(true)
        }
        .onHover { optionsHovered = $0 }
        .help("猫条选项与设置")
        .accessibilityLabel("猫条选项").accessibilityIdentifier("cat-dock-options")
    }
}

private struct DesktopDockTile: View {
    @ObservedObject var state: AppState
    let source: WorkSource
    let vertical: Bool
    let action: () -> Void
    let hover: (Bool) -> Void
    @State private var hovered = false
    @State private var pawShown = false
    @State private var following = false
    @State private var stamps = 0
    @State private var requestDrops = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var count: Int { state.agentRunningCount(for: source) }
    private var selected: Bool { state.desktopPetShowsStatus && state.desktopDockSource == source }
    private var quota: AgentDockQuota? { state.dockQuota(for: source) }
    private var completion: Date? { state.unseenCompletion(for: source) }
    private var ringColor: Color {
        guard let quota, !quota.stale else { return .secondary.opacity(0.4) }
        return (quota.remaining ?? 100) <= 15 ? Theme.attention : Theme.accent
    }
    private var quotaHint: String {
        guard let quota, let remaining = quota.remaining else {
            return source == .claude ? "当前会话额度暂无读数" : source == .codex ? "每周额度暂无读数" : "账户额度暂无读数"
        }
        return quota.title + "剩余 " + String(Int(remaining.rounded())) + "%" + (quota.stale ? " · 上次读数" : "")
    }
    @ViewBuilder private var ring: some View {
        Circle().stroke(Theme.wellStrong, lineWidth: 2).frame(width: 36, height: 36)
        if let remaining = quota?.remaining {
            Circle().trim(from: 0, to: CGFloat(min(1, max(0, remaining / 100))))
                .stroke(ringColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90)).frame(width: 36, height: 36)
                .animation(reduceMotion ? nil : Motion.slow, value: remaining)
        }
    }
    private var spokenLabel: String { "\(source.clientName)，\(state.desktopPetStatus(for: source))，\(quotaHint)" }
    private var waiting: [AgentInteraction] { state.interactions(for: source) }
    private var requestGlyph: String? {
        waiting.isEmpty ? nil : waiting.count > 1 ? String(min(99, waiting.count)) : waiting[0].request.isQuestion ? "?" : "!"
    }
    private var attentionLabel: String { waiting.isEmpty ? "" : "，\(waiting.count) 个待处理请求" }
    private var completionLabel: String { pawShown ? "，有新完成" : "" }
    private var completionHint: String {
        completion.map { "\n已完成 · " + $0.formatted(date: .omitted, time: .shortened) } ?? ""
    }
    private var tooltip: String {
        "\(source.clientName) · \(state.desktopPetStatus(for: source))\(attentionLabel)\(completionHint)\n\(quotaHint)\n点击固定工作卡片；拖动猫头可换边"
    }
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Theme.wellStrong).frame(width: 44, height: 44).opacity(hovered && !selected ? 1 : 0)
                ring
                AgentActivityMark(source: source, working: count > 0, stamp: stamps).frame(width: 24, height: 24)
                    .allowsHitTesting(false).accessibilityHidden(true)
                DockTileBadges(request: requestGlyph, paw: pawShown, fanned: hovered,
                               clockwise: state.desktopDockEdge == .left || state.desktopDockEdge == .top,
                               stamps: stamps, requestDrops: requestDrops)
            }
            .frame(width: vertical ? DesktopDockGeometry.thickness : DesktopDockGeometry.tile,
                   height: vertical ? DesktopDockGeometry.tile : DesktopDockGeometry.thickness)
            .contentShape(Rectangle())
        }
        .buttonStyle(DockTilePressStyle())
        .onHover { hovered = $0; hover($0) }
        .animation(reduceMotion ? nil : Motion.fast, value: hovered)
        .task(id: completion) { await follow(completion) }
        .onChange(of: requestGlyph == nil) { wasEmpty, isEmpty in
            if wasEmpty && !isEmpty && !reduceMotion { requestDrops += 1 }
        }
        .accessibilityLabel(spokenLabel + attentionLabel + completionLabel)
        .accessibilityIdentifier("cat-dock-" + source.rawValue)
        .help(tooltip)
    }
    /// A completion that arrives while the dock is up is stamped: the swing comes to
    /// rest first, then the paw falls. One already waiting at launch is just shown.
    @MainActor private func follow(_ completion: Date?) async {
        guard following else { following = true; pawShown = completion != nil; return }
        guard completion != nil else {
            if pawShown { withAnimation(Motion.fast) { pawShown = false } }
            return
        }
        guard !pawShown else { return }
        let delay = (reduceMotion ? 0 : 0.35) + DockStampCenter.shared.claim()
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled else { return }
        if reduceMotion { withAnimation(Motion.fast) { pawShown = true } } else { pawShown = true; stamps += 1 }
        try? await Task.sleep(for: .seconds(reduceMotion ? 0 : AgentActivityMarkView.stampContact))
        DockStampCenter.shared.contact(sound: state.soundEnabled)
    }
}

/// The selection well slides between tiles in the surface; the tile itself only
/// answers a press.
private struct DockTilePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(Motion.snap, value: configuration.isPressed)
    }
}

/// Coordinates completion stamps across the dock: stamps within 1.5 s fall one
/// after another, and only the first sounds and twitches the cat's ears.
final class DockStampCenter: ObservableObject {
    static let shared = DockStampCenter()
    static let batchWindow: TimeInterval = 1.5
    static let stagger: TimeInterval = 0.08
    @Published private(set) var earTwitch = 0
    private var batchStart = -TimeInterval.infinity
    private var batchCount = 0
    private var lastContact = -TimeInterval.infinity
    /// Extra delay before this stamp falls.
    func claim(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        if now - batchStart > Self.batchWindow { batchStart = now; batchCount = 0 }
        defer { batchCount += 1 }
        return Double(batchCount) * Self.stagger
    }
    /// Called at a stamp's contact frame. Returns whether it sounded.
    @discardableResult
    func contact(sound: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard now - lastContact > Self.batchWindow else { return false }
        lastContact = now
        if sound { PlayAudio.shared.stamp() }
        earTwitch += 1
        return true
    }
}

/// Badges share one spot on the ring (top-right, 45°). A request needs the user,
/// so it stays in front; a completion paw tucks behind it, showing a sliver, and
/// fans out along the ring toward the screen's interior while the tile is hovered.
private struct DockTileBadges: View {
    static let radius: CGFloat = 22.6
    let request: String?
    let paw: Bool
    let fanned: Bool
    let clockwise: Bool
    let stamps: Int
    let requestDrops: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var both: Bool { request != nil && paw }
    var pawAngle: Double { both ? (fanned ? (clockwise ? 71 : 19) : 54) : 45 }
    var requestAngle: Double { both && fanned ? (clockwise ? 41 : 49) : 45 }
    var body: some View {
        ZStack {
            ZStack {
                if !reduceMotion {
                    KeyframeAnimator(initialValue: StampRipple(), trigger: stamps) { ripple in
                        Circle().stroke(Theme.accentBadge, lineWidth: 1.2).frame(width: 15, height: 15)
                            .scaleEffect(ripple.scale).opacity(ripple.opacity)
                    } keyframes: { _ in
                        KeyframeTrack(\.opacity) {
                            LinearKeyframe(0, duration: AgentActivityMarkView.stampContact)
                            MoveKeyframe(0.55); LinearKeyframe(0, duration: 0.5, timingCurve: .easeOut)
                        }
                        KeyframeTrack(\.scale) {
                            LinearKeyframe(1, duration: AgentActivityMarkView.stampContact)
                            LinearKeyframe(2.1, duration: 0.5, timingCurve: .easeOut)
                        }
                    }
                }
                badge(fill: Theme.accentBadge) {
                    Image(systemName: "pawprint.fill").font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(Theme.accentBadgeInk)
                }
                .stampDrop(trigger: stamps, amplitude: 1)
                .scaleEffect(paw ? 1 : 0.6).opacity(paw ? 1 : 0)
            }
            .modifier(RingPosition(angle: pawAngle))
            badge(fill: Theme.attentionBadge) {
                Text(request ?? "?").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.badgeInk)
            }
            .stampDrop(trigger: requestDrops, amplitude: 0.5)
            .opacity(request == nil ? 0 : 1)
            .animation(Motion.fast, value: request == nil)
            .modifier(RingPosition(angle: requestAngle))
        }
        .animation(Motion.resolved(Motion.snap, reduceMotion: reduceMotion), value: pawAngle)
        .animation(Motion.resolved(Motion.snap, reduceMotion: reduceMotion), value: requestAngle)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
    private func badge<Glyph: View>(fill: Color, @ViewBuilder glyph: () -> Glyph) -> some View {
        Circle().fill(fill).frame(width: 15, height: 15)
            .overlay { glyph() }
            .overlay(Circle().stroke(Theme.surface, lineWidth: 1.5))
    }
}

private struct StampRipple { var scale = 1.0; var opacity = 0.0 }
private struct StampFrame { var scale = 1.0; var angle = 0.0; var opacity = 1.0 }

extension View {
    /// A stamp falls from above, tilted, presses in on contact and springs to rest.
    /// `amplitude` 1 is the completion paw; requests use a gentler 0.5.
    fileprivate func stampDrop(trigger: Int, amplitude: Double) -> some View {
        keyframeAnimator(initialValue: StampFrame(), trigger: trigger) { content, frame in
            content.scaleEffect(frame.scale).rotationEffect(.degrees(frame.angle)).opacity(frame.opacity)
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                MoveKeyframe(1 + 0.9 * amplitude)
                CubicKeyframe(1 - 0.16 * amplitude, duration: AgentActivityMarkView.stampContact)
                CubicKeyframe(1 + 0.07 * amplitude, duration: 0.15)
                SpringKeyframe(1, duration: 0.1, spring: .snappy)
            }
            KeyframeTrack(\.angle) {
                MoveKeyframe(-16 * amplitude)
                CubicKeyframe(0, duration: AgentActivityMarkView.stampContact)
            }
            KeyframeTrack(\.opacity) {
                MoveKeyframe(0)
                LinearKeyframe(1, duration: 0.12)
            }
        }
    }
}

/// Places a badge on the circle around a tile, measured clockwise from the top,
/// so a change of angle travels along the ring rather than cutting across it.
private struct RingPosition: ViewModifier, Animatable {
    var angle: Double
    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }
    func body(content: Content) -> some View {
        let radians = angle * .pi / 180
        content.offset(x: DockTileBadges.radius * sin(radians), y: -DockTileBadges.radius * cos(radians))
    }
}

/// A working mark swings in one continuous sine (±8°) and breathes, fullest as it
/// passes upright, so work is visible at a glance without the old stop at every
/// keyframe. Each client keeps its own phase, so several marks never swing in
/// lockstep. The quota ring stays still, and animation frames never pass through
/// AppState.
struct AgentActivityMark: NSViewRepresentable {
    let source: WorkSource
    let working: Bool
    /// Bumped when a completion stamp lands on this mark; the mark dips under it.
    var stamp = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    func makeNSView(context: Context) -> AgentActivityMarkView { AgentActivityMarkView() }
    func updateNSView(_ view: AgentActivityMarkView, context: Context) {
        view.configure(source: source, dark: scheme == .dark, working: working, reduceMotion: reduceMotion)
        view.press(stamp)
    }
}

final class AgentActivityMarkView: NSView {
    static let swingAngle = 8.0 * Double.pi / 180
    static let breath = 0.06
    static let rampDuration: CFTimeInterval = 0.6
    /// When a stamp's contact frame lands after the stamp starts to fall.
    static let stampContact: CFTimeInterval = 0.17
    private let mark = CALayer()
    private var observer: NSObjectProtocol?
    private var reduceMotion = false
    private var working = false
    private var phase: CFTimeInterval = 0
    private var assetKey: String?
    private var stamp = 0
    private(set) var source: WorkSource?
    var isAnimating: Bool { mark.animation(forKey: "working-swing") != nil }
    /// The angle on screen right now, in radians.
    var presentedAngle: Double { (mark.presentation()?.value(forKeyPath: "transform.rotation.z") as? NSNumber)?.doubleValue ?? 0 }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; mark.contentsGravity = .resizeAspect
        mark.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer?.addSublayer(mark); setAccessibilityElement(false)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func configure(source: WorkSource, dark: Bool, working: Bool, reduceMotion: Bool) {
        self.working = working; self.reduceMotion = reduceMotion; self.source = source
        // A quarter period apart in dock order: neighbours are never in step.
        phase = CFTimeInterval(WorkSource.dockOrder.firstIndex(of: source) ?? 0) * Motion.swingPeriod / 4
        let name: String
        switch source {
        case .codex: name = "chatgpt"
        case .claude: name = "claude"
        case .qoder: name = dark ? "qoder-dark" : "qoder"
        case .workbuddy: name = "workbuddy"
        }
        let key = name + (dark ? ":dark" : ":light")
        if assetKey != key {
            assetKey = key
            if let image = AgentMarkAssets.image(name) ?? NSImage(systemSymbolName: source.dockSymbol, accessibilityDescription: nil) {
                let rendered: NSImage
                if source == .codex {
                    let tint = Theme.accentColor.resolved(dark: dark)
                    rendered = NSImage(size: image.size, flipped: false) { rect in
                        image.draw(in: rect); tint.setFill(); rect.fill(using: .sourceIn); return true
                    }
                } else { rendered = image }
                CATransaction.begin(); CATransaction.setDisableActions(true)
                mark.contents = rendered.cgImage(forProposedRect: nil, context: nil, hints: nil)
                CATransaction.commit()
            }
        }
        updateActivity()
    }
    /// The mark is pressed down by a landing stamp, then springs back.
    func press(_ token: Int) {
        guard token != stamp else { return }
        stamp = token
        guard !reduceMotion, window != nil else { return }
        let dip = CAKeyframeAnimation(keyPath: "transform.scale")
        dip.values = [0, -0.08, 0]; dip.keyTimes = [0, 0.4, 1]; dip.isAdditive = true
        dip.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        dip.duration = 0.28
        dip.beginTime = mark.convertTime(CACurrentMediaTime(), from: nil) + Self.stampContact
        mark.add(dip, forKey: "stamp-dip")
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        mark.bounds = CGRect(origin: .zero, size: bounds.size)
        mark.position = CGPoint(x: bounds.midX, y: bounds.midY)
        mark.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
        updateActivity()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let window {
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main) { [weak self] _ in self?.updateActivity() }
        }
        updateActivity()
    }
    private func updateActivity() {
        let visible = bounds.width > 0 && window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
        if working && !reduceMotion && visible {
            if !isAnimating { startSwing() }
        } else if isAnimating {
            // Work ended: come to rest upright. Hidden or reduced motion: stop at once.
            settle(animated: working == false && !reduceMotion && visible)
        }
    }
    /// The swing eases in from rest over its first moments, then hands over to the
    /// loop with matching angle and speed.
    private func startSwing() {
        let now = mark.convertTime(CACurrentMediaTime(), from: nil)
        mark.removeAnimation(forKey: "working-settle"); mark.removeAnimation(forKey: "working-settle-scale")
        let ramp = swingTrack(start: 0, duration: Self.rampDuration, ramp: true)
        ramp.beginTime = now; ramp.fillMode = .forwards; ramp.isRemovedOnCompletion = false
        let loop = swingTrack(start: Self.rampDuration, duration: Motion.swingPeriod, ramp: false)
        loop.beginTime = now + Self.rampDuration; loop.repeatCount = .infinity
        mark.add(ramp, forKey: "working-ramp")
        mark.add(loop, forKey: "working-swing")
    }
    private func settle(animated: Bool) {
        let presented = mark.presentation()
        let angle = (presented?.value(forKeyPath: "transform.rotation.z") as? NSNumber)?.doubleValue ?? 0
        let scale = (presented?.value(forKeyPath: "transform.scale") as? NSNumber)?.doubleValue ?? 1
        mark.removeAnimation(forKey: "working-ramp"); mark.removeAnimation(forKey: "working-swing")
        guard animated else { return }
        let rotation = Motion.springAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = angle; rotation.toValue = 0
        let breath = Motion.springAnimation(keyPath: "transform.scale")
        breath.fromValue = scale; breath.toValue = 1
        mark.add(rotation, forKey: "working-settle"); mark.add(breath, forKey: "working-settle-scale")
    }
    /// Sampled sine keyframes: angle θ = A·sin(2πt/T); scale is largest at θ = 0.
    /// The ramp multiplies both by a smoothstep from rest.
    private func swingTrack(start: CFTimeInterval, duration: CFTimeInterval, ramp: Bool) -> CAAnimationGroup {
        let steps = ramp ? 18 : 48
        var angles: [NSNumber] = [], scales: [NSNumber] = [], times: [NSNumber] = []
        for step in 0...steps {
            let progress = Double(step) / Double(steps)
            let t = start + duration * progress + phase
            let weight = ramp ? progress * progress * (3 - 2 * progress) : 1
            angles.append(NSNumber(value: weight * Self.swingAngle * sin(2 * .pi * t / Motion.swingPeriod)))
            scales.append(NSNumber(value: 1 + weight * Self.breath / 2 * (1 + cos(4 * .pi * t / Motion.swingPeriod))))
            times.append(NSNumber(value: progress))
        }
        let rotation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        rotation.values = angles; rotation.keyTimes = times; rotation.calculationMode = .cubic
        let breath = CAKeyframeAnimation(keyPath: "transform.scale")
        breath.values = scales; breath.keyTimes = times; breath.calculationMode = .cubic
        let group = CAAnimationGroup()
        group.animations = [rotation, breath]; group.duration = duration
        rotation.duration = duration; breath.duration = duration
        return group
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct DesktopDockDetailView: View {
    @ObservedObject var state: AppState
    var close: () -> Void = {}
    var settings: () -> Void = {}
    /// The card's height with all of its content in view, for sizing the window.
    var idealHeight: (CGFloat) -> Void = { _ in }
    @State private var moreBelow = false
    /// Card, viewport and content heights. A reference, so measuring never re-renders.
    @State private var meter = CardHeightMeter()
    /// The open request's actions ran below the view: show them pinned at the bottom.
    @State private var pinActions = false
    /// Clients whose lists are kept alive while the card is open.
    @State private var keptSources: Set<WorkSource> = []
    /// Clients whose lists are complete. A first visit builds a screenful at once and the
    /// rest once the pointer settles, so sweeping across agents never builds whole lists.
    @State private var fullSources: Set<WorkSource> = []
    @State private var expandedSessions: Set<String> = []
    static let firstRows = 6
    /// The client shown before the latest switch, for the direction of the swap.
    @State private var lastSource: WorkSource?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Switching agents slides the new content 6 pt in the pointer's direction of travel.
    private var swapOffset: CGSize {
        let order = WorkSource.dockOrder
        let from = lastSource.flatMap { order.firstIndex(of: $0) } ?? -1
        let to = state.desktopDockSource.flatMap { order.firstIndex(of: $0) } ?? -1
        let distance: CGFloat = to > from ? 6 : to < from ? -6 : 0
        return state.desktopDockOrientation == .vertical ? CGSize(width: 0, height: distance) : CGSize(width: distance, height: 0)
    }
    private var sources: [WorkSource] {
        if let source = state.desktopDockSource { return [source] }
        return WorkSource.dockOrder.filter { state.selectedSources.contains($0) }
    }
    private var title: String { state.desktopDockSource?.dockName ?? "AI 工作台" }
    private func subtitle(_ requests: [AgentInteraction]) -> String {
        if !requests.isEmpty { return "\(requests.count) 个请求等你处理" }
        let count = sources.reduce(0) { $0 + state.agentRunningCount(for: $1) }
        if count > 0 { return "\(count) 个会话进行中" }
        return state.desktopDockSource.map { state.desktopPetStatus(for: $0) } ?? "陪你等开工"
    }
    /// Rows, requests and the selection are derived once per update and passed down:
    /// as computed properties they were rebuilt (filtered and sorted) for every row.
    var body: some View {
        let rows = state.sessionRows(for: sources)
        let roots = AgentDockSessionTree.roots(rows)
        let requests = rows.flatMap(\.requests)
        let visibleRequests = roots.flatMap { $0.visibleEntries(expanded: expandedSessions) }
            .flatMap { $0.node.row.requests }
        let selectedRequest = visibleRequests.first { $0.id == state.agentInteractionSelectionID } ?? visibleRequests.first
        return card(rows: rows, requests: requests, selectedRequest: selectedRequest)
    }
    private func card(rows: [AgentDockSessionRow], requests: [AgentInteraction], selectedRequest: AgentInteraction?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Group {
                        if let source = state.desktopDockSource { AgentMark(source: source, size: 18) }
                        else { Image(systemName: "pawprint.fill").font(.system(size: 16)).foregroundStyle(Theme.accent) }
                    }.frame(width: 22, height: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(subtitle(requests)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.modifier(SourceSwap(source: state.desktopDockSource, offset: swapOffset))
                Spacer(minLength: 2)
                HStack(spacing: 2) {
                    tab(.sessions, title: "会话", symbol: "bubble.left.and.bubble.right", hasRequests: !requests.isEmpty)
                    tab(.quota, title: "额度", symbol: "chart.bar.xaxis")
                }.padding(3).background(Theme.well, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .contain).accessibilityLabel("工作卡片页签")
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .medium)).frame(width: 22, height: 24)
                }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("收起工作卡片")
            }.padding(.top, 7)
            Divider().opacity(0.35)
            PetDetailScroll(hasMoreBelow: $moreBelow, contentHeight: { meter.content = $0; reportIdealHeight() }, pinActions: $pinActions) {
                VStack(alignment: .leading, spacing: 0) {
                    if sources.isEmpty {
                        Text("让小猫帮你留意 AI 的工作。").font(.system(size: 12)).foregroundStyle(.secondary)
                        Button("选择要关注的 AI", action: settings).buttonStyle(.plain).foregroundStyle(Theme.accent)
                    } else {
                        let quota = state.desktopDockTab == .quota
                        if quota {
                            ForEach(sources) { source in quotaRows(source) }
                            AgentDockTopSessions(sessions: state.agentDashboard.sessions.filter { sources.contains($0.source) },
                                                 showSource: state.desktopDockSource == nil)
                        }
                        // The session lists stay alive under the quota tab too: switching tabs
                        // used to tear every row down and build them all again on the way back.
                        if let current = state.desktopDockSource {
                            // One list per client seen while the card is open stays alive, so a
                            // switch shows another list instead of building one. Hidden lists take
                            // no height and skip updates (their rows are equatable values).
                            ZStack(alignment: .topLeading) {
                                ForEach(WorkSource.dockOrder.filter { $0 == current || keptSources.contains($0) }) { source in
                                    let shown = source == current && !quota
                                    sessionList(source == current ? rows : state.sessionRows(for: [source]), sources: [source],
                                                limit: fullSources.contains(source) ? .max : Self.firstRows,
                                                selectedRequestID: shown ? selectedRequest?.id : nil)
                                        .offset(shown || quota ? .zero : swapOffset)
                                        .opacity(shown ? 1 : 0)
                                        .animation(reduceMotion || quota ? nil : .easeOut(duration: 0.16), value: shown)
                                        .frame(height: shown ? nil : 0, alignment: .top).clipped()
                                        .allowsHitTesting(shown).accessibilityHidden(!shown)
                                }
                            }
                        } else {
                            sessionList(rows, sources: sources, limit: .max, selectedRequestID: quota ? nil : selectedRequest?.id)
                                .opacity(quota ? 0 : 1)
                                .frame(height: quota ? 0 : nil, alignment: .top).clipped()
                                .allowsHitTesting(!quota).accessibilityHidden(quota)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, moreBelow ? .clear : .black], startPoint: .top, endPoint: .bottom).frame(height: 16)
                }
            }
            .background(GeometryReader { Color.clear.preference(key: DockViewportHeight.self, value: $0.size.height) })
            if state.desktopDockTab == .quota {
                let sessions = state.agentDashboard.sessions.filter { sources.contains($0.source) }
                if !sessions.isEmpty {
                    Divider().opacity(0.25)
                    AgentDockUsageView(usage: AgentLocalUsage(sessions: sessions))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if state.desktopDockTab == .sessions, pinActions, let selectedRequest {
                VStack(alignment: .leading, spacing: 8) {
                    Divider().opacity(0.35)
                    AgentInteractionActionsView(state: state, interaction: selectedRequest)
                }.transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? Motion.fast : Motion.snap, value: pinActions)
        .padding(14).background(CompanionMaterial(radius: 22))
        .background(GeometryReader { Color.clear.preference(key: DockCardHeight.self, value: $0.size.height) })
        .onPreferenceChange(DockCardHeight.self) { meter.card = $0; reportIdealHeight() }
        .onPreferenceChange(DockViewportHeight.self) { meter.viewport = $0; reportIdealHeight() }
        .onAppear { lastSource = state.desktopDockSource }
        .onChange(of: state.desktopDockSource) { _, source in lastSource = source }
        .task(id: state.desktopDockSource) {
            guard let source = state.desktopDockSource else { return }
            keptSources.insert(source)
            guard !fullSources.contains(source) else { return }
            // Build the rest of the list once the pointer has settled on this client.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            fullSources.insert(source)
        }
        .onChange(of: state.desktopPetShowsStatus) { _, shown in
            // A closed card keeps nothing alive; the next opening starts fresh.
            if !shown { keptSources = []; fullSources = []; expandedSessions = [] }
        }
        .accessibilityIdentifier("cat-dock-detail")
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .onChange(of: requests.map(\.id)) { old, new in
            if let latest = new.first(where: { !old.contains($0) }) {
                state.desktopDockTab = .sessions
                if state.activeInteractionEditID == nil { state.agentInteractionSelectionID = latest }
            }
        }
    }
    /// Rows keep their priority order; headings name the groups once there is more than one.
    @ViewBuilder private func sessionList(_ rows: [AgentDockSessionRow], sources: [WorkSource], limit: Int,
                                          selectedRequestID: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            let groups = sessionGroups(rows, limit: limit)
            ForEach(groups, id: \.priority) { group in
                if groups.count > 1 {
                    Text("\(Self.groupTitle(group.priority)) · \(group.rows.count)")
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.top, group.priority == groups[0].priority ? 2 : 12)
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(group.rows) { node in
                    ForEach(node.visibleEntries(expanded: expandedSessions)) { entry in
                        VStack(alignment: .leading, spacing: 0) {
                            sessionView(entry.node.row, selectedRequestID: selectedRequestID)
                            if !entry.node.children.isEmpty { subagentToggle(entry.node) }
                            Divider().opacity(0.25)
                        }
                        .padding(.leading, CGFloat(min(entry.depth, 4)) * 14)
                    }
                }
            }
            ForEach(sources.filter { source in !rows.contains { $0.session.source == source } }) { source in
                fallbackRows(source)
            }
        }
    }
    private func sessionGroups(_ rows: [AgentDockSessionRow], limit: Int) -> [(priority: Int, rows: [AgentDockSessionTree])] {
        let now = Date()
        var groups: [(priority: Int, rows: [AgentDockSessionTree])] = []
        for node in AgentDockSessionTree.roots(rows).prefix(limit) {
            let priority = node.priority(at: now)
            if let index = groups.firstIndex(where: { $0.priority == priority }) { groups[index].rows.append(node) }
            else { groups.append((priority, [node])) }
        }
        return groups
    }
    private func subagentToggle(_ node: AgentDockSessionTree) -> some View {
        let expanded = expandedSessions.contains(node.id)
        return Button {
            if expanded { expandedSessions.remove(node.id) }
            else { expandedSessions.insert(node.id) }
            state.hideAgentReplyPreview()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                Text("子 Agent · \(node.descendants.count)")
                if node.pendingCount > 0 {
                    Text("\(node.pendingCount) 待处理").foregroundStyle(Theme.attention)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 10))
            .contentShape(Rectangle())
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel((expanded ? "收起" : "展开") + node.row.session.title + "的子 Agent")
        .accessibilityValue("\(node.descendants.count) 个，\(node.pendingCount) 个待处理")
        .accessibilityIdentifier("agent-subagents-" + node.row.session.id)
    }
    private func sessionView(_ row: AgentDockSessionRow, selectedRequestID: String?) -> some View {
        let session = row.session
        let phase = row.requests.isEmpty && row.event == .working
            ? state.desktopWorkSessions.first { $0.id == session.id && $0.source == session.source }?.phase : nil
        return AgentDockSessionView(state: state, row: row, selectedRequestID: selectedRequestID,
                                    showSource: state.desktopDockSource == nil, phase: phase,
                                    replyPreviews: state.agentReplyPreviews, messageStatus: state.agentMessageStatus[session.id],
                                    delivery: state.agentInteractionDelivery[session.source]).equatable()
    }
    static func groupTitle(_ priority: Int) -> String {
        switch priority {
        case 0: return "待你处理"
        case 1: return "刚完成"
        case 2: return "进行中"
        default: return "较早"
        }
    }
    private func reportIdealHeight() {
        guard meter.card > 0, meter.viewport > 0, meter.content > 0 else { return }
        let ideal = meter.card - meter.viewport + meter.content
        guard abs(ideal - meter.reported) > 1 else { return }
        meter.reported = ideal
        idealHeight(ideal)
    }
    private func tab(_ tab: DesktopDockTab, title: String, symbol: String, hasRequests: Bool = false) -> some View {
        Button {
            // Every published write re-renders each view observing the state, equal or not.
            guard state.desktopDockTab != tab else { return }
            state.desktopDockTab = tab
            if state.agentInteractionInputID != nil { state.agentInteractionInputID = nil }
            state.hideAgentReplyPreview()
        } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                .frame(width: 28, height: 25)
                .foregroundStyle(state.desktopDockTab == tab ? Color.primary : .secondary)
                .background(state.desktopDockTab == tab ? Theme.wellStrong : .clear, in: RoundedRectangle(cornerRadius: 5))
                .overlay(alignment: .topTrailing) {
                    if tab == .sessions, hasRequests {
                        Circle().fill(Theme.attentionBadge).frame(width: 4, height: 4).padding(3)
                    }
                }
        }.buttonStyle(.plain).help(tab == .sessions ? "会话与待处理事件" : "账户额度与本机会话用量")
            .accessibilityLabel(title)
            .accessibilityAddTraits(state.desktopDockTab == tab ? .isSelected : [])
            .accessibilityIdentifier("cat-dock-tab-" + tab.rawValue)
    }
    @ViewBuilder private func quotaRows(_ source: WorkSource) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.desktopDockSource == nil { Text(source.clientName).font(.system(size: 12, weight: .semibold)) }
            AgentDockQuotaView(state: state, source: source)
        }.padding(.vertical, 2)
    }
    @ViewBuilder private func fallbackRows(_ source: WorkSource) -> some View {
        let sessions = state.desktopWorkSessions.filter { $0.source == source }
        VStack(alignment: .leading, spacing: 10) {
            if state.desktopDockSource == nil { Text(source.clientName).font(.system(size: 12, weight: .semibold)) }
            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                HStack(spacing: 9) {
                    Image(systemName: session.phase == .tool ? "wrench.and.screwdriver" : session.phase == .thinking ? "ellipsis.bubble" : "text.bubble")
                        .font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 24, height: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("会话 \(index + 1)").font(.system(size: 12, weight: .medium))
                        Text(session.phase.title).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            if sessions.isEmpty {
                Text(state.workSourceDetails[source].flatMap { $0.isEmpty ? nil : $0 } ?? state.desktopPetStatus(for: source))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if state.agentRunningCount(for: source) > 0 {
                    Text("正在同步会话详情…").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, 8)
    }
}

/// Keeps Metal outside the SwiftUI material's compositing layer. The Rive posture
/// itself removes the body; this native crop just bounds the animated head/paws.
final class PerchedMascotHost: NSView {
    override var isFlipped: Bool { true }
    let mascotView: NSView
    init(mascot: MascotController) {
        mascot.setPerched(true)
        mascotView = mascot.isAvailable ? MascotHostView(controller: mascot) : NSHostingView(rootView: MascotView(controller: mascot))
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(mascotView)
        setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel("趴在卡片上的小猫")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    var rim: CGPoint = CGPoint(x: 22, y: 80)
    override func layout() {
        super.layout()
        mascotView.frame = CGRect(x: 0, y: -17, width: bounds.width, height: bounds.width)
        var visible = Path(CGRect(x: 0, y: 0, width: bounds.width, height: rim.y))
        visible.addRect(CGRect(x: 0, y: rim.y, width: rim.x, height: bounds.height - rim.y))
        // The two front legs hooked over the rim, matching their Rive columns: artboard
        // x 97 and 143 ± 8.5, ending at y 144 when perched, at 0.75 scale and 17 pt up.
        for x in [97.0, 143.0] {
            visible.addRoundedRect(in: CGRect(x: (x - 8.5) * 0.75, y: 123 * 0.75 - 17, width: 17 * 0.75, height: 21 * 0.75),
                                   cornerSize: CGSize(width: 8.5 * 0.75, height: 8.5 * 0.75))
        }
        let mask = CAShapeLayer(); mask.frame = bounds; mask.path = visible.cgPath
        wantsLayer = true; layer?.mask = mask
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class DesktopDockController: NSObject {
    let panel: DesktopPetPanel
    let detailPanel: DesktopPetPanel
    let mascot: MascotController
    let cardMascot: MascotController
    let replyPreview = AgentReplyPreviewController()
    let interactionWindow: AgentInteractionWindowController
    private let state: AppState
    private let showSettings: () -> Void
    private var content: DesktopDockContent!
    private var detailContent: DesktopDockCardContent!
    private var subscription: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var hoverOpenWork: DispatchWorkItem?
    private var hoverCloseWork: DispatchWorkItem?
    private var hoveredSource: WorkSource?
    private var hoverGeneration = 0
    private var pinned = false
    private var dragEdge: DesktopDockEdge?
    private var dragPosition: DesktopDockPosition?
    private var catchTimer: Timer?
    private var pointerTimer: Timer?
    private var refreshScheduled = false
    /// The card is leaving: its window lingers only for the exit animation.
    private var closingCard = false
    /// Clients the open card is showing; leaving them marks their completions seen.
    private var cardShown: [WorkSource]?
    /// The card's height with everything in view, reported by its content.
    private var idealCardHeight: CGFloat?
    var cardVisible: Bool { detailPanel.isVisible && !closingCard }

    init(state: AppState, mascot: MascotController = MascotController(), cardMascot: MascotController = MascotController(),
         showSettings: @escaping () -> Void = {}) {
        self.state = state; self.mascot = mascot; self.cardMascot = cardMascot; self.showSettings = showSettings
        interactionWindow = AgentInteractionWindowController(state: state)
        panel = Self.makePanel(title: "贴边猫条")
        detailPanel = Self.makePanel(title: "小猫工作卡片")
        super.init()
        state.showAgentReplyPreview = { [weak self] session, anchor in
            guard let self, self.state.agentReplyPreviews else { return }
            self.replyPreview.show(session, from: anchor)
        }
        state.hideAgentReplyPreview = { [weak self] in self?.replyPreview.hideAfterDelay() }
        replyPreview.didHide = { [weak self] in self?.hoverCard(entered: false) }
        state.openAgentInteraction = { [weak self] id in
            guard let self else { return }
            self.state.agentInteractionInputID = nil
            self.interactionWindow.show(id, appearance: self.state.desktopCompanionAppearance.native, beside: self.detailPanel.frame)
        }
        state.focusAgentComposer = { [weak self] in
            guard let self else { return }
            self.pinned = true; self.detailPanel.allowsKeyboard = true
            self.detailPanel.makeKey()
        }
        content = DesktopDockContent(state: state, mascot: mascot,
            select: { [weak self] in self?.select($0) }, hover: { [weak self] in self?.hover($0, entered: $1) }, settings: showSettings)
        content.onMove = { [weak self] in self?.drag(to: $0) }
        content.onSave = { [weak self] in self?.finishDrag() }
        content.onCat = { [weak self] in self?.select(nil); self?.mascot.pet() }
        content.makeMenu = { [weak self] in self?.contextMenu() ?? NSMenu() }
        panel.contentView = content
        detailContent = DesktopDockCardContent(state: state, mascot: cardMascot,
            close: { [weak self] in self?.dismiss() }, settings: { [weak self] in self?.dismiss(); showSettings() })
        detailContent.onHover = { [weak self] entered in self?.hoverCard(entered: entered) }
        detailContent.onIdealHeight = { [weak self] height in
            guard let self, abs((self.idealCardHeight ?? 0) - height.rounded(.up)) > 1 else { return }
            self.idealCardHeight = height.rounded(.up)
            // Reported from inside a SwiftUI update: resizing here would lay the whole card
            // out again synchronously, once per height the update passes through.
            if self.cardVisible { self.scheduleRefresh() }
        }
        detailPanel.contentView = detailContent
        subscription = state.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.dismissOutsideClick(); return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.dismissOutsideClick() }
        // Catch presentation expires on a monotonic clock without a state write.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.state.desktopPetEnabled, self.state.desktopPetPresentation == .dock else { return }
            let expected = self.state.companionCatch(at: ProcessInfo.processInfo.systemUptime) == nil
            if expected != self.panel.isVisible { self.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common); catchTimer = timer
        refresh()
    }
    deinit {
        hoverOpenWork?.cancel(); hoverCloseWork?.cancel(); catchTimer?.invalidate(); pointerTimer?.invalidate()
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        panel.orderOut(nil); detailPanel.orderOut(nil)
    }
    private static func makePanel(title: String) -> DesktopPetPanel {
        let panel = DesktopPetPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = title; panel.setAccessibilityLabel(title)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none; panel.acceptsMouseMovedEvents = true
        return panel
    }
    private var sources: [WorkSource] { WorkSource.dockOrder.filter { state.selectedSources.contains($0) } }
    /// Coalesces state changes and height reports into one refresh on the next run-loop turn.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false; self?.refresh()
        }
    }
    private func screen(for position: DesktopDockPosition?) -> NSScreen? {
        NSScreen.screens.first { DesktopScreenChoice.id(for: $0) == position?.screenID }
            ?? NSScreen.screens.first { DesktopScreenChoice.id(for: $0) == String(CGMainDisplayID()) }
            ?? NSScreen.screens.first
    }
    func refresh() {
        interactionWindow.refresh()
        if !state.agentReplyPreviews || replyPreview.source.map({ !state.selectedSources.contains($0) }) == true {
            replyPreview.dismiss()
        }
        let visible = state.desktopPetEnabled && state.desktopPetPresentation == .dock && state.companionCatch(at: ProcessInfo.processInfo.systemUptime) == nil
        guard visible, let screen = screen(for: dragPosition ?? state.desktopDockPosition) else {
            replyPreview.dismiss()
            if state.agentComposeSessionID != nil { state.agentComposeSessionID = nil }
            if state.agentInteractionInputID != nil { state.agentInteractionInputID = nil }
            panel.orderOut(nil); hideCard(animated: false)
            mascot.setActive(false)
            cancelHover(); pinned = false
            pointerTimer?.invalidate(); pointerTimer = nil
            content.cancelDrag(); dragEdge = nil; dragPosition = nil
            return
        }
        if let source = state.desktopDockSource, !state.selectedSources.contains(source) { state.desktopDockSource = nil }
        // Reassigning an equal appearance still invalidates every view in the window.
        let appearance = state.desktopCompanionAppearance.native
        if panel.appearance?.name != appearance?.name { panel.appearance = appearance }
        if detailPanel.appearance?.name != appearance?.name { detailPanel.appearance = appearance }
        detailPanel.allowsKeyboard = state.agentComposeSessionID != nil || state.agentInteractionInputID != nil
        if !detailPanel.allowsKeyboard && detailPanel.isKeyWindow { detailPanel.resignKey() }
        let size = DesktopDockGeometry.size(orientation: state.desktopDockOrientation, sources: sources.count)
        let origin = DesktopDockGeometry.origin(size: size, edge: dragEdge ?? state.desktopDockEdge,
            fraction: (dragPosition ?? state.desktopDockPosition)?.fraction ?? 0.5, visible: screen.visibleFrame, attachment: state.desktopDockAttachment)
        let dockFrame = CGRect(origin: origin, size: size)
        let dockSizeChanged = panel.frame.size != size || content.frame.size != size
        if panel.frame != dockFrame { panel.setFrame(dockFrame, display: true) }
        if dockSizeChanged {
            content.frame = CGRect(origin: .zero, size: size); content.needsLayout = true
            content.layoutSubtreeIfNeeded()
        }
        mascot.set(mood: state.detectedWorking ? .watch : .sleep, coat: state.mascotCoat)
        if !panel.isVisible { panel.orderFrontRegardless() }
        mascot.setActive(false)
        if pointerTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.updateHitRegions() }
            RunLoop.main.add(timer, forMode: .common); pointerTimer = timer
        }
        updateHitRegions()
        guard state.desktopPetShowsStatus else {
            replyPreview.dismiss()
            hideCard(animated: true); pinned = false
            return
        }
        let index = state.desktopDockSource.flatMap { sources.firstIndex(of: $0) }
        let entry = index.map { DesktopDockGeometry.tileFrame(index: $0, orientation: state.desktopDockOrientation) }
            ?? DesktopDockGeometry.catFrame(orientation: state.desktopDockOrientation)
        let anchor = CGPoint(x: origin.x + entry.midX, y: origin.y + size.height - entry.midY)
        let frame = DesktopDockGeometry.detailFrame(dock: panel.frame, anchor: anchor, edge: state.desktopDockEdge, visible: screen.visibleFrame,
                                                    height: idealCardHeight.map { $0 + DesktopDockGeometry.cardChrome })
        let alreadyVisible = cardVisible
        if closingCard { closingCard = false; detailContent.resetMotion() }
        if !alreadyVisible && state.desktopDockTab != .sessions { state.desktopDockTab = .sessions }
        let cardSizeChanged = detailPanel.frame.size != frame.size || detailContent.frame.size != frame.size
        // Following the pointer between agents only moves the window: a move needs no
        // layout or redraw. A size change resizes once, never in animated steps.
        if detailPanel.frame.size == frame.size {
            if detailPanel.frame.origin != frame.origin { detailPanel.setFrameOrigin(frame.origin) }
        } else {
            detailPanel.setFrame(frame, display: true)
        }
        if cardSizeChanged && !alreadyVisible {
            detailContent.frame = CGRect(origin: .zero, size: frame.size); detailContent.needsLayout = true
            detailContent.layoutSubtreeIfNeeded()
        }
        cardMascot.set(mood: .curious, coat: state.mascotCoat)
        if !alreadyVisible {
            detailPanel.orderFrontRegardless()
            detailContent.animateEntrance(edge: state.desktopDockEdge,
                                          anchor: CGPoint(x: anchor.x - frame.minX, y: anchor.y - frame.minY),
                                          reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
        let showing = state.desktopDockSource.map { [$0] } ?? sources
        if cardShown != showing {
            if let shown = cardShown { state.markCompletionSeen(shown.filter { !showing.contains($0) }) }
            cardShown = showing
        }
        cardMascot.setActive(detailPanel.occlusionState.contains(.visible))
        updateHitRegions()
    }
    /// Collapses the card. Leaving it marks what it showed as seen; the window stays
    /// up only while it shrinks away, and can be reclaimed by a new opening.
    private func hideCard(animated: Bool) {
        if let shown = cardShown { state.markCompletionSeen(shown) }
        cardShown = nil
        guard animated, detailPanel.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            closingCard = false; detailContent.resetMotion()
            detailPanel.orderOut(nil); cardMascot.setActive(false)
            return
        }
        guard !closingCard else { return }
        closingCard = true; detailPanel.ignoresMouseEvents = true
        detailContent.animateExit { [weak self] in
            guard let self, self.closingCard else { return }
            self.closingCard = false; self.detailContent.resetMotion()
            self.detailPanel.orderOut(nil); self.cardMascot.setActive(false)
        }
    }
    func select(_ source: WorkSource?) {
        cancelHover()
        replyPreview.dismiss()
        if source != state.desktopDockSource || !state.desktopPetShowsStatus {
            if state.agentComposeSessionID != nil { state.agentComposeSessionID = nil }
            if state.agentInteractionInputID != nil { state.agentInteractionInputID = nil }
            if state.desktopDockTab != .sessions { state.desktopDockTab = .sessions }
        }
        if pinned && state.desktopPetShowsStatus && source == state.desktopDockSource { dismiss(); return }
        pinned = true
        if state.desktopDockSource != source { state.desktopDockSource = source }
        if !state.desktopPetShowsStatus { state.desktopPetShowsStatus = true }
        refresh()
    }
    func hover(_ source: WorkSource, entered: Bool) {
        guard !pinned, state.desktopPetPresentation == .dock, panel.isVisible else { return }
        if !entered {
            // SwiftUI can deliver the previous tile's exit after the next tile's entry.
            guard hoveredSource == source else { return }
            hoveredSource = nil
            cancelHoverOpening()
            scheduleHoverClose()
            return
        }
        hoveredSource = source
        hoverCloseWork?.cancel(); hoverCloseWork = nil
        cancelHoverOpening()
        if state.desktopPetShowsStatus {
            showHoveredSource(source)
            return
        }
        // A brief initial dwell avoids opening while passing through the rail.
        // Once open, switching agents has no dwell or repeated entrance animation.
        let generation = hoverGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hoverGeneration == generation, self.hoveredSource == source else { return }
            self.showHoveredSource(source)
        }
        hoverOpenWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }
    private func showHoveredSource(_ source: WorkSource) {
        guard !pinned, state.desktopPetPresentation == .dock, panel.isVisible,
              state.selectedSources.contains(source) else { return }
        if state.desktopDockSource != source {
            replyPreview.dismiss()
            state.desktopDockTab = .sessions
            state.desktopDockSource = source
        }
        if !state.desktopPetShowsStatus { state.desktopDockTab = .sessions; state.desktopPetShowsStatus = true }
        // Published state coalesces window positioning into the next main-run-loop
        // refresh; avoid forcing two full native layouts for the same pointer event.
    }
    private func cancelHoverOpening() {
        hoverGeneration += 1
        hoverOpenWork?.cancel(); hoverOpenWork = nil
    }
    private func cancelHover() {
        cancelHoverOpening()
        hoverCloseWork?.cancel(); hoverCloseWork = nil
        hoveredSource = nil
    }
    private func hoverCard(entered: Bool) {
        hoverCloseWork?.cancel(); hoverCloseWork = nil
        guard !entered, !pinned, state.desktopPetPresentation == .dock, panel.isVisible else { return }
        scheduleHoverClose()
    }
    private func scheduleHoverClose() {
        hoverCloseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.pinned, self.hoveredSource == nil,
                  !self.contains(NSEvent.mouseLocation) else { return }
            self.dismiss()
        }
        hoverCloseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }
    private func updateHitRegions() {
        let point = NSEvent.mouseLocation
        panel.ignoresMouseEvents = !content.hasActiveGesture && !content.containsInteraction(panel.convertPoint(fromScreen: point))
        detailPanel.ignoresMouseEvents = closingCard || !detailContent.containsInteraction(detailPanel.convertPoint(fromScreen: point))
        mascot.setActive(false)
        cardMascot.setActive(detailPanel.isVisible && detailPanel.occlusionState.contains(.visible))
    }
    func dismiss() {
        replyPreview.dismiss()
        cancelHover(); pinned = false
        if state.agentComposeSessionID != nil { state.agentComposeSessionID = nil }
        if state.agentInteractionInputID != nil { state.agentInteractionInputID = nil }
        if state.desktopPetShowsStatus { state.desktopPetShowsStatus = false }
        hideCard(animated: true)
    }
    private func contains(_ point: CGPoint) -> Bool {
        (panel.isVisible && content.containsInteraction(panel.convertPoint(fromScreen: point))) ||
            (cardVisible && detailContent.containsInteraction(detailPanel.convertPoint(fromScreen: point))) ||
            (replyPreview.panel.isVisible && replyPreview.panel.frame.contains(point))
    }
    func dismissOutsideClick(at point: CGPoint? = nil) {
        guard state.desktopPetPresentation == .dock, state.desktopPetShowsStatus else { return }
        if !contains(point ?? NSEvent.mouseLocation) { dismiss() }
    }
    func drag(to point: CGPoint, on dragScreen: NSScreen? = nil) {
        dismiss()
        guard let screen = dragScreen ?? NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? panel.screen else { return }
        let edge = DesktopDockGeometry.dragEdge(to: point, current: dragEdge ?? state.desktopDockEdge, visible: screen.visibleFrame)
        if state.desktopDockEdge != edge { state.dock(on: edge) }
        if state.desktopDockAttachment != .attached && DesktopDockGeometry.touchesEdge(point, edge: edge, visible: screen.visibleFrame) { state.desktopDockAttachment = .attached }
        let size = DesktopDockGeometry.size(orientation: edge.orientation, sources: sources.count)
        let head = DesktopDockGeometry.catFrame(orientation: edge.orientation)
        let origin = CGPoint(x: point.x - head.midX, y: point.y - size.height + head.midY)
        let fraction = DesktopDockGeometry.fraction(origin: origin, size: size, edge: edge, visible: screen.visibleFrame)
        dragEdge = edge; dragPosition = DesktopDockPosition(screenID: DesktopScreenChoice.id(for: screen), fraction: fraction)
        refresh()
    }
    func finishDrag() {
        if let edge = dragEdge { state.dock(on: edge) }
        if let position = dragPosition { state.desktopDockPosition = position }
        dragEdge = nil; dragPosition = nil
        refresh()
    }
    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [("展开工作台", #selector(showOverview)), ("切换为桌面小猫", #selector(showCompanion)),
            (state.desktopDockOrientation == .vertical ? "横向猫条" : "竖向猫条", #selector(rotate)),
            (state.desktopDockAttachment == .attached ? "切换为悬浮" : "贴边融合", #selector(toggleAttachment)),
            ("回到边缘中央", #selector(resetPosition)), ("设置…", #selector(settings)), ("收起猫条", #selector(hide))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        return menu
    }
    @objc private func showOverview() { select(nil) }
    @objc private func showCompanion() { state.desktopPetPresentation = .companion }
    @objc private func rotate() { state.desktopDockOrientation = state.desktopDockOrientation == .vertical ? .horizontal : .vertical }
    @objc private func toggleAttachment() { state.desktopDockAttachment = state.desktopDockAttachment == .attached ? .floating : .attached }
    @objc private func resetPosition() { state.resetDesktopPetPosition() }
    @objc private func settings() { dismiss(); showSettings() }
    @objc private func hide() { state.desktopPetEnabled = false }
}

private final class DesktopDockContent: NSView {
    override var isFlipped: Bool { true }
    var onMove: ((CGPoint) -> Void)?
    var onSave: (() -> Void)?
    var onCat: (() -> Void)?
    var makeMenu: (() -> NSMenu)?
    private let state: AppState
    private let surface: NSView
    private var downPoint: CGPoint?
    private var dragging = false
    private var cachedContour: (key: String, path: Path)?
    var hasActiveGesture: Bool { downPoint != nil }
    init(state: AppState, mascot: MascotController, select: @escaping (WorkSource?) -> Void,
         hover: @escaping (WorkSource, Bool) -> Void, settings: @escaping () -> Void) {
        self.state = state
        surface = NSHostingView(rootView: DesktopDockSurface(state: state, select: select, hover: hover, settings: settings))
        super.init(frame: .zero)
        wantsLayer = true; layer?.backgroundColor = NSColor.clear.cgColor; clipsToBounds = true
        addSubview(surface)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("贴边猫条")
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "展开全部 AI 工作台", target: self, selector: #selector(accessibleOverview)),
            NSAccessibilityCustomAction(name: "猫条选项", target: self, selector: #selector(accessibleMenu))
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout(); surface.frame = bounds
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func containsInteraction(_ windowPoint: CGPoint) -> Bool {
        containsContour(CGPoint(x: windowPoint.x, y: bounds.height - windowPoint.y))
    }
    private func containsContour(_ point: CGPoint) -> Bool {
        let key = "\(bounds)-\(state.desktopDockOrientation)-\(state.desktopDockEdge)-\(state.desktopDockAttachment)"
        if cachedContour?.key != key {
            cachedContour = (key, CatDockContour(orientation: state.desktopDockOrientation, edge: state.desktopDockEdge,
                                                attachment: state.desktopDockAttachment).path(in: bounds))
        }
        return cachedContour?.path.contains(point) ?? false
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard containsContour(local) else { return nil }
        if DesktopDockGeometry.catFrame(orientation: state.desktopDockOrientation).contains(local) || DesktopDockGeometry.handleFrame(size: bounds.size, orientation: state.desktopDockOrientation).contains(local) { return self }
        return surface.hitTest(local)
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        downPoint = NSEvent.mouseLocation; dragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint else { return }
        let now = NSEvent.mouseLocation, dx = now.x - start.x, dy = now.y - start.y
        if hypot(dx, dy) > 4 { dragging = true }
        if dragging { onMove?(now) }
    }
    override func mouseUp(with event: NSEvent) {
        guard downPoint != nil else { return }
        if dragging { onSave?() } else { onCat?() }
        downPoint = nil; dragging = false
    }
    override func rightMouseDown(with event: NSEvent) {
        cancelDrag()
        if let menu = makeMenu?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
    func cancelDrag() { downPoint = nil; dragging = false }
    @objc private func accessibleOverview() -> Bool { onCat?(); return true }
    @objc private func accessibleMenu() -> Bool {
        guard let menu = makeMenu?() else { return false }
        menu.popUp(positioning: nil, at: CGPoint(x: bounds.midX, y: bounds.midY), in: self)
        return true
    }
}

private final class DesktopDockCardContent: NSView {
    override var isFlipped: Bool { true }
    private let card: NSView
    private let cat: PerchedMascotHost
    private let mascot: MascotController
    var onHover: ((Bool) -> Void)?
    var onIdealHeight: ((CGFloat) -> Void)?
    private var tracking: NSTrackingArea?
    init(state: AppState, mascot: MascotController, close: @escaping () -> Void, settings: @escaping () -> Void) {
        var report: (CGFloat) -> Void = { _ in }
        card = NSHostingView(rootView: DesktopDockDetailView(state: state, close: close, settings: settings,
                                                             idealHeight: { report($0) }))
        cat = PerchedMascotHost(mascot: mascot)
        self.mascot = mascot
        super.init(frame: .zero)
        report = { [weak self] height in self?.onIdealHeight?(height) }
        wantsLayer = true; layer?.backgroundColor = NSColor.clear.cgColor; clipsToBounds = true
        addSubview(card); addSubview(cat)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout(); card.frame = DesktopDockGeometry.cardFrame(in: bounds.size); cat.frame = DesktopDockGeometry.perchedCatFrame(in: bounds.size)
        cat.rim = CGPoint(x: card.frame.minX - cat.frame.minX, y: card.frame.minY - cat.frame.minY)
        cat.needsLayout = true
    }
    func containsInteraction(_ screenConvertedPoint: CGPoint) -> Bool {
        let point = CGPoint(x: screenConvertedPoint.x, y: bounds.height - screenConvertedPoint.y)
        return card.frame.contains(point) || cat.frame.contains(point)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { mascot.pet() }
    /// The card grows out of the entry that opened it: it starts at 92%, nudged
    /// 8 pt toward the dock, and springs into place; the cat climbs on 0.1 s later.
    /// `anchor` is the entry's centre in window points, measured from the bottom left.
    func animateEntrance(edge: DesktopDockEdge, anchor: CGPoint, reduceMotion: Bool) {
        guard let layer else { return }
        resetMotion()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.duration = reduceMotion ? 0.15 : 0.2
        layer.add(fade, forKey: "card-enter-fade")
        guard !reduceMotion else { return }
        var origin = anchor, nudge = CGPoint.zero
        switch edge {
        case .right: origin.x = bounds.width; nudge.x = 8
        case .left: origin.x = 0; nudge.x = -8
        case .bottom: origin.y = 0; nudge.y = -8
        case .top: origin.y = bounds.height; nudge.y = 8
        }
        let grow = Motion.springAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: Self.scale(layer, by: 0.92, about: origin, nudge: nudge))
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        layer.add(grow, forKey: "card-enter")
        if let perch = cat.layer {
            let down: CGFloat = perch.superlayer?.contentsAreFlipped() == true ? 6 : -6
            let climb = Motion.springAnimation(keyPath: "transform.translation.y")
            climb.fromValue = down; climb.toValue = 0
            climb.beginTime = perch.convertTime(CACurrentMediaTime(), from: nil) + 0.1
            climb.fillMode = .backwards
            let show = CABasicAnimation(keyPath: "opacity")
            show.fromValue = 0; show.toValue = 1; show.duration = 0.2
            show.beginTime = climb.beginTime; show.fillMode = .backwards
            perch.add(climb, forKey: "card-cat-climb"); perch.add(show, forKey: "card-cat-show")
        }
    }
    func animateExit(completion: @escaping () -> Void) {
        guard let layer else { completion(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.toValue = NSValue(caTransform3D: Self.scale(layer, by: 0.96, about: CGPoint(x: bounds.midX, y: bounds.midY), nudge: .zero))
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.toValue = 0
        for animation in [shrink, fade] {
            animation.duration = 0.18; animation.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animation.fillMode = .forwards; animation.isRemovedOnCompletion = false
        }
        layer.add(shrink, forKey: "card-exit"); layer.add(fade, forKey: "card-exit-fade")
        CATransaction.commit()
    }
    func resetMotion() {
        for key in ["card-enter", "card-enter-fade", "card-exit", "card-exit-fade"] { layer?.removeAnimation(forKey: key) }
        for key in ["card-cat-climb", "card-cat-show"] { cat.layer?.removeAnimation(forKey: key) }
    }
    /// A transform that scales the layer about a point given in bottom-left window
    /// points, then nudges it, whatever the layer's anchor and flip.
    private static func scale(_ layer: CALayer, by factor: CGFloat, about point: CGPoint, nudge: CGPoint) -> CATransform3D {
        let flipped = layer.superlayer?.contentsAreFlipped() == true
        let size = layer.bounds.size
        let pivot = CGPoint(x: point.x - layer.anchorPoint.x * size.width,
                            y: (flipped ? size.height - point.y : point.y) - layer.anchorPoint.y * size.height)
        var transform = CATransform3DMakeTranslation(pivot.x + nudge.x, pivot.y + (flipped ? -nudge.y : nudge.y), 0)
        transform = CATransform3DScale(transform, factor, factor, 1)
        return CATransform3DTranslate(transform, -pivot.x, -pivot.y, 0)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if card.frame.contains(local) { return card.hitTest(local) }
        return cat.frame.contains(local) ? self : nil
    }
}

struct AgentDockUsageView: View {
    let usage: AgentLocalUsage
    private let scope = "本机读取的最近会话累计，未限定为今日或 24 小时；不代表订阅账单。"
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Token 用量").font(.system(size: 11, weight: .medium))
                Spacer(minLength: 4)
                Label("本机 · \(usage.sessionCount) 个会话", systemImage: "square.stack")
                    .font(.system(size: 9)).foregroundStyle(.secondary).help(scope)
            }
            if usage.total > 0 {
                // The hit rate leads; a composition bar would be almost all cache.
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("缓存命中").font(.system(size: 9)).foregroundStyle(.secondary)
                        Text(usage.cacheHitRate != nil ? TokenFormat.share(usage.cached, of: usage.input + usage.cached) : "—")
                            .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(usage.cacheHitRate != nil ? Theme.accent : .secondary)
                    }
                    .frame(minWidth: 84, alignment: .leading)
                    .help("缓存命中 = 缓存读取 ÷（输入 + 缓存读取），按输入 Token 计算，并非请求次数。\n没有缓存读取记录时不估算。")
                    .accessibilityElement(children: .combine)
                    metric("输入", symbol: "arrow.down", value: usage.input, tint: .secondary)
                    metric("输出", symbol: "arrow.up", value: usage.output, tint: .secondary)
                    metric("缓存读取", symbol: "arrow.triangle.2.circlepath", value: usage.cached, tint: .secondary)
                }
                Text("总计 " + TokenFormat.short(usage.total) + " tok").font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
                    .help("总计 " + exact(usage.total) + " Token，包含输入、输出和缓存读取。\n" + scope)
            } else {
                Text("客户端尚未记录 Token 用量").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 2).accessibilityIdentifier("cat-dock-token-usage")
    }
    private func exact(_ count: Int) -> String { count.formatted(.number.locale(Locale(identifier: "zh_CN"))) }
    private func metric(_ title: String, symbol: String, value: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.system(size: 9)).foregroundStyle(tint)
            Text(TokenFormat.short(value)).font(.system(size: 13, weight: .medium)).monospacedDigit()
                .foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.85)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .help(title + "：" + exact(value) + " Token" + (title == "输入" ? "（不含缓存读取）" : "") + "\n" + scope)
            .accessibilityElement(children: .ignore).accessibilityLabel(title).accessibilityValue(exact(value) + " Token")
    }
}

private struct AgentDockQuotaView: View {
    @ObservedObject var state: AppState
    let source: WorkSource
    private var quotas: [AgentDockQuota] {
        let all = state.agentDashboard.quotas.filter { $0.source == source }
        guard let primary = state.dockQuota(for: source) else { return all }
        return [primary] + all.filter { $0.id != primary.id }
    }
    private func tooltip(_ quota: AgentDockQuota) -> String {
        let reading = quota.remaining.map { String(Int($0.rounded())) + "%" } ?? "未知"
        let reset = quota.resetAt.map { " · 重置于 " + $0.formatted() } ?? ""
        let pace = quota.paceRemaining().map { "\n竖线：按时间平均消耗，此刻应剩 \(Int($0.rounded()))%" } ?? ""
        return "\(quota.title) · 剩余 \(reading)\(reset)" + (quota.stale ? " · 上次读数" : "") + pace
    }
    static func updatedLabel(_ updated: Date, now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(updated)) / 60)
        if minutes < 1 { return "刚刚更新" }
        if minutes < 60 { return "\(minutes) 分钟前更新" }
        return "\(minutes / 60) 小时前更新"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Text("账户剩余额度").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                if let plan = state.agentDashboard.plans[source] {
                    Text("· " + plan).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).help(plan)
                }
                Spacer()
                if let updated = state.agentDashboard.updatedAt {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(Self.updatedLabel(updated, now: context.date)).font(.system(size: 9)).foregroundStyle(.secondary)
                            .help("读数更新于 " + updated.formatted(date: .omitted, time: .standard))
                    }
                }
                Button(action: state.refreshAgentData) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .medium)).frame(width: 24, height: 24)
                }.buttonStyle(.plain).foregroundStyle(.secondary).help("刷新已登录客户端的用量")
                    .accessibilityLabel("刷新用量").accessibilityIdentifier("cat-dock-refresh-quota")
            }
            if quotas.isEmpty {
                Text(state.agentDashboard.notices[source] ?? (state.agentDashboard.updatedAt == nil ? "正在连接本机客户端…" : "客户端暂未提供账户额度"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            ForEach(quotas) { quota in
                let primary = state.dockQuota(for: source)?.id == quota.id
                let tint: Color = quota.stale || quota.remaining == nil ? .secondary : (quota.remaining ?? 100) <= 15 ? Theme.attention : Theme.accent
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(quota.title).font(.system(size: primary ? 11 : 10, weight: .medium)).lineLimit(1)
                        if quota.stale { Image(systemName: "clock").font(.system(size: 9)).foregroundStyle(.secondary).help("上次读数") }
                        Spacer(minLength: 0)
                        if !primary, let reset = quota.resetAt, reset > Date() {
                            Image(systemName: "clock.arrow.circlepath").font(.system(size: 8)).foregroundStyle(.secondary)
                            Text(reset, style: .relative).font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        Text(quota.remaining.map { "\(Int($0.rounded()))%" } ?? "—")
                            .font(.system(size: primary ? 17 : 11, weight: .medium)).monospacedDigit()
                            .foregroundStyle(primary ? tint : .secondary)
                    }
                    // A thin 3 pt bar centred in a 9 pt band, so the pace marker never
                    // thickens the bar or crowds the line below.
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.wellStrong).frame(height: 3)
                            if let remaining = quota.remaining {
                                Capsule().fill(tint).frame(width: geometry.size.width * min(100, max(0, remaining)) / 100, height: 3)
                            }
                            // The pace marker: what would remain now if the window were spent evenly.
                            if !quota.stale, quota.remaining != nil, let pace = quota.paceRemaining() {
                                RoundedRectangle(cornerRadius: 0.75).fill(Color.primary.opacity(0.55))
                                    .frame(width: 1.5, height: 9)
                                    .offset(x: max(0, geometry.size.width * pace / 100 - 0.75))
                            }
                        }.frame(width: geometry.size.width, height: 9, alignment: .leading)
                    }.frame(height: 9)
                    if primary, let reset = quota.resetAt {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.arrow.circlepath")
                            if reset > Date() { Text(reset, style: .relative); Text("后重置") }
                            else { Text("等待客户端更新") }
                            if reset > Date(), !quota.stale, quota.remaining != nil, quota.paceRemaining() != nil {
                                Text("·")
                                if let runOut = quota.projectedRunOut() {
                                    Text("按当前节奏约").foregroundStyle(Theme.attention)
                                    Text(runOut, style: .relative).foregroundStyle(Theme.attention)
                                    Text("后用完").foregroundStyle(Theme.attention)
                                } else {
                                    Text("按当前节奏够用").foregroundStyle(Theme.accent)
                                }
                            }
                        }.font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }.help(tooltip(quota)).accessibilityElement(children: .combine)
            }
        }
    }
}

/// One session in the card. It takes plain values rather than observing AppState, so
/// an unrelated state change (or a switch of agents) skips every row that is unchanged.
/// Actions still go through `state`; the open request's card observes it on its own.
private struct AgentDockSessionView: View, Equatable {
    let state: AppState
    let row: AgentDockSessionRow
    let selectedRequestID: String?
    let showSource: Bool
    /// What the running turn is doing right now, when the live monitor knows this session.
    let phase: WorkPhase?
    let replyPreviews: Bool
    let messageStatus: String?
    let delivery: String?
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row && lhs.selectedRequestID == rhs.selectedRequestID && lhs.showSource == rhs.showSource &&
            lhs.phase == rhs.phase && lhs.replyPreviews == rhs.replyPreviews &&
            lhs.messageStatus == rhs.messageStatus && lhs.delivery == rhs.delivery
    }
    private var session: AgentDockSession { row.session }
    private var selected: AgentInteraction? { row.requests.first { $0.id == selectedRequestID } }
    private var displayEvent: AgentSessionEvent {
        selected.map { $0.request.isQuestion ? .input : .approval } ?? row.event
    }
    private var eventLabel: String {
        if let request = selected ?? row.requests.first {
            if !request.fresh { return "连接中断" }
            switch request.phase {
            case .sending: return "发送中…"
            case .confirming: return "已发送 · 待确认"
            case .uncertain: return "结果待确认"
            case .failed: return "发送失败"
            case .ready: break
            }
        }
        switch displayEvent {
        case .input: return "待回答"
        case .approval: return "待审批"
        case .finished: return "已完成"
        case .working: return phase.map { $0.title.replacingOccurrences(of: "正在", with: "") } ?? "运行中"
        case .recent: return session.status
        }
    }
    private var eventSymbol: String {
        switch displayEvent {
        case .input: return "questionmark.bubble"
        case .approval: return "hand.raised"
        case .finished: return "checkmark.circle"
        case .working:
            switch phase {
            case .tool: return "wrench.and.screwdriver"
            case .thinking: return "ellipsis.bubble"
            case .replying: return "text.bubble"
            default: return "waveform"
            }
        case .recent: return "clock"
        }
    }
    private var eventColor: Color {
        switch displayEvent { case .input, .approval: return Theme.attention; case .finished: return Theme.accent; default: return .secondary }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                if showSource { AgentMark(source: session.source, size: 14).padding(.top, 1) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    HStack(spacing: 5) {
                        Label(eventLabel, systemImage: eventSymbol).foregroundStyle(eventColor)
                            .help((selected ?? row.requests.first)?.status ?? session.status)
                        if row.requests.count > 1 { Text("\(row.requests.count)").foregroundStyle(Theme.attention) }
                        if displayEvent == .working, let started = session.turnStartedAt {
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                Text(Self.runningLabel(since: started, now: context.date)).foregroundStyle(.secondary)
                                    .help("本轮开始于 " + started.formatted(date: .omitted, time: .shortened))
                            }
                        }
                        if let project = session.project { Text(project).lineLimit(1).foregroundStyle(.secondary) }
                        if row.event == .finished {
                            Spacer(minLength: 0)
                            Text(row.eventAt, format: .dateTime.hour().minute()).foregroundStyle(.secondary).help(row.eventAt.formatted())
                        }
                    }.font(.system(size: 9))
                }
                Spacer(minLength: 0)
                if !row.requests.isEmpty {
                    if selected == nil {
                        Button {
                            state.agentInteractionSelectionID = row.requests[0].id
                            state.agentInteractionInputID = nil
                        } label: { Image(systemName: "chevron.down").frame(width: 24, height: 24) }
                            .buttonStyle(.plain).foregroundStyle(Theme.attention).help("处理这个会话的请求")
                            .accessibilityLabel("处理请求：" + session.title)
                    } else if let selected {
                        Button { state.openAgentInteraction(selected.id) } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10)).frame(width: 24, height: 24)
                        }.buttonStyle(.plain).foregroundStyle(.secondary).help("在独立浮窗中处理长内容")
                            .accessibilityLabel("展开待处理请求").accessibilityIdentifier("agent-interaction-expand")
                    }
                } else if session.navigationURL != nil || session.resumeCommand != nil {
                    Button { state.openAgentSession(session) } label: {
                        Image(systemName: session.navigationURL != nil ? "arrow.up.forward" : "doc.on.doc")
                            .font(.system(size: 10)).frame(width: 24, height: 24)
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                        .help(session.navigationURL != nil ? "回到原会话" : "复制恢复命令，在原终端继续")
                        .accessibilityLabel((session.navigationURL != nil ? "回到原会话：" : "复制恢复命令：") + session.title)
                }
            }
            if let selected {
                if row.requests.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(Array(row.requests.enumerated()), id: \.element.id) { index, request in
                            Button("\(index + 1)") {
                                state.agentInteractionSelectionID = request.id; state.agentInteractionInputID = nil
                            }.buttonStyle(.plain).font(.system(size: 10)).frame(width: 22, height: 22)
                                .background(request.id == selected.id ? Theme.wellStrong : .clear, in: RoundedRectangle(cornerRadius: 5))
                                .help(request.request.summary).accessibilityLabel("请求 \(index + 1)：" + request.request.summary)
                        }
                    }
                }
                AgentInteractionCardView(state: state, interaction: selected, showActions: false, showHeader: false, embedded: true)
                // The decision sits with the request it answers; the card pins a copy
                // to its bottom only while this one has scrolled out of view.
                AgentInteractionActionsView(state: state, interaction: selected).reportsStickyFrame(.actions)
            } else if !row.requests.isEmpty {
                Text(row.requests[0].request.summary).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            } else if replyPreviews, let reply = session.reply, !reply.isEmpty {
                AgentReplySummary(session: session, show: state.showAgentReplyPreview, hide: state.hideAgentReplyPreview)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if row.requests.isEmpty, row.event == .approval || row.event == .input {
                Text("请到原会话处理，客户端暂未提供可回答的请求。").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let status = messageStatus {
                Text(status).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if let delivery, selected != nil {
                Text(delivery).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 10).padding(.horizontal, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { if selected != nil { Color.clear.reportsStickyFrame(.item) } }
            .accessibilityElement(children: .contain).accessibilityIdentifier("agent-session-" + session.id)
    }
    static func runningLabel(since start: Date, now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(start)) / 60)
        if minutes < 1 { return "刚开始" }
        if minutes < 60 { return "已运行 \(minutes) 分钟" }
        return "已运行 \(minutes / 60) 小时" + (minutes % 60 > 0 ? " \(minutes % 60) 分" : "")
    }
}

/// The local sessions that used the most tokens, a hint at where a quota went.
private struct AgentDockTopSessions: View {
    let sessions: [AgentDockSession]
    let showSource: Bool
    private var ranked: [AgentDockSession] {
        Dictionary(sessions.map { ($0.dockIdentity, $0) }, uniquingKeysWith: { $0.observedAt >= $1.observedAt ? $0 : $1 }).values
            .filter { Self.total($0) > 0 }
            .sorted { Self.total($0) != Self.total($1) ? Self.total($0) > Self.total($1) : $0.dockIdentity < $1.dockIdentity }
            .prefix(3).map { $0 }
    }
    static func total(_ session: AgentDockSession) -> Int { max(0, session.tokensIn) + max(0, session.tokensOut) + max(0, session.cacheRead) }
    var body: some View {
        if !ranked.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text("最费的会话").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                ForEach(ranked) { session in
                    HStack(spacing: 6) {
                        if showSource { AgentMark(source: session.source, size: 12) }
                        Text(session.title).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(TokenFormat.short(Self.total(session))).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11))
                    .help(session.title + "\n" + Self.total(session).formatted(.number.locale(Locale(identifier: "zh_CN")))
                          + " Token（输入、输出与缓存读取，本机会话累计）")
                }
            }
            .padding(.top, 16).accessibilityElement(children: .contain).accessibilityIdentifier("cat-dock-top-sessions")
        }
    }
}
