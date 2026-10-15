import Foundation

/// Decides which completed turns and quota events are new. The island presents each update, and a host that relays
/// the same events elsewhere reads that update instead of keeping its own history, so both agree on what is new.
public struct IslandEventTracker: Sendable {
    /// A quota window that crossed a threshold, with the reading that crossed it.
    public struct Crossing: Hashable, Sendable {
        public let agent: AgentDescriptor
        public let snapshot: UsageSnapshot

        public init(agent: AgentDescriptor, snapshot: UsageSnapshot) {
            self.agent = agent
            self.snapshot = snapshot
        }
    }

    public struct Update: Sendable {
        /// Newly completed turns of clients whose Live status is on, oldest first.
        public var completions: [SessionCompletion]
        /// Island quota events: warnings, exhaustion and confirmed resets.
        public var quotaAlerts: [QuotaAlert]
        /// Windows that reached zero in this update, in agent order.
        public var exhaustedWindows: [Crossing]
        /// Windows that crossed the critical threshold without also reaching zero, in agent order.
        public var criticalWindows: [Crossing]
        /// Accounts that gained usage resets in this update.
        public var resetCreditGrants: [ResetCreditGrant]

        public init(completions: [SessionCompletion] = [], quotaAlerts: [QuotaAlert] = [],
                    exhaustedWindows: [Crossing] = [], criticalWindows: [Crossing] = [],
                    resetCreditGrants: [ResetCreditGrant] = []) {
            self.completions = completions
            self.quotaAlerts = quotaAlerts
            self.exhaustedWindows = exhaustedWindows
            self.criticalWindows = criticalWindows
            self.resetCreditGrants = resetCreditGrants
        }
    }

    private let startedAt: Date
    private var seenCompletions: Set<String> = []
    private var quotas = QuotaAlertTracker()
    private var resetCredits = ResetCreditTracker()

    /// Completions at or before `startedAt` are history, not events.
    public init(startedAt: Date = Date()) { self.startedAt = startedAt }

    public mutating func update(report: UsageReport, agents: [AgentDescriptor], now: Date, settings: Settings = Settings()) -> Update {
        var result = Update()
        for completion in report.completions.sorted(by: { $0.completedAt < $1.completedAt }) {
            guard completion.completedAt > startedAt, completion.completedAt <= now,
                  seenCompletions.insert(completion.id).inserted else { continue }
            // Consume suppressed events as well, so enabling live status never replays them.
            var event = completion
            if event.vendor == "Grok", event.client == nil {
                event.client = report.sessions.first { $0.id == event.sessionID }?.client
            }
            guard settings.liveStatusEnabled(for: event.agentVendor) else { continue }
            result.completions.append(event)
        }
        let quota = quotas.update(report: report, agents: agents, now: now)
        result.quotaAlerts = quota.alerts
        for agent in agents {
            guard quota.exhaustedAgentIDs.contains(agent.id) || quota.criticalAgentIDs.contains(agent.id),
                  let snapshot = report.snapshot(for: agent.id) else { continue }
            // Running out supersedes the critical warning when both land in the same reading.
            if quota.exhaustedAgentIDs.contains(agent.id) {
                result.exhaustedWindows.append(Crossing(agent: agent, snapshot: snapshot))
            } else {
                result.criticalWindows.append(Crossing(agent: agent, snapshot: snapshot))
            }
        }
        result.resetCreditGrants = resetCredits.update(report: report, now: now)
        return result
    }
}
