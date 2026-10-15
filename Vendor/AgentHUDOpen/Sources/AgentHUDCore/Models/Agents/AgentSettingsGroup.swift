import Foundation

/// Joins observed account information to the existing ordered display windows.
public struct AgentSettingsGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let source: SourceStatus?
    /// Execution clients configured separately under this account provider.
    public let clients: [SourceStatus]
    public let agents: [AgentDescriptor]
    public let plans: [String]
    public let apiProviders: [String]
    /// Accounts the clients are currently signed in to, including plan pools.
    public let accounts: [AccountObservation]
    /// API balance identities remain available here even while their readings are hidden.
    public let billingAccounts: [APIBilling]

    public struct DisplayAccount: Identifiable, Equatable, Sendable {
        public let id: String
        public let displayName: String
        public let detail: String?
    }

    public struct WindowSection: Identifiable, Equatable, Sendable {
        public let id: String?
        public let title: String?
        public let agents: [AgentDescriptor]
    }

    /// Account sections follow their first window; every account's windows keep their manual order.
    /// Presentation groups the windows without changing their interleaved HUD order in the store.
    public var windowSections: [WindowSection] {
        let windows = Dictionary(grouping: agents, by: \.displayAccountID)
        let fallbackAccounts = unobservedAccounts
        var seen = Set<String?>()
        return agents.compactMap { agent in
            let id = agent.displayAccountID
            guard seen.insert(id).inserted else { return nil }
            let title = id.flatMap { id in
                accounts.first { $0.account.id == id }?.displayName
                    ?? billingAccounts.first { $0.id == id }?.displayName
                    ?? fallbackAccounts.first { $0.id == id }?.displayName
            }
            return WindowSection(id: id, title: title, agents: windows[id] ?? [])
        }
    }

    /// Existing rows still offer a display switch before their account or balance reading is available.
    /// Each identity appears once, and identities already represented by a summary do not need a fallback.
    public var unobservedAccounts: [DisplayAccount] {
        var represented = Set(accounts.map(\.account.id) + billingAccounts.map(\.id))
        return agents.compactMap { agent in
            guard let id = agent.displayAccountID, represented.insert(id).inserted else { return nil }
            let name = agent.isAPIBilled ? agent.vendorName + " · API"
                : L10n.text("账户 ", "Account ") + String(id.split(separator: ":").last?.prefix(6) ?? "")
            return DisplayAccount(id: id, displayName: name, detail: agent.billingPool?.label)
        }
    }

    public func displayedCount(settings: Settings) -> Int {
        agents.filter { $0.enabled && settings.accountVisible($0.displayAccountID) }.count
    }
    public var hasLiveStatus: Bool { SessionSource.agentVendors.contains(id) }

    /// One group per account provider, including sources not detected on this Mac, plus present rows and
    /// reported services. Undetected sources follow other groups, preserving order within both sections. A source alone
    /// creates no windows or accounts; existing windows keep their manual order.
    public static func make(sources: [SourceStatus], agents: [AgentDescriptor], report: UsageReport? = nil) -> [Self] {
        let agents = agents.filter { ReportView.isPresent($0, in: report) }
        let existing = agents.agentGroups
        var ids = existing.map(\.id)
        for id in sources.map(\.provider) + agents.map(\.vendor) + (report?.services ?? []).map(\.client)
            where !ids.contains(id) { ids.append(id) }
        let groups = ids.map { id in
            let family = sources.filter { $0.provider == id }
            let source = family.first { $0.state != .notDetected } ?? family.first
            let clients = family.filter { $0.name != id }
            let windows = existing.first { $0.id == id }?.agents ?? []
            let services = (report?.services ?? []).filter { $0.client == id }
            // Older restart copies include former accounts; only current identities have settings and quota rows.
            let accountIDs = Set((report?.accounts?[id] ?? []).filter(\.isCurrent).map(\.account.id))
            let accounts = accountIDs.compactMap { report?.observation(accountID: $0) }
                .sorted { ($0.isCurrent ? 1 : 0, $0.observedAt) > ($1.isCurrent ? 1 : 0, $1.observedAt) }
            var plans = accounts.isEmpty ? source?.planLabel.map { [$0] } ?? [] : []
            for service in services where service.product == .plan {
                guard !accounts.contains(where: { $0.account.id == service.accountID }) else { continue }
                guard let plan = report?.subscriptions[service.accountID ?? service.provider], !plan.isEmpty else { continue }
                plans.append(service.provider == id ? plan.capitalized : service.provider + " · " + plan.capitalized)
            }
            for window in windows {
                guard let pool = window.billingPool, pool.product == .plan,
                      !accounts.contains(where: { $0.account.id == pool.id }),
                      let plan = report?.subscriptions[pool.id], !plan.isEmpty else { continue }
                plans.append(plan.capitalized)
            }
            var api = services.filter { $0.product == .api }.map(\.provider)
            api += agents.filter { $0.vendor == id && $0.billingPool?.product == .api }.compactMap { $0.billingPool?.provider }
            api += windows.compactMap { $0.billingPool?.product == .api ? $0.billingPool?.provider : nil }
            api += (report?.billing ?? []).filter {
                ($0.billingPool?.provider ?? $0.vendor) == id && (!$0.balances.isEmpty || !$0.costs.isEmpty)
            }.map { $0.billingPool?.provider ?? $0.vendor }
            return Self(id: id, source: source, clients: clients, agents: windows, plans: Array(Set(plans)).sorted(),
                        apiProviders: Array(Set(api)).sorted(), accounts: accounts,
                        billingAccounts: (report?.billing ?? []).filter { ($0.billingPool?.provider ?? $0.vendor) == id })
        }
        return groups.filter { $0.source?.state != .notDetected } + groups.filter { $0.source?.state == .notDetected }
    }

}
