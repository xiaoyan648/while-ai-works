import AgentHUDSupport
import Foundation

/// The `account/rateLimits/read` fields used by the HUD.
public struct CodexRateLimits: Decodable, Sendable {
    public struct Window: Decodable, Sendable {
        public let usedPercent: Double
        public let windowDurationMins: Int?
        public let resetsAt: TimeInterval?

        public var remainingPct: Double { QuotaMath.remaining(usedPercent: usedPercent) }
        public var resetAt: Date? { resetsAt.map(Date.init(timeIntervalSince1970:)) }
        public var duration: TimeInterval? { windowDurationMins.map { Double($0) * 60 } }
    }

    public struct Bucket: Decodable, Sendable {
        public let limitId: String?
        public let limitName: String?
        public let primary: Window?
        public let secondary: Window?
        public let planType: String?
    }

    public struct Row: Sendable {
        public let id: String
        /// The window's full name in the words of Codex's own client.
        public let label: String
        /// The window's short name (`WindowNames`), its full name where it has none.
        public let shortLabel: String
        public let window: Window
        public let weekly: Window?
        public var account: ProviderAccount? = nil
        /// Only the `codex` bucket limits every model; another bucket limits its own model.
        public var allModels = true

        public var descriptor: AgentDescriptor {
            AgentDescriptor(id: id, vendor: "Codex", model: label, shortModel: shortLabel, source: L10n.sourceCodexAppServer,
                            enabled: true, account: account, allModels: allModels)
        }

        func scoped(to account: ProviderAccount) -> Row {
            Row(id: account.windowID(id), label: label, shortLabel: shortLabel, window: window, weekly: weekly, account: account,
                allModels: allModels)
        }
    }

    /// The `account/read` result from the same engine process.
    public struct SignedInAccount: Decodable, Sendable {
        public let type: String?
        public let email: String?
        public let planType: String?
    }

    public let rateLimits: Bucket?
    public let rateLimitsByLimitId: [String: Bucket]?
    public let rateLimitResetCredits: CodexResetCredits?
    /// The ChatGPT workspace of this snapshot. Members of one workspace share it, so the email separates users.
    public let accountId: String?
    public var account: SignedInAccount?
    /// The hash of the workspace this home's account last came with, standing in for an `accountId` the engine left out.
    public var rememberedWorkspace: String?

    /// A present multi-bucket map is authoritative, including an empty map.
    public var buckets: [(id: String, bucket: Bucket)] {
        if let map = rateLimitsByLimitId {
            return map.keys.sorted { a, b in
                if a == "codex" { return b != "codex" }
                if b == "codex" { return false }
                return a < b
            }.map { ($0, map[$0]!) }
        }
        return rateLimits.map { [($0.limitId ?? "codex", $0)] } ?? []
    }

    public var plan: String? { buckets.compactMap { $0.bucket.planType }.first ?? account?.planType }

    /// Hashes of the signed-in email and of the workspace, as `ProviderAccount.identified` makes them; empty for a missing one.
    private var identity: (user: String, workspace: String) {
        let email = account?.email?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let workspace = accountId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (email.isEmpty ? "" : RecordCoding.hash([email]),
                workspace.isEmpty ? rememberedWorkspace ?? "" : RecordCoding.hash([workspace]))
    }

    public func providerAccount(home: String) -> ProviderAccount {
        let identity = identity
        guard !identity.user.isEmpty || !identity.workspace.isEmpty else { return .unresolved(provider: "Codex", home: home) }
        return ProviderAccount(provider: "Codex", user: identity.user, workspace: identity.workspace, evidence: .account)
    }

    /// The keys the same account got from readings without its email, as when `account/read` answered too late, or
    /// without its workspace, as from an engine that leaves out `accountId`. Empty unless this reading has both.
    public var partialKeys: [String] {
        let identity = identity
        guard !identity.user.isEmpty, !identity.workspace.isEmpty else { return [] }
        return [ProviderAccount(provider: "Codex", user: "", workspace: identity.workspace, evidence: .account).id,
                ProviderAccount(provider: "Codex", user: identity.user, workspace: "", evidence: .account).id]
    }

    /// Window rows keyed by their own window id (`codex`, `codex:<limit>:<slot>`); providers scope them to the account.
    public func rows(home: String) -> [Row] {
        let account = providerAccount(home: home)
        return rows.map { $0.scoped(to: account) }
    }

    /// Every bucket's windows, named as Codex's own client names them: "5h limit", "Weekly limit", a window without a
    /// length "Usage limit" or "Secondary usage limit", and a bucket other than `codex` with its name before them. Short
    /// names give the `codex` bucket's windows their period alone and another bucket's its word, with the period when
    /// the bucket has two windows (Spark 5h, Spark 7d, Reserve).
    public var rows: [Row] {
        let named = buckets.flatMap { id, bucket in
            let weekly = [bucket.primary, bucket.secondary].compactMap { $0 }.first { $0.windowDurationMins == 10080 }
            let windows = [("primary", bucket.primary), ("secondary", bucket.secondary)].compactMap { slot, window in window.map { (slot, $0) } }
            let service = bucket.limitName ?? id
            let name = id == "codex" ? nil : VendorCatalog.window(service, vendor: "Codex")
            let word = id == "codex" ? nil : VendorCatalog.windowWord(service, vendor: "Codex")
            return windows.map { slot, window -> Row in
                let period = WindowNames.Period(seconds: window.duration), secondary = slot == "secondary"
                let limit = Self.limitName(period, secondary: secondary)
                let alone = period?.shortName ?? (secondary ? L10n.text("次要额度", "Secondary") : L10n.text("额度", "Usage"))
                let short = word.map { windows.count > 1 ? "\($0) \(period?.afterWord ?? alone)" : $0 } ?? alone
                // The shared primary window keeps the old placeholder's id as its window key, preserving preferences.
                let rowId = id == "codex" && slot == "primary" ? "codex" : "codex:\(id):\(slot)"
                return Row(id: rowId, label: name.map { "\($0) · \(limit)" } ?? limit, shortLabel: short, window: window, weekly: weekly,
                           allModels: id == "codex")
            }
        }
        // Windows whose short names would read alike keep their full names.
        let shortLabels = WindowNames.distinct(named.map { Optional($0.shortLabel) })
        return zip(named, shortLabels).map { row, short in
            Row(id: row.id, label: row.label, shortLabel: short ?? row.label, window: row.window, weekly: row.weekly, allModels: row.allModels)
        }
    }

    /// A window's name in the words of Codex's own client, which names 5 hours, a day, a week, a month and a year within
    /// 5 %, in Chinese in the Mac's words.
    static func limitName(_ period: WindowNames.Period?, secondary: Bool) -> String {
        switch period {
        case .fiveHours: L10n.text("5 小时额度", "5h limit")
        case .day: L10n.text("每日额度", "Daily limit")
        case .week: L10n.text("每周额度", "Weekly limit")
        case .month: L10n.text("每月额度", "Monthly limit")
        case .year: L10n.text("每年额度", "Annual limit")
        case .days(let count): L10n.text("\(count) 天额度", "\(count)d limit")
        case .hours(let count): L10n.text("\(count) 小时额度", "\(count)h limit")
        case .minutes(let count): L10n.text("\(count) 分钟额度", "\(count)m limit")
        case nil: secondary ? L10n.text("次要用量额度", "Secondary usage limit") : L10n.text("用量额度", "Usage limit")
        }
    }
}

/// Account-wide earned resets. The count is authoritative; credit details can be absent or capped.
public struct CodexResetCredits: Codable, Hashable, Sendable {
    public struct Credit: Codable, Hashable, Sendable, Identifiable {
        public let id: String
        public let expiresAt: TimeInterval?

        public init(id: String, expiresAt: TimeInterval?) {
            self.id = id
            self.expiresAt = expiresAt
        }

        public var expirationDate: Date? { expiresAt.map(Date.init(timeIntervalSince1970:)) }
    }

    public let availableCount: Int
    public let credits: [Credit]?

    public init(availableCount: Int, credits: [Credit]?) {
        self.availableCount = availableCount
        self.credits = credits
    }

    public var creditsByExpiry: [Credit] {
        (credits ?? []).sorted { ($0.expiresAt ?? .infinity) < ($1.expiresAt ?? .infinity) }
    }
}
