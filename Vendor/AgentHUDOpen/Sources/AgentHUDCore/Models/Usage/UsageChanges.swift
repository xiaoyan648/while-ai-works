import Foundation

/// What a newly displayed report changed compared with the one before, by kind of data. Publishers such as a synchronization
/// service subscribe to these instead of comparing reports themselves.
public struct UsageChanges: Hashable, Sendable {
    /// 15-minute token totals or cost totals.
    public var usage = false
    /// Quota windows, their metrics, balances, reset credits and plan names.
    public var readings = false
    /// Sessions added, changed or removed, by id.
    public var sessions: Set<String> = []
    /// Turn observations.
    public var turns = false
    /// Completions the previous report did not have.
    public var completions: [SessionCompletion] = []
    /// Discovered agents, model consumers, accounts, services, notices and indexing progress.
    public var inventory = false

    public init() {}

    public var isEmpty: Bool { !usage && !readings && sessions.isEmpty && !turns && completions.isEmpty && !inventory }

    /// Every kind of data counts as changed when there was no previous report.
    public init(from old: UsageReport?, to new: UsageReport) {
        usage = old?.usage != new.usage || old.map { Self.costs($0) } != Self.costs(new)
        readings = old?.snapshots != new.snapshots || old?.insightsByAgent != new.insightsByAgent
            || old.map { Self.balances($0) } != Self.balances(new) || old?.codexResetCredits != new.codexResetCredits
            || old?.codexResetCreditsObservedAt != new.codexResetCreditsObservedAt || old?.subscriptions != new.subscriptions
        let before = Dictionary((old?.sessions ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(new.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        sessions = Set(after.filter { id, session in before[id].map { !$0.hasSameContent(as: session) } ?? true }.keys)
            .union(before.keys.filter { after[$0] == nil })
        turns = old?.turns != new.turns
        let known = Set((old?.completions ?? []).map(\.id))
        completions = new.completions.filter { !known.contains($0.id) }
        inventory = old?.discoveredAgents != new.discoveredAgents || old?.consumers != new.consumers || old?.accounts != new.accounts
            || old?.services != new.services || old?.activeQuotaPoolIDs != new.activeQuotaPoolIDs || old?.notice != new.notice
            || old?.sourceNotices != new.sourceNotices || old?.quotaNotices != new.quotaNotices || old?.readingIssues != new.readingIssues
            || old?.indexing != new.indexing
    }

    private static func costs(_ report: UsageReport) -> [String: [CostBucket]] {
        Dictionary(report.billing.map { ($0.id, $0.costs) }, uniquingKeysWith: { first, _ in first })
    }

    private struct BalanceReading: Hashable {
        let balances: [AccountBalance]
        let updatedAt: Date?
        let isAvailable: Bool?
        let notice: String?
        let readingIssue: ReadingIssue?
    }

    private static func balances(_ report: UsageReport) -> [String: BalanceReading] {
        Dictionary(report.billing.map {
            ($0.id, BalanceReading(balances: $0.balances, updatedAt: $0.updatedAt, isAvailable: $0.isAvailable, notice: $0.notice,
                                   readingIssue: $0.readingIssue))
        },
                   uniquingKeysWith: { first, _ in first })
    }
}

private extension LiveSession {
    /// A provider refreshes `observedAt` whenever it checks a session; only the session's own data is a change.
    func hasSameContent(as other: LiveSession) -> Bool {
        id == other.id && agentId == other.agentId && task == other.task && terminal == other.terminal && startedAt == other.startedAt
            && endedAt == other.endedAt && pctOfWindow == other.pctOfWindow && tokensIn == other.tokensIn && tokensOut == other.tokensOut
            && cacheReadTokens == other.cacheReadTokens && client == other.client && transcriptPath == other.transcriptPath
            && accountWide == other.accountWide && lastActivityAt == other.lastActivityAt && navigationTarget == other.navigationTarget
            && usageKey == other.usageKey
    }
}
