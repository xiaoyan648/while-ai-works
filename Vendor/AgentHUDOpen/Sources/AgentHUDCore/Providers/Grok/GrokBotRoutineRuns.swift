import Foundation

/// Which bot each routine run belongs to. A run is billed as a `sand-subagent-<run id>` conversation of its own, and
/// billing names no parent: only the Bot service's record of the routine lists its runs under the bot that owns it.
/// A run stays known after its routine is deleted, for as long as the ledger keeps its usage.
actor GrokBotRoutineRuns {
    struct Run: Codable, Equatable, Sendable {
        /// The bot that owns the routine, by its native id.
        let agent: String
        /// The routine's name as its record keeps it.
        let name: String
        let startedAt: Date
    }

    /// How often the service is asked about one run it does not list, and how long it waits in between.
    static let attempts = 2
    static let retryAfter: TimeInterval = 600

    private let directory: URL
    private let fileURL: URL?
    private let clock: @Sendable () -> Date
    private var runs: [String: Run] = [:]
    private var asked: [String: (count: Int, at: Date)] = [:]

    /// - directory: Grok Bot's persistence folder, whose roster lists the bots to ask about.
    /// - fileURL: where the runs are kept across launches; nil keeps them in memory.
    init(directory: URL = GrokBotSessions.roots(home: FileManager.default.homeDirectoryForCurrentUser, environment: [:])[0],
         fileURL: URL? = nil, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory; self.fileURL = fileURL; self.clock = clock
        if let data = fileURL.flatMap({ try? Data(contentsOf: $0) }),
           let saved = try? JSONDecoder().decode([String: Run].self, from: data) { runs = saved }
    }

    var links: [String: Run] { runs }

    /// Asks the service for the bots' routines when `billed`, the ids of the billed conversations, holds a sub-agent
    /// conversation no known run explains. Each such conversation is asked about `attempts` times at most, so one that
    /// is no routine's run costs no further request.
    func refresh(billed: [String], read: @Sendable ([String]) async throws -> ProviderJSON) async {
        let now = clock()
        let unknown = Set(billed.compactMap(GrokBotUsage.billedSubagentID)).subtracting(runs.keys)
        let due = unknown.filter { id in
            guard let last = asked[id] else { return true }
            return last.count < Self.attempts && now.timeIntervalSince(last.at) >= Self.retryAfter
        }
        asked = asked.filter { unknown.contains($0.key) }
        guard !due.isEmpty else { return }
        let agents = GrokBotSessions.agentIDs(in: directory)
        guard !agents.isEmpty, let reply = try? await read(agents) else { return }
        for id in due { asked[id] = ((asked[id]?.count ?? 0) + 1, now) }
        let cutoff = now.addingTimeInterval(-UsageLedger.retention)
        let merged = runs.merging(Self.parse(reply, now: now)) { _, new in new }.filter { $0.value.startedAt >= cutoff }
        guard merged != runs else { return }
        runs = merged
        save()
    }

    /// The runs a `ListGrokBotAccountAutomations` reply lists, by run id. A run listed under two bots names neither.
    static func parse(_ reply: ProviderJSON, now: Date) -> [String: Run] {
        var result: [String: Run] = [:], ambiguous = Set<String>()
        for agent in reply["agents"].arrayValue ?? [] {
            guard let owner = agent["agentId"].stringValue, GrokBotCache.isAgentID(owner) else { continue }
            for automation in agent["automations"].arrayValue ?? [] {
                guard let text = automation["recordJson"].stringValue,
                      let record = try? ProviderJSON.read(Data(text.utf8)) else { continue }
                let name = SessionTitle.named(record["name"].stringValue) ?? SessionTitle.named(record["id"].stringValue) ?? ""
                for run in record["runs"].arrayValue ?? [] {
                    guard let id = run["id"].stringValue, GrokBotCache.isAgentID(id) else { continue }
                    if let known = result[id], known.agent != owner { ambiguous.insert(id) }
                    result[id] = Run(agent: owner, name: name, startedAt: ProviderDate.milliseconds(run["startedAt"]) ?? now)
                }
            }
        }
        return result.filter { !ambiguous.contains($0.key) }
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(runs).write(to: fileURL, options: .atomic)
        } catch { NSLog("[AgentHUD] Grok Bot routine runs write failed: %@", error.localizedDescription) }
    }
}
