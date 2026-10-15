import Foundation

public struct AccountBalance: Hashable, Codable, Sendable, Identifiable {
    public let currency: String
    public let total: Decimal
    public let granted: Decimal
    public let toppedUp: Decimal
    /// When the balance runs out at the pace it fell over the day before its reading (`BalanceTrend`); nil without an
    /// estimate.
    public let runsOutAt: Date?
    public var id: String { currency }

    public init(currency: String, total: Decimal, granted: Decimal, toppedUp: Decimal, runsOutAt: Date? = nil) {
        self.currency = currency; self.total = total; self.granted = granted; self.toppedUp = toppedUp; self.runsOutAt = runsOutAt
    }
}

/// Money remains independent of subscription percentages: a balance has no fixed denominator.
public struct APIBilling: Hashable, Codable, Sendable, Identifiable {
    public let vendor: String
    public let balances: [AccountBalance]
    public let isAvailable: Bool?
    public let updatedAt: Date?
    /// Estimated cost in 15-minute periods, ordered by start. No currency conversion is implied.
    public let costs: [CostBucket]
    /// Estimated cost of each session by currency; a currency is absent when one of its requests had no price in it.
    public let sessionCosts: [String: [String: Decimal]]
    /// The reason of `readingIssue`, written beside it for readers of the notice text; a balance saved without a typed
    /// issue counts it as a failed read.
    public let notice: String?
    /// A failed balance read keeps the last balance and its time.
    public let readingIssue: ReadingIssue?
    public var billingPool: BillingPool? = nil
    public var id: String { billingPool?.id ?? vendor }
    public var displayName: String { (billingPool?.provider ?? vendor) + " · API" }
    public var currency: String { balances.first?.currency ?? "CNY" }

    public init(vendor: String, balances: [AccountBalance], isAvailable: Bool?, updatedAt: Date?, costs: [CostBucket] = [],
                sessionCosts: [String: [String: Decimal]] = [:], notice: String?, readingIssue: ReadingIssue? = nil,
                billingPool: BillingPool? = nil) {
        self.vendor = vendor; self.balances = balances; self.isAvailable = isAvailable
        self.updatedAt = updatedAt; self.costs = costs; self.sessionCosts = sessionCosts; self.notice = notice
        self.readingIssue = readingIssue; self.billingPool = billingPool
    }

    /// The sum over periods overlapping `interval`; unknown when any of them lacks a price in `currency`.
    public func estimatedCost(currency: String, during interval: DateInterval? = nil) -> Decimal? {
        var total: Decimal = 0
        for bucket in costs where interval.map(bucket.overlaps) ?? true {
            guard let amount = bucket.amounts[currency] else { return nil }
            total += amount
        }
        return total
    }

    public func estimatedCost(currency: String, sessionId: String) -> Decimal? {
        sessionCosts[sessionId]?[currency]
    }
}

public extension APIBilling {
    func contains(_ model: AgentDescriptor) -> Bool {
        guard model.isAPIBilled else { return false }
        if let billingPool { return model.billingPool?.id == billingPool.id }
        return model.billingPool == nil && model.vendor == vendor
    }
}
