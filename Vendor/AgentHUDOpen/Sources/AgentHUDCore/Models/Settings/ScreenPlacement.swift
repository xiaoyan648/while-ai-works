import Foundation

/// How one screen presents the HUD.
public enum HUDMode: String, Codable, Sendable, CaseIterable {
    /// The island: the notch itself, or a bar standing in for one on displays without.
    case notch
    /// A queue of the agents' own logos, parked on a screen edge, with the glow behind them as a backdrop.
    case logos
    /// A small floating panel on a screen edge with no glow behind it: each agent's mark, with its tightest
    /// window as a ring round it, a percentage beside it, or both.
    case simple

    /// Parked on a screen edge and opening inward from it, rather than standing at the notch.
    public var isDocked: Bool { self != .notch }
}

/// The screen edge a HUD is parked on. It runs along that edge and opens inward.
public enum HUDEdge: String, Codable, Sendable, CaseIterable {
    case top, right, bottom, left

    public var isHorizontal: Bool { self == .top || self == .bottom }

    /// Unit vector pointing into the screen from this edge.
    public var inward: (x: Double, y: Double) {
        switch self {
        case .top: return (0, -1)
        case .bottom: return (0, 1)
        case .left: return (1, 0)
        case .right: return (-1, 0)
        }
    }
}

/// One screen's HUD. Everything here is per screen: two displays can run different modes, sit on
/// different edges and size their logos differently. The glow is per screen too, kept beside this in
/// `Settings.screenGlow` under the same display key, with `Settings.glow` for a display that has none.
public struct ScreenPlacement: Hashable, Codable, Sendable {
    /// Side of one mark in points, independent of the display's menu bar height.
    public static let logoSizeRange: ClosedRange<Double> = 12...36
    /// Distance from the visible logo, including its outline, to its parked screen edge, in points.
    public static let logoEdgeDistanceRange: ClosedRange<Double> = 0...20
    /// Gap between logos, as a share of the logo's height. A gap wider than about half a mark reads as
    /// separate marks rather than one queue.
    public static let gapScaleRange: ClosedRange<Double> = 0.1...0.6
    /// Diameter of one ring in Simple mode, in points. The marks and numbers are sized from it.
    public static let simpleSizeRange: ClosedRange<Double> = 16...40
    /// Stroke of that ring, in points.
    public static let ringWidthRange: ClosedRange<Double> = 1...4
    public var mode: HUDMode
    public var edge: HUDEdge
    /// The queue's centre along its edge, as a fraction of that edge's length, so it survives a
    /// resolution change.
    public var offset: Double
    public var logoSize: Double
    public var logoEdgeDistance: Double
    public var gapScale: Double
    /// Draw the marks. Turning them off leaves the backdrop alone — it still spans what the marks would
    /// have occupied, so the field keeps its place and its width; only the logos stop being drawn.
    public var showsLogos: Bool
    public var simpleSize: Double
    public var ringWidth: Double
    /// Simple mode draws each agent's tightest window as a ring round its mark.
    public var showsRings: Bool
    /// Simple mode writes the percentage used beside each mark.
    public var showsNumbers: Bool
    /// Simple mode turns a working agent's mark into its bot, and lets idle marks visit as bots.
    public var simpleBots: Bool
    /// A docked HUD answers for one agent at a time: hovering a mark opens that agent's own panel from the
    /// mark, and a request or reminder grows from the mark of the agent that sent it while the others stay.
    public var separatesAgents: Bool

    public init(
        mode: HUDMode = .logos,
        edge: HUDEdge = .top,
        offset: Double = 0.5,
        logoSize: Double = 20,
        logoEdgeDistance: Double = 2,
        gapScale: Double = 0.4,
        showsLogos: Bool = true,
        simpleSize: Double = 22,
        ringWidth: Double = 1.5,
        showsRings: Bool = true,
        showsNumbers: Bool = true,
        simpleBots: Bool = false,
        separatesAgents: Bool = false
    ) {
        self.mode = mode
        self.edge = edge
        self.offset = Self.clamp(offset, to: 0...1)
        self.logoSize = Self.clamp(logoSize, to: Self.logoSizeRange)
        self.logoEdgeDistance = Self.clamp(logoEdgeDistance, to: Self.logoEdgeDistanceRange)
        self.gapScale = Self.clamp(gapScale, to: Self.gapScaleRange)
        self.showsLogos = showsLogos
        self.simpleSize = Self.clamp(simpleSize, to: Self.simpleSizeRange)
        self.ringWidth = Self.clamp(ringWidth, to: Self.ringWidthRange)
        self.showsRings = showsRings
        self.showsNumbers = showsNumbers
        self.simpleBots = simpleBots
        self.separatesAgents = separatesAgents
    }

    /// A display's starting point: a notched screen keeps its island, anything else shows the queue.
    public static func `default`(hasNotch: Bool) -> ScreenPlacement {
        ScreenPlacement(mode: hasNotch ? .notch : .logos)
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value.isFinite ? value : range.lowerBound))
    }

    private enum CodingKeys: String, CodingKey {
        case mode, edge, offset, logoSize, logoEdgeDistance, gapScale, showsLogos
        case simpleSize, ringWidth, showsRings, showsNumbers, simpleBots, separatesAgents
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ScreenPlacement()
        self.init(
            mode: (try? c.decodeIfPresent(HUDMode.self, forKey: .mode)) ?? d.mode,
            edge: (try? c.decodeIfPresent(HUDEdge.self, forKey: .edge)) ?? d.edge,
            offset: try c.decodeIfPresent(Double.self, forKey: .offset) ?? d.offset,
            logoSize: try c.decodeIfPresent(Double.self, forKey: .logoSize) ?? d.logoSize,
            logoEdgeDistance: try c.decodeIfPresent(Double.self, forKey: .logoEdgeDistance) ?? d.logoEdgeDistance,
            gapScale: try c.decodeIfPresent(Double.self, forKey: .gapScale) ?? d.gapScale,
            showsLogos: try c.decodeIfPresent(Bool.self, forKey: .showsLogos) ?? d.showsLogos,
            simpleSize: try c.decodeIfPresent(Double.self, forKey: .simpleSize) ?? d.simpleSize,
            ringWidth: try c.decodeIfPresent(Double.self, forKey: .ringWidth) ?? d.ringWidth,
            showsRings: try c.decodeIfPresent(Bool.self, forKey: .showsRings) ?? d.showsRings,
            showsNumbers: try c.decodeIfPresent(Bool.self, forKey: .showsNumbers) ?? d.showsNumbers,
            simpleBots: try c.decodeIfPresent(Bool.self, forKey: .simpleBots) ?? d.simpleBots,
            separatesAgents: try c.decodeIfPresent(Bool.self, forKey: .separatesAgents) ?? d.separatesAgents
        )
    }
}
