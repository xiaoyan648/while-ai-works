import Foundation
import Observation

/// Persists `Settings`, the ordered agent list and onboarding state in UserDefaults as JSON.
@MainActor
@Observable
public final class SettingsStore {
    public private(set) var settings: Settings
    public private(set) var agents: [AgentDescriptor]
    public private(set) var hasCompletedOnboarding: Bool

    public enum Change { case settings, agents, discovery }
    /// Invoked after preferences are persisted and local state is updated. A running `UsageStore` sets it, to wake
    /// collection when a change needs a read; a host follows settings through Observation instead.
    @ObservationIgnored public var onChange: ((Change) -> Void)?

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public enum Keys {
        public static let settings = "settings.v1"
        public static let agents = "agents.v5"
        public static let onboarding = "onboarding.completed.v1"
    }

    /// Rows come from providers; `defaultAgents` seeds a store for the demo and tests.
    public init(defaults: UserDefaults = .standard, defaultAgents: [AgentDescriptor] = []) {
        self.defaults = defaults
        let decoder = JSONDecoder()
        if let data = defaults.data(forKey: Keys.settings), let stored = try? decoder.decode(Settings.self, from: data) {
            settings = stored
        } else {
            settings = Settings()
        }
        if let data = defaults.data(forKey: Keys.agents), let stored = try? decoder.decode([AgentDescriptor].self, from: data), !stored.isEmpty {
            // Only seeded placeholders are unconnected: a provider reports the rows it reads, connected.
            agents = stored.filter(\.connected).groupedAgentOrder
        } else {
            agents = defaultAgents.groupedAgentOrder
        }
        hasCompletedOnboarding = defaults.bool(forKey: Keys.onboarding)
        let normalized = applyingAccountVisibility(to: agents)
        if normalized != agents {
            agents = normalized
            persist(normalized, key: Keys.agents)
        }
    }

    public var enabledAgents: [AgentDescriptor] { agents.filter(\.enabled) }

    public func update(_ change: (inout Settings) -> Void) {
        let next = settings.with(change)
        guard next != settings else { return }
        // Views can render as soon as settings change; translations must already match.
        if next.language != settings.language {
            L10n.setLanguage(next.language)
        }
        settings = next
        persist(next, key: Keys.settings)
        onChange?(.settings)
    }

    public func updateAgents(_ transform: ([AgentDescriptor]) -> [AgentDescriptor]) {
        saveAgents(transform(agents), change: .agents)
    }

    private func saveAgents(_ list: [AgentDescriptor], change: Change) {
        let next = list.groupedAgentOrder
        guard next != agents else { return }
        agents = next
        persist(next, key: Keys.agents)
        onChange?(change)
    }

    public func setAgent(id: String, enabled: Bool) {
        updateAgents { list in list.map { $0.id == id ? $0.with(enabled: enabled) : $0 } }
    }

    /// Sets every window of the account to the same display switch, preserving other accounts and window order.
    /// Both persisted values are current before observers hear about this one preference change.
    public func setAccount(id: String, visible: Bool) {
        let next = settings.with { $0.setAccountVisibility(id: id, visible: visible) }
        let windows = agents.map { $0.displayAccountID == id ? $0.with(enabled: visible) : $0 }
        guard next != settings || windows != agents else { return }
        if next != settings {
            settings = next
            persist(next, key: Keys.settings)
        }
        if windows != agents {
            agents = windows
            persist(windows, key: Keys.agents)
        }
        onChange?(.settings)
    }

    public func moveAgent(id: String, to index: Int) {
        updateAgents { $0.moving(id: id, to: index) }
    }

    public func moveAccountWindow(id: String, to targetID: String) {
        updateAgents { $0.movingAccountWindow(id: id, to: targetID) }
    }

    public func moveAgentGroup(id: String, to targetID: String) {
        updateAgents { $0.movingGroup(id: id, to: targetID) }
    }

    /// Adds rows a provider discovered (in the order given) and refreshes the names and flags of known rows.
    /// New rows for a vendor go right after that vendor's last existing row; vendors new to the list go to the top in
    /// the order the providers gave them, switched off when the vendor catalog starts them hidden. The user's manual
    /// order is preserved.
    /// Account rows: the first identified account takes over an unscoped row's position and switch, a further account's
    /// window inherits the switch of the same window on another account, and rows that are no longer present, as
    /// `ReportView.isPresent(_:in:)` decides without the sighting times, are removed.
    /// Windows belonging to a hidden account stay switched off, including newly discovered and identified windows.
    /// With `replaceQuotaWindows`, the caller explicitly declares the discovered windows to be complete for each current
    /// account whose own reading is sound. Otherwise account observations must explicitly list their quota window ids;
    /// incremental discovery keeps existing preferences.
    public func mergeDiscovered(_ discovered: [AgentDescriptor], activeQuotaPoolIDs: [String: Set<String>]? = nil,
                                accounts: [String: [AccountObservation]]? = nil, replaceQuotaWindows: Bool = false) {
        let inventoryReport = UsageReport(generatedAt: Date(), snapshots: [], sessions: [], accounts: accounts)
        let inventories = replaceQuotaWindows ? (accounts ?? [:]).values.flatMap { $0 }.reduce(into: [String: Set<String>]()) { inventories, account in
            guard account.isCurrent && account.ownStatus.isNormal else { return }
            inventories[account.account.id] = Set(discovered.filter { $0.displayAccountID == account.account.id }.map(\.id))
        } : inventoryReport.completeQuotaWindowInventories
        merge(discovered, activeQuotaPoolIDs: activeQuotaPoolIDs, accounts: accounts, windowInventories: inventories)
    }

    /// Merges the rows of a report the app displays, as `mergeDiscovered(_:activeQuotaPoolIDs:accounts:replaceQuotaWindows:)`
    /// does with every explicitly complete inventory applied. Only a current account's sound complete inventory retires
    /// omitted windows, the same rule the report kept across passes follows.
    public func mergeDiscovered(from report: UsageReport) {
        merge(report.discoveredAgents, activeQuotaPoolIDs: report.activeQuotaPoolIDs, accounts: report.accounts,
              windowInventories: report.completeQuotaWindowInventories, rowSeenAt: report.rowSeenAt)
    }

    /// - windowInventories: explicit complete window ids for accounts whose current reading can replace older windows.
    private func merge(_ discovered: [AgentDescriptor], activeQuotaPoolIDs: [String: Set<String>]?,
                       accounts: [String: [AccountObservation]]?, windowInventories: [String: Set<String>], rowSeenAt: [String: Date]? = nil) {
        guard !discovered.isEmpty || activeQuotaPoolIDs != nil || accounts != nil else { return }
        let resolved = (accounts ?? [:]).values.flatMap { $0 }.filter {
            $0.aliases?.contains(where: settings.hiddenAccountIDs.contains) == true
        }
        if !resolved.isEmpty {
            update { preferences in
                for observation in resolved {
                    for alias in observation.aliases ?? [] { preferences.setAccountVisibility(id: alias, visible: true) }
                    preferences.setAccountVisibility(id: observation.account.id, visible: false)
                }
            }
        }
        func isPresent(_ agent: AgentDescriptor) -> Bool {
            ReportView.isPresent(agent, seenAt: nil, accounts: accounts, activePools: activeQuotaPoolIDs)
        }
        func isUnscoped(_ agent: AgentDescriptor) -> Bool { agent.account == nil && agent.billingPool == nil }
        let merged: [AgentDescriptor] = {
            var list = agents.filter { agent in
                // A complete account inventory keeps only the windows it explicitly lists.
                if let accountID = agent.displayAccountID, let inventory = windowInventories[accountID] {
                    return inventory.contains(agent.id)
                }
                // A row without an account waits for an identified account to take it over.
                return isUnscoped(agent) || isPresent(agent)
            }
            let knownSummaryRows = (list + discovered).filter {
                ReportView.isPresent($0, seenAt: rowSeenAt, accounts: accounts, activePools: activeQuotaPoolIDs)
            }
            let superseded = AntigravityClient.supersededLegacyWindowIDs(in: list + discovered, by: knownSummaryRows)
            list.removeAll { superseded.contains($0.id) }
            let discovered = discovered.filter { !superseded.contains($0.id) }
            for found in discovered where found.account != nil && found.billingPool == nil && !list.contains(where: { $0.id == found.id }) {
                if let index = list.firstIndex(where: { $0.account == nil && $0.billingPool == nil && $0.vendor == found.vendor && $0.id == found.windowKey }) {
                    let unscoped = list.remove(at: index)
                    list.insert(found.with(enabled: unscoped.enabled), at: index)
                } else if let sibling = list.last(where: { $0.vendor == found.vendor && $0.account != nil && $0.windowKey == found.windowKey }) {
                    let anchor = list.lastIndex { $0.vendor == found.vendor }
                    list.insert(found.with(enabled: sibling.enabled), at: anchor.map { $0 + 1 } ?? 0)
                }
            }
            if discovered.contains(where: { $0.vendor == "DeepSeek" && $0.id.hasPrefix("deepseek-model:") }),
               let index = list.firstIndex(where: { $0.id == "deepseek" }) {
                let placeholder = list.remove(at: index)
                let replacements = discovered.filter { found in found.vendor == "DeepSeek" && !list.contains(where: { $0.id == found.id }) }
                    .map { $0.with(enabled: placeholder.enabled) }
                list.insert(contentsOf: replacements, at: index)
            }
            // Unscoped rows of a provider that now identifies accounts have been taken over or no longer exist.
            list.removeAll { agent in isUnscoped(agent) && !isPresent(agent) && !discovered.contains { $0.id == agent.id } }
            let listed = Set(list.map(\.vendor))
            var arriving: [AgentDescriptor] = []
            for found in discovered {
                if let index = list.firstIndex(where: { $0.id == found.id }) {
                    let existing = list[index]
                    if existing.model != found.model || existing.shortModel != found.shortModel || existing.source != found.source
                        || existing.connected != found.connected || existing.billingPool != found.billingPool
                        || existing.account != found.account || existing.allModels != found.allModels {
                        list[index] = AgentDescriptor(
                            id: existing.id, vendor: existing.vendor, model: found.model, shortModel: found.shortModel, source: found.source,
                            enabled: existing.enabled, connected: found.connected, billingPool: found.billingPool, account: found.account,
                            allModels: found.allModels
                        )
                    }
                    continue
                }
                guard listed.contains(found.vendor) else {
                    arriving.append(VendorCatalog.startsHidden(found.vendor) ? found.with(enabled: false) : found)
                    continue
                }
                let anchor = list.lastIndex { $0.vendor == found.vendor }
                list.insert(found, at: anchor.map { $0 + 1 } ?? 0)
            }
            list.insert(contentsOf: arriving, at: 0)
            return list
        }()
        saveAgents(applyingAccountVisibility(to: merged), change: .discovery)
    }

    /// Hidden accounts keep every window off; visible accounts retain their individual display switches.
    private func applyingAccountVisibility(to windows: [AgentDescriptor]) -> [AgentDescriptor] {
        windows.map { settings.accountVisible($0.displayAccountID) ? $0 : $0.with(enabled: false) }
    }

    public func markOnboardingComplete() {
        hasCompletedOnboarding = true
        defaults.set(true, forKey: Keys.onboarding)
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
