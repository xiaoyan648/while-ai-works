import Foundation

/// A confirmed rise in an account's usage resets; `preview` builds a sample event for snapshots.
public struct ResetCreditGrant: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let account: AccountObservation
    /// The reading that confirmed the rise.
    public let credits: CodexResetCredits
    /// How many resets the account gained since the previous reading.
    public let added: Int
    /// The gained credits when the provider lists them, first to expire first. Their ids name the event for every
    /// Mac that reads the same account.
    public let newCredits: [CodexResetCredits.Credit]
    public let isPreview: Bool

    public init(account: AccountObservation, credits: CodexResetCredits, added: Int,
                newCredits: [CodexResetCredits.Credit] = [], isPreview: Bool = false) {
        id = UUID()
        self.account = account
        self.credits = credits
        self.added = added
        self.newCredits = newCredits
        self.isPreview = isPreview
    }

    public static func preview(now: Date = Date()) -> ResetCreditGrant {
        let credits = CodexResetCredits(availableCount: 2, credits: [14, 30].map { days in
            .init(id: "preview-\(days)", expiresAt: now.addingTimeInterval(Double(days) * 86400).timeIntervalSince1970)
        })
        let account = AccountObservation(account: .identified(provider: "Codex", user: "preview", workspace: nil)!,
                                         label: "me@example.com", plan: "plus", observedAt: now, resetCredits: credits)
        return ResetCreditGrant(account: account, credits: credits, added: 1, newCredits: [credits.creditsByExpiry[1]], isPreview: true)
    }
}

/// One count history per account decides when usage resets were added. Using a reset or letting one expire lowers
/// the count and is not an event.
public struct ResetCreditTracker: Sendable {
    private struct Observation: Sendable {
        let observedAt: Date
        let count: Int
        /// The last listed credit ids; a count-only reading keeps the earlier list.
        let ids: Set<String>?
    }
    private var previous: [String: Observation] = [:]

    public init() {}

    public mutating func update(report: UsageReport, now: Date) -> [ResetCreditGrant] {
        let accountIDs = Set(report.accountObservations.map(\.account.id))
        previous = previous.filter { accountIDs.contains($0.key) }
        var result: [ResetCreditGrant] = []
        for id in accountIDs.sorted() {
            guard let account = report.observation(accountID: id) else { continue }
            let reading = report.assess(.account(account), now: now)
            // Signing back in to an account is a new baseline, not a grant observed while it was away.
            guard reading.isCurrentAccount else { previous[id] = nil; continue }
            guard let credits = account.resetCredits, reading.confirmsEvents else { continue }
            let old = previous[id]
            guard old == nil || account.observedAt > old!.observedAt else { continue }
            previous[id] = Observation(observedAt: account.observedAt, count: credits.availableCount,
                                       ids: credits.credits.map { Set($0.map(\.id)) } ?? old?.ids)
            guard let old, credits.availableCount > old.count else { continue } // The first reading is a silent baseline.
            let newCredits = old.ids.map { known in credits.creditsByExpiry.filter { !known.contains($0.id) } } ?? []
            result.append(ResetCreditGrant(account: account, credits: credits, added: credits.availableCount - old.count,
                                           newCredits: newCredits))
        }
        return result
    }
}
