import Foundation

/// Serves the sample data (`DemoData`) as a provider serves what it read.
public struct DemoUsageProvider: UsageProvider {
    public init() {}

    public func fetchUsage(agents: [AgentDescriptor], historyHours: Int) async throws -> UsageReport {
        let now = DemoClock.now
        return Self.report(agents: agents, historyHours: historyHours, now: now)
    }

    /// The sample as a report of `agents`: readings for the windows among them, and the sample's sessions, models and
    /// tokens whichever rows are shown.
    /// - stage: what a playing script has set; the fixed demo without one.
    public static func report(agents: [AgentDescriptor], historyHours: Int, now: Date,
                              stage: DemoStage? = DemoStageBox.current) -> UsageReport {
        let consumers = DemoData.consumers
        func models(of vendor: String) -> Set<String> { Set(consumers.filter { $0.vendor == vendor }.map(\.id)) }
        var insights: [String: UsageInsights] = [:], consumerIdsByQuota: [String: Set<String>] = [:]
        for row in agents {
            guard let made = DemoData.insights(for: row, now: now, stage: stage) else { continue }
            insights[row.id] = made
            // Every Claude model spends from the session and the week, Fable from its own week too; every Codex model
            // from the plan's window, and none of the sample's from Spark's.
            switch row.windowKey {
            case "claude-session", "claude-weekly": consumerIdsByQuota[row.id] = models(of: "Claude")
            case "claude-weekly-fable": consumerIdsByQuota[row.id] = models(of: "Claude").filter { $0.contains("fable") }
            case "codex": consumerIdsByQuota[row.id] = models(of: "Codex")
            default: break
            }
        }
        let shown = Set(agents.compactMap(\.account?.id))
        let accounts = DemoData.accounts(now: now).compactMapValues { observed -> [AccountObservation]? in
            let kept = observed.filter { shown.contains($0.account.id) }
            return kept.isEmpty ? nil : kept
        }
        let usage = DemoData.usage(now: now), named = DemoData.agents
        var periods = UsagePeriods()
        periods.add(usage, endingAt: now)
        return UsageReport(
            generatedAt: now,
            snapshots: DemoData.snapshots(for: agents, now: now, stage: stage),
            sessions: DemoData.sessions(now: now, stage: stage),
            // The demo reports the rows it was given, as a provider reports the rows it read: the sample's own as it names
            // them now, so a window a provider words in the interface's language follows that language.
            discoveredAgents: agents.map { row in named.first { $0.id == row.id } ?? row },
            consumers: consumers,
            usage: usage,
            insightsByAgent: insights,
            subscriptions: ["Claude": "max_20x", "Codex": "pro"],
            consumerIdsByQuota: consumerIdsByQuota,
            billing: agents.contains { $0.vendor == "DeepSeek" } ? [DemoData.deepSeekBilling(now: now)] : [],
            codexResetCredits: DemoData.codexResetCredits(now: now),
            completions: stage?.completions ?? [],
            accounts: accounts.isEmpty ? nil : accounts,
            sessionUsage: DemoData.sessionUsage(now: now),
            periods: periods
        )
    }
}
