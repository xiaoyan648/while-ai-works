import Foundation

/// Consumption speed of a quota window, in remaining-% per hour.
public struct BurnRate: Hashable, Sendable {
    public let pctPerHour: Double

    public init(pctPerHour: Double) {
        self.pctPerHour = pctPerHour
    }

    /// Seconds until `remainingPct` reaches zero at this rate.
    public func timeToExhaust(remainingPct: Double) -> TimeInterval? {
        guard pctPerHour > 0 else { return nil }
        return max(0, remainingPct) / pctPerHour * 3600
    }
}
