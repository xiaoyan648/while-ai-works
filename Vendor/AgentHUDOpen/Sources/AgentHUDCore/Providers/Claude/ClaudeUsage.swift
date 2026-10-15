import Foundation

/// One rate-limit window.
public struct ClaudeUsageWindow: Hashable, Sendable {
    /// 0…100, share of the window already consumed.
    public let utilizationPct: Double
    public let resetsAt: Date?

    public init(utilizationPct: Double, resetsAt: Date?) {
        self.utilizationPct = utilizationPct
        self.resetsAt = resetsAt
    }

    public var remainingPct: Double { QuotaMath.remaining(usedPercent: utilizationPct) }
}

/// One quota window as a row: Current session, Weekly limit · All models, Weekly limit · Fable. Each has its own reset
/// cadence.
public struct ClaudeQuotaWindowRow: Hashable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let window: ClaudeUsageWindow
    public let duration: TimeInterval
    public let account: ProviderAccount?
    /// False for a model family's weekly window; the session and the weekly window cover every model.
    public let allModels: Bool

    public init(id: String, label: String, window: ClaudeUsageWindow, duration: TimeInterval, account: ProviderAccount? = nil,
                allModels: Bool = true) {
        self.id = id
        self.label = label
        self.window = window
        self.duration = duration
        self.account = account
        self.allModels = allModels
    }

    public var descriptor: AgentDescriptor {
        AgentDescriptor(id: id, vendor: "Claude", model: label, source: L10n.sourceClaudeCode, enabled: true, account: account,
                        allModels: allModels)
    }

    func scoped(to account: ProviderAccount) -> ClaudeQuotaWindowRow {
        ClaudeQuotaWindowRow(id: account.windowID(id), label: label, window: window, duration: duration, account: account,
                             allModels: allModels)
    }
}

/// Plan usage windows: the shared 5-hour and 7-day windows plus model-scoped weekly windows
/// (`seven_day_opus`, or `limits[]` entries of kind `weekly_scoped` with a model scope).
public struct ClaudeUsage: Hashable, Sendable {
    public let fiveHour: ClaudeUsageWindow?
    public let sevenDay: ClaudeUsageWindow?
    /// Keyed by lowercased model family ("opus", "sonnet", "fable").
    public let modelWeekly: [String: ClaudeUsageWindow]

    public init(fiveHour: ClaudeUsageWindow?, sevenDay: ClaudeUsageWindow?, modelWeekly: [String: ClaudeUsageWindow] = [:]) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.modelWeekly = modelWeekly
    }

    public static let sessionRowId = "claude-session"
    public static let weeklyRowId = "claude-weekly"

    /// Rows in the order Claude Code's own /usage screen uses: session, weekly all-models, weekly per family.
    /// Labels are persisted keys; `L10n.modelLabel` turns them into text.
    public var rows: [ClaudeQuotaWindowRow] {
        var rows: [ClaudeQuotaWindowRow] = []
        if let fiveHour { rows.append(ClaudeQuotaWindowRow(id: Self.sessionRowId, label: L10n.windowSession, window: fiveHour, duration: 5 * 3600)) }
        if let sevenDay { rows.append(ClaudeQuotaWindowRow(id: Self.weeklyRowId, label: L10n.windowWeekly, window: sevenDay, duration: 7 * 86400)) }
        for family in modelWeekly.keys.sorted() {
            guard let window = modelWeekly[family] else { continue }
            let name = family.prefix(1).uppercased() + family.dropFirst()
            rows.append(ClaudeQuotaWindowRow(id: "claude-weekly-\(family)", label: L10n.windowWeeklyPrefix + name, window: window,
                                             duration: 7 * 86400, allModels: false))
        }
        return rows
    }

    public init(fiveHour: ClaudeUsageWindow?, sevenDay: ClaudeUsageWindow?, sevenDayOpus: ClaudeUsageWindow?, sevenDaySonnet: ClaudeUsageWindow?) {
        var scoped: [String: ClaudeUsageWindow] = [:]
        if let sevenDayOpus { scoped["opus"] = sevenDayOpus }
        if let sevenDaySonnet { scoped["sonnet"] = sevenDaySonnet }
        self.init(fiveHour: fiveHour, sevenDay: sevenDay, modelWeekly: scoped)
    }

    public var sevenDayOpus: ClaudeUsageWindow? { modelWeekly["opus"] }
    public var sevenDaySonnet: ClaudeUsageWindow? { modelWeekly["sonnet"] }

    /// Lenient parse of a `rate_limits` object: known window keys carrying `utilization`, plus `limits[]`.
    public static func parse(_ data: Data) throws -> ClaudeUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeDataError.malformedUsage
        }
        func window(_ object: Any?, valueKey: String) -> ClaudeUsageWindow? {
            guard let object = object as? [String: Any], let value = number(object[valueKey]) else { return nil }
            return ClaudeUsageWindow(utilizationPct: value, resetsAt: (object["resets_at"] as? String).flatMap(DateParsing.iso8601))
        }
        var scoped: [String: ClaudeUsageWindow] = [:]
        if let opus = window(root["seven_day_opus"], valueKey: "utilization") { scoped["opus"] = opus }
        if let sonnet = window(root["seven_day_sonnet"], valueKey: "utilization") { scoped["sonnet"] = sonnet }
        if let limits = root["limits"] as? [[String: Any]] {
            for entry in limits where (entry["kind"] as? String) == "weekly_scoped" {
                guard let scope = entry["scope"] as? [String: Any],
                      let model = scope["model"] as? [String: Any],
                      let family = ((model["display_name"] as? String) ?? (model["id"] as? String)).flatMap(ClaudeModelInfo.parse)?.family.lowercased()
                        ?? (model["display_name"] as? String)?.lowercased(),
                      let value = window(entry, valueKey: "percent")
                else { continue }
                scoped[family] = value
            }
        }
        let usage = ClaudeUsage(
            fiveHour: window(root["five_hour"], valueKey: "utilization"),
            sevenDay: window(root["seven_day"], valueKey: "utilization"),
            modelWeekly: scoped
        )
        guard usage.fiveHour != nil || usage.sevenDay != nil else { throw ClaudeDataError.malformedUsage }
        return usage
    }

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        return nil
    }

    /// Weekly window for a family row ("claude-fable" → the Fable-scoped window), else the shared weekly window.
    public func weekly(for agentId: String) -> ClaudeUsageWindow? {
        let family = agentId.hasPrefix("claude-") ? String(agentId.dropFirst("claude-".count)) : agentId
        return modelWeekly[family] ?? sevenDay
    }
}
