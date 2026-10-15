import Foundation

/// When an API balance runs out at the pace it fell over the last day. A balance belongs to the account, so its fall
/// counts every Mac's spending and any spending outside Agent HUD; the estimate is rough and settles as readings come.
public enum BalanceTrend {
    /// How far back the trend reads, and how long the ledger keeps a balance's readings.
    public static let lookback: TimeInterval = 24 * 3600
    /// The shortest stretch of readings that gives an estimate.
    public static let minimumSpan: TimeInterval = 3 * 3600

    /// When the balance reaches zero at the pace it fell, as of the reading at `time`: the readings of the day before
    /// `time`, from the latest rise on, since a top-up starts the trend again. nil with readings spanning less than
    /// `minimumSpan`, without a fall, and for a balance at or below zero.
    public static func runsOutAt(_ samples: [BalanceSample], at time: Date) -> Date? {
        let recent = samples.filter { $0.timestamp <= time && time.timeIntervalSince($0.timestamp) <= lookback }
            .sorted { $0.timestamp < $1.timestamp }
        let start = recent.indices.dropFirst().last { recent[$0].amount > recent[$0 - 1].amount } ?? recent.startIndex
        let trend = recent[start...]
        guard let first = trend.first, let last = trend.last, last.amount > 0,
              last.timestamp.timeIntervalSince(first.timestamp) >= minimumSpan, first.amount > last.amount else { return nil }
        let perSecond = NSDecimalNumber(decimal: first.amount - last.amount).doubleValue / last.timestamp.timeIntervalSince(first.timestamp)
        return last.timestamp.addingTimeInterval(NSDecimalNumber(decimal: last.amount).doubleValue / perSecond)
    }
}
