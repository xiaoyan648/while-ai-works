import Foundation

/// Fixed application policy. No threshold values are stored or synchronized.
public enum AlertPolicy {
    public static let warningUsed: Double = 70
    public static let criticalUsed: Double = 90
    /// Remaining % at or below which a window is exhausted: for its alerts, its outlook, its row and its cap hits alike.
    public static let exhaustedRemaining: Double = 0.5
    /// Old observations remain visible but must not generate new quota alerts.
    public static let maximumReadingAge: TimeInterval = 30 * 60
    /// Readings wobble by a point or two between queries; only a larger rise is a reset.
    public static let resetRise: Double = 5
    /// How far back a window's insights read its stored readings.
    public static let insightsLookback: TimeInterval = 7 * 86400
    /// The balance at or below which an account runs low, by currency. A balance in any other currency is fine until it
    /// runs out.
    public static let balanceWarnings: [String: Decimal] = ["CNY": 10, "USD": 2]

    public static func quotaLevel(remaining: Double) -> StatusLevel {
        StatusLevel.resolve(remainingPct: remaining, warnPct: 100 - warningUsed, critPct: 100 - criticalUsed)
    }

    /// A balance's rung on the one ladder every currency climbs: depleted (critical) at or below zero, low (warning) at or
    /// below its currency's line, else fine (ok). Nil only for an amount that is not a number.
    public static func balanceLevel(remaining: Decimal, currency: String) -> StatusLevel? {
        guard !remaining.isNaN else { return nil }
        if remaining <= 0 { return .critical }
        return balanceWarnings[currency].map { remaining <= $0 } == true ? .warning : .ok
    }

    /// An API account's level: critical while its service marks it unavailable, even with no balance to show, else
    /// the lowest of its balances' levels.
    public static func balanceLevel(_ balances: [AccountBalance], isAvailable: Bool?) -> StatusLevel? {
        if isAvailable == false { return .critical }
        let levels = balances.compactMap { balanceLevel(remaining: $0.total, currency: $0.currency) }
        return levels.contains(.critical) ? .critical : levels.contains(.warning) ? .warning : levels.first
    }
}
