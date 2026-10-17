import AppKit
import SwiftUI
import WhileCore

/// Shared colours, type and small controls for the menu bar panel and windows.
/// Everything adapts to light and dark appearance; system colours carry the rest.
enum Theme {
    /// The one green. Text, selection, quota rings, the Codex mark and "working" all use it.
    static let accentColor = NSColor.adaptive(light: 0x237E60, dark: 0x8EDCC1)
    static let accent = Color(nsColor: accentColor)
    /// Paper and ink surfaces shared by the dock, its card, the panel and settings.
    static let surfaceColor = NSColor.adaptive(light: 0xFAFAFC, dark: 0x060708)
    static let surface = Color(nsColor: surfaceColor)
    static let gold = Color(nsColor: .adaptive(light: 0xA66F1C, dark: 0xE5B75C))
    static let attention = Color(nsColor: .adaptive(light: 0x94601C, dark: 0xE5B75C))
    static let attentionBadge = Color(nsColor: .adaptive(light: 0xF0CC83, dark: 0xE5B75C))
    /// Request badge glyphs ("?", "!", counts) on `attentionBadge`.
    static let badgeInk = Color(rgb: 0x211B0D)
    /// Completion badge and its paw print.
    static let accentBadge = Color(rgb: 0x8EDCC1)
    static let accentBadgeInk = Color(rgb: 0x0F3B2C)
    /// Secondary glyphs drawn outside native controls, such as the dock's three dots.
    static let inkSecondary = Color(nsColor: .adaptive(light: 0x505660, dark: 0xCDD2DA))
    static let silver = Color(nsColor: .adaptive(light: 0x8B939C, dark: 0xC3CAD2))
    static let working = accent
    /// A quiet fill for grouped rows sitting on window or panel material.
    static let well = Color(nsColor: .adaptive(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.045, darkAlpha: 0.06))
    static let wellStrong = Color(nsColor: .adaptive(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.075, darkAlpha: 0.1))
    static let heroEdge = Color(nsColor: .adaptive(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.7, darkAlpha: 0.08))

    static let panelCornerRadius: CGFloat = 14

    static let spring = Motion.base
    static let quick = Motion.snap

    static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

/// One set of timings for SwiftUI and Core Animation: a light spring, a little
/// cat-like bounce. With Reduce Motion every spring becomes the short fade.
enum Motion {
    static let fast = Animation.easeOut(duration: 0.15)
    static let snap = Animation.spring(duration: 0.25, bounce: 0.15)
    static let base = Animation.spring(duration: 0.38, bounce: 0.22)
    static let slow = Animation.easeInOut(duration: 0.6)
    /// One full left-right-left swing of a working client mark.
    static let swingPeriod: CFTimeInterval = 2.4

    static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation { reduceMotion ? fast : animation }
    static func springAnimation(keyPath: String, base: Bool = true) -> CASpringAnimation {
        let spring = CASpringAnimation(perceptualDuration: base ? 0.38 : 0.25, bounce: base ? 0.22 : 0.15)
        spring.keyPath = keyPath
        spring.duration = spring.settlingDuration
        return spring
    }
}

extension NSColor {
    static func adaptive(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        }
    }

    /// A dynamic colour pinned to light or dark, for drawing outside a view's appearance.
    func resolved(dark: Bool) -> NSColor {
        var color = self
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            color = self.usingColorSpace(.sRGB) ?? self
        }
        return color
    }

    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }
}

/// Soft press and hover feedback for tiles and inline actions.
struct PressableButtonStyle: ButtonStyle {
    var hoverFill = true
    func makeBody(configuration: Configuration) -> some View {
        PressableBody(configuration: configuration, hoverFill: hoverFill)
    }
    private struct PressableBody: View {
        let configuration: ButtonStyleConfiguration
        let hoverFill: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .background {
                    if hoverFill {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.wellStrong.opacity(hovering && enabled ? 1 : 0))
                    }
                }
                .scaleEffect(configuration.isPressed ? 0.965 : 1)
                .opacity(enabled ? 1 : 0.45)
                .animation(Theme.quick, value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .onHover { hovering = $0 }
                .contentShape(Rectangle())
        }
    }
}

/// The one filled action in a request: mint with ink that reads in both appearances.
struct DockPrimaryButtonStyle: ButtonStyle {
    static let ink = Color(nsColor: .adaptive(light: 0xFFFFFF, dark: 0x0F3B2C))
    func makeBody(configuration: Configuration) -> some View {
        DockPrimaryBody(configuration: configuration)
    }
    private struct DockPrimaryBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DockPrimaryButtonStyle.ink)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(Theme.accent.opacity(enabled ? 1 : 0.35), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .animation(Motion.snap, value: configuration.isPressed)
                .contentShape(Rectangle())
        }
    }
}

/// A compact icon + label action used in panel footers and card headers.
struct InlineAction: View {
    let title: String
    let symbol: String
    var tint: Color = .primary
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 8).padding(.vertical, 5)
        }
        .buttonStyle(PressableButtonStyle())
    }
}

/// The card the cat sits in: a misty morning wood in light mode, a night wood in dark
/// mode, with the light gathered where the cat is. The front hill lines up with the
/// ground of the Rive artboard when the cat fills the card's height.
struct ForestBackdrop: View {
    var cornerRadius: CGFloat = 14
    /// Where the cat sits, as a fraction of the width.
    var focus: CGFloat = 0.2
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let card = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Canvas { context, size in
            let w = size.width, h = size.height
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                Gradient(colors: dark ? [Color(rgb: 0x152832), Color(rgb: 0x0B161B)] : [Color(rgb: 0xEFF5F2), Color(rgb: 0xDCE8E4)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
            let centre = CGPoint(x: w * focus, y: h * 0.55)
            context.fill(Path(ellipseIn: CGRect(x: centre.x - h, y: centre.y - h, width: 2 * h, height: 2 * h)), with: .radialGradient(
                Gradient(colors: dark ? [Color(rgb: 0x8EDCC1).opacity(0.16), Color(rgb: 0x8EDCC1).opacity(0)]
                                      : [Color.white.opacity(0.75), Color.white.opacity(0)]),
                center: centre, startRadius: 0, endRadius: h))
            let trunk = dark ? Color(rgb: 0x0C1A20).opacity(0.85) : Color(rgb: 0xD0DFDA).opacity(0.45)
            for (x, width) in [(0.03, 8.0), (0.37, 5.0), (0.84, 7.0), (0.95, 10.0)] as [(CGFloat, CGFloat)] {
                context.fill(Path(roundedRect: CGRect(x: w * x, y: -4, width: width, height: h + 8), cornerRadius: width / 2),
                             with: .color(trunk))
            }
            var back = Path()
            back.move(to: CGPoint(x: 0, y: h * 0.8))
            back.addCurve(to: CGPoint(x: w * 0.55, y: h * 0.79), control1: CGPoint(x: w * 0.18, y: h * 0.7),
                          control2: CGPoint(x: w * 0.36, y: h * 0.85))
            back.addCurve(to: CGPoint(x: w, y: h * 0.72), control1: CGPoint(x: w * 0.72, y: h * 0.73),
                          control2: CGPoint(x: w * 0.86, y: h * 0.68))
            back.addLines([CGPoint(x: w, y: h), CGPoint(x: 0, y: h)])
            back.closeSubpath()
            context.fill(back, with: .color(dark ? Color(rgb: 0x11232B) : Color(rgb: 0xD5E3DE)))
            var front = Path()
            front.move(to: CGPoint(x: 0, y: h * 0.91))
            front.addCurve(to: CGPoint(x: w, y: h * 0.9), control1: CGPoint(x: w * 0.35, y: h * 0.87),
                           control2: CGPoint(x: w * 0.7, y: h * 0.96))
            front.addLines([CGPoint(x: w, y: h), CGPoint(x: 0, y: h)])
            front.closeSubpath()
            context.fill(front, with: .color(dark ? Color(rgb: 0x14303A) : Color(rgb: 0xC9DAD4)))
        }
        .clipShape(card)
        .overlay(card.strokeBorder(Theme.heroEdge, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

extension Color {
    init(rgb: UInt32) { self.init(nsColor: NSColor(rgb: rgb)) }
}

/// Pulsing dot that shows whether an AI client is currently working.
struct ActivityDot: View {
    let active: Bool
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            if active && !reduceMotion {
                Circle().fill(Theme.working.opacity(0.35))
                    .scaleEffect(pulse ? 2.2 : 1).opacity(pulse ? 0 : 1)
            }
            Circle().fill(active ? Theme.working : Color.secondary.opacity(0.5))
        }
        .frame(width: 6, height: 6)
        .onAppear { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true } }
        .accessibilityHidden(true)
    }
}

/// The panel's own background: the dock's solid paper/ink, or frosted glass when
/// chosen, in which case the window's vibrancy shows through.
struct PanelSurface: ViewModifier {
    let material: PanelMaterial
    var radius: CGFloat = Theme.panelCornerRadius
    func body(content: Content) -> some View {
        content.background {
            if material == .solid {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.surface)
            }
        }
    }
}

/// Medal glyph shared by the collection cards and detail views.
struct MedalBadge: View {
    let medal: FishingMedal
    var body: some View {
        Image(systemName: "medal.fill")
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(medal == .gold ? Theme.gold : Theme.silver)
            .accessibilityLabel(medal.title)
    }
}
