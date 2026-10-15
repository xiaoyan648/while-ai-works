import AgentHUDSupport
import Foundation

/// Estimated money in one 15-minute period of one billing account.
public struct CostBucket: Hashable, Codable, Sendable {
    public let start: Date
    /// Exact sums by currency. A currency is absent when an event in the period had no price in it.
    public let amounts: [String: Decimal]

    public init(start: Date, amounts: [String: Decimal]) {
        self.start = start
        self.amounts = amounts
    }

    public var end: Date { start.addingTimeInterval(UsageBucket.duration) }
    public func overlaps(_ interval: DateInterval) -> Bool { end > interval.start && start < interval.end }
}
