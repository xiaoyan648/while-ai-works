import Foundation

/// One reading of an API balance in one currency, kept in the usage ledger for its trend (`BalanceTrend`).
public struct BalanceSample: Hashable, Sendable {
    public let timestamp: Date
    public let amount: Decimal

    public init(timestamp: Date, amount: Decimal) {
        self.timestamp = timestamp
        self.amount = amount
    }
}
