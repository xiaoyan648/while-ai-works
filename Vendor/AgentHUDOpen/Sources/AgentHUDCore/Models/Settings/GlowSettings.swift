import Foundation

/// Everything that decides how a glow looks and moves.
///
/// These live together because they are set together and, since a HUD belongs to a screen, they are set per
/// screen: a notch wants a rim and an external display's logo queue wants a curtain, and the two want
/// different styles, reaches and speeds. `Settings` keeps one of these as the default and one per display
/// that has been given its own.
public struct GlowSettings: Hashable, Codable, Sendable {
    /// A collapsed island or a logo queue's backdrop can afford this much; a panel tall enough to fill the
    /// screen cannot, and shrinks its glow to fit through `GlowGeometry.fitted(within:)`.
    public static let sizeRange: ClosedRange<Double> = 0...36
    public static let breathSecondsRange: ClosedRange<Double> = 1...24
    // Depth is what the logo queue's backdrop needed, not a coarser grid: past this the marks stop reading
    // as a field and start reading as scattered shapes, and density past 150% is solid either way.
    public static let gridPitchRange: ClosedRange<Double> = 4...12
    /// Rows, both of them. Kept short on purpose: the cell count is the width times these, and a backdrop
    /// as wide as a logo queue pays for every row of it.
    public static let gridCoreRange: ClosedRange<Double> = 0...8
    public static let gridFadeRange: ClosedRange<Double> = 0...8
    public static let gridDensityRange: ClosedRange<Double> = 0.5...1.5

    public var style: GlowStyle = .blur
    public var effect: GlowEffect = .breathe
    /// Breath period while an agent is working.
    public var breathSeconds: Double = 3
    /// Breath period while every agent is idle. The glow never stops; it only slows down, so a resting HUD
    /// still reads as alive.
    public var idleBreathSeconds: Double = 7
    /// 0…1. Glow opacity oscillates between `1 - amplitude` and 1 (times brightness).
    public var breathAmplitude: Double = 0.6
    public var range: Double = 14
    public var blur: Double = 8
    /// Keep the island's rim dense and fade outward with distance.
    public var outwardOnly: Bool = true
    /// 0.2…1
    public var brightness: Double = 0.9
    /// Grid spacing in points for the dot and ASCII styles. A third of the notch height, as in the design.
    public var gridPitch: Double = 10
    /// Rows held at full strength before the glow begins to fade. Zero is a glow that fades from the rim.
    public var gridCore: Double = 0
    /// Rows the glow fades over. Five reads like the exponential falloff this replaced; the same number of
    /// rows under the new curve is denser, because it leaves the core flat instead of dropping at once.
    public var gridFade: Double = 5
    /// How much of its cell each dot or character fills; above 1 marks grow into their neighbours. The grid
    /// stays put.
    public var gridDensity: Double = 1

    public init() {}

    static func clamp(_ value: Double?, to range: ClosedRange<Double>, default fallback: Double) -> Double {
        guard let value, value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}
