import Foundation

/// One monitored agent/model row, e.g. "Claude · Opus 4.5". Order in the stored array is the glow order (left → right).
public struct AgentDescriptor: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let vendor: String
    /// A model's name, or a quota window's full name in its vendor's words: Claude's windows as persisted keys that
    /// `L10n.modelLabel(_:)` words in the current language, every other window as its provider wrote it.
    public let model: String
    /// A quota window's short name as its provider wrote it (`WindowNames`), its full name where it has none; nil for
    /// Claude's windows and models, whose short names `L10n.shortModelLabel(_:)` derives from `model`.
    public let shortModel: String?
    /// Human-readable data-source label shown in settings ("Claude Code 会话", "codex app-server", "未连接").
    public let source: String
    public let enabled: Bool
    /// Whether a local data source was detected for this agent.
    public let connected: Bool
    public let billingPool: BillingPool?
    /// The account whose quota this row shows. Nil for token consumers, API rows and placeholders.
    public let account: ProviderAccount?
    /// Whether a quota window is its provider's plan-wide quota. False for a window that limits a subset of the plan's
    /// models or features: Claude's weekly window of one family, a Codex bucket other than `codex`, Cursor's Cursor Models
    /// and Other Models pools, an Antigravity group's window where the account has several groups, GitHub Copilot's chat
    /// and code completions, and GLM's MCP window. True for every other row, and for rows saved before the flag existed.
    public let allModels: Bool

    public init(
        id: String,
        vendor: String,
        model: String,
        shortModel: String? = nil,
        source: String,
        enabled: Bool,
        connected: Bool = true,
        billingPool: BillingPool? = nil,
        account: ProviderAccount? = nil,
        allModels: Bool = true
    ) {
        self.id = id
        self.vendor = vendor
        self.model = model
        self.shortModel = shortModel
        self.source = source
        self.enabled = enabled
        self.connected = connected
        self.billingPool = billingPool
        self.account = account
        self.allModels = allModels
    }

    private enum CodingKeys: String, CodingKey {
        case id, vendor, model, shortModel, source, enabled, connected, billingPool, account, allModels
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), vendor: try c.decode(String.self, forKey: .vendor),
                  model: try c.decode(String.self, forKey: .model), shortModel: try c.decodeIfPresent(String.self, forKey: .shortModel),
                  source: try c.decode(String.self, forKey: .source),
                  enabled: try c.decode(Bool.self, forKey: .enabled), connected: try c.decode(Bool.self, forKey: .connected),
                  billingPool: try c.decodeIfPresent(BillingPool.self, forKey: .billingPool),
                  account: try c.decodeIfPresent(ProviderAccount.self, forKey: .account),
                  allModels: try c.decodeIfPresent(Bool.self, forKey: .allModels) ?? true)
    }

    /// A row over every model, the usual case, is stored without the flag.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(vendor, forKey: .vendor)
        try c.encode(model, forKey: .model)
        try c.encodeIfPresent(shortModel, forKey: .shortModel)
        try c.encode(source, forKey: .source)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(connected, forKey: .connected)
        try c.encodeIfPresent(billingPool, forKey: .billingPool)
        try c.encodeIfPresent(account, forKey: .account)
        if !allModels { try c.encode(false, forKey: .allModels) }
    }

    /// The provider's own window name inside the account-scoped id (`codex`, `claude-session`, `weekly`).
    public var windowKey: String {
        if let account, id.hasPrefix(account.id + "/") { return String(id.dropFirst(account.id.count + 1)) }
        if let billingPool, id.hasPrefix(billingPool.id + ":") { return String(id.dropFirst(billingPool.id.count + 1)) }
        return id
    }

    /// The vendor this row is grouped under: the API provider for API-billed rows. An id, not a name to show.
    public var displayVendor: String { billingPool?.product == .api ? billingPool!.provider : vendor }
    /// The group's name as shown, from the vendor catalog.
    public var vendorName: String { VendorCatalog.name(displayVendor) }
    /// The row's own name, a quota window's full name or a model's, as every surface writes it: a persisted window key in
    /// words (`L10n.modelLabel(_:)`), else the model as written.
    public var name: String { L10n.modelLabel(model) }
    /// The short form of `name` for tight places, such as a panel row whose name column is too narrow for `name`, a menu row
    /// that names its vendor, a Watch row or a small widget: the provider's short name for a window, else
    /// `L10n.shortModelLabel(_:)`. Never cut: a window without a short name gives its full name.
    public var shortName: String { shortModel ?? L10n.shortModelLabel(model) }
    /// The vendor's name and the row's.
    public var displayName: String { "\(vendorName) · \(name)" }
    /// The vendor's name and the row's short name, for a menu row that names its vendor.
    public var compactName: String { "\(vendorName) · \(shortName)" }

    /// DeepSeek exposes API balance and costs instead of subscription quota windows.
    public var isAPIBilled: Bool {
        if let product = billingPool?.product, product != .unknown { return product == .api }
        return vendor == "DeepSeek"
    }

    /// The existing identity shared by this row's quota or API balance. Legacy API balances are keyed by vendor.
    public var displayAccountID: String? {
        account?.id ?? billingPool?.id ?? (isAPIBilled ? vendor : nil)
    }

    /// Returns a copy with the given fields replaced (the core never mutates in place).
    public func with(
        enabled: Bool? = nil,
        connected: Bool? = nil
    ) -> AgentDescriptor {
        AgentDescriptor(
            id: id,
            vendor: vendor,
            model: model,
            shortModel: shortModel,
            source: source,
            enabled: enabled ?? self.enabled,
            connected: connected ?? self.connected,
            billingPool: billingPool,
            account: account,
            allModels: allModels
        )
    }

}

public extension Array where Element == AgentDescriptor {
    /// Moves the agent with `id` to `index`, returning a new array.
    func moving(id: String, to index: Int) -> [AgentDescriptor] {
        guard let from = firstIndex(where: { $0.id == id }), index >= 0, index < count else { return self }
        var copy = self
        let item = copy.remove(at: from)
        copy.insert(item, at: index)
        return copy
    }

    func replacing(_ agent: AgentDescriptor) -> [AgentDescriptor] {
        map { $0.id == agent.id ? agent : $0 }
    }
}
