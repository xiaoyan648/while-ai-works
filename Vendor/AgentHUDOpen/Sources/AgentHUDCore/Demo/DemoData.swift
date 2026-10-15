import AgentHUDSupport
import Foundation

/// The sample every device's demo shows: one Claude account and one Codex account with their quota windows, a DeepSeek
/// balance, nine sessions and a month of tokens. Rows, readings and sessions are shaped as the providers shape real
/// ones. The iPhone's `DemoFleet` holds the same accounts, sessions and generators: a figure changed here is changed
/// there.
public enum DemoData {
    // MARK: Accounts and quota windows

    public static let claudeAccount = ProviderAccount.identified(provider: "Claude", user: "demo-claude-personal", workspace: nil)!
    public static let codexAccount = ProviderAccount.identified(provider: "Codex", user: "demo-codex-personal", workspace: nil)!

    /// A quota window as last read: the share used, the seconds to its reset, its length, the share it burns an hour
    /// and the week's waits at its cap.
    struct Reading {
        var used: Double
        var resetIn: TimeInterval
        var duration: TimeInterval
        /// nil where the week holds too few readings to tell.
        var burn: Double?
        var caps: (hits: Int, wait: TimeInterval, longest: TimeInterval, daysAgo: Double)?
    }

    /// The windows by their provider's own key (`AgentDescriptor.windowKey`).
    static let readings: [String: Reading] = [
        "claude-session": Reading(used: 12, resetIn: 4320, duration: 5 * 3600, burn: 6.3, caps: (2, 7740, 5400, 2)),
        "claude-weekly": Reading(used: 79, resetIn: 5 * 86400, duration: 7 * 86400, burn: 1.4),
        "claude-weekly-fable": Reading(used: 60, resetIn: 5 * 86400, duration: 7 * 86400, burn: 0.8, caps: (1, 2460, 2460, 3)),
        "codex": Reading(used: 49, resetIn: 6 * 86400, duration: 7 * 86400, burn: 0.6),
        "codex:spark:primary": Reading(used: 18, resetIn: 7200, duration: 5 * 3600, burn: 0),
        "codex:spark:secondary": Reading(used: 24, resetIn: 6 * 86400, duration: 7 * 86400),
    ]

    /// Claude's windows as its provider builds them from a plan's usage: the session, the week, and the week of Fable.
    public static var claudeRows: [AgentDescriptor] {
        func window(_ key: String) -> ClaudeUsageWindow { ClaudeUsageWindow(utilizationPct: readings[key]!.used, resetsAt: nil) }
        return ClaudeUsage(fiveHour: window("claude-session"), sevenDay: window("claude-weekly"),
                           modelWeekly: ["fable": window("claude-weekly-fable")]).rows.map { $0.scoped(to: claudeAccount).descriptor }
    }

    /// Codex's windows as its provider builds them from the engine's rate limits: the plan's week and Spark's two.
    public static var codexRows: [AgentDescriptor] {
        func window(_ key: String) -> String {
            let reading = readings[key]!
            return #"{"usedPercent": \#(reading.used), "windowDurationMins": \#(Int(reading.duration / 60))}"#
        }
        let limits = """
            {"rateLimitsByLimitId": {"codex": {"limitId": "codex", "primary": \(window("codex"))},
             "spark": {"limitId": "spark", "limitName": "GPT-5.3-Codex-Spark", "primary": \(window("codex:spark:primary")),
                       "secondary": \(window("codex:spark:secondary"))}}}
            """
        let read = try? JSONDecoder().decode(CodexRateLimits.self, from: Data(limits.utf8))
        return (read?.rows ?? []).map { $0.scoped(to: codexAccount).descriptor }
    }

    /// The models the sample's sessions and history spend tokens on, by the id their client logs.
    static let models: [(vendor: String, model: String)] = [
        ("Claude", "claude-fable-5-1"), ("Claude", "claude-opus-5-5"), ("Claude", "claude-sonnet-5-5"), ("Claude", "claude-haiku-4-5"),
        ("Codex", "gpt-6-astra"), ("Codex", "gpt-6.1-sol"), ("Codex", "codex-auto-review"),
        ("DeepSeek", "deepseek-v4-pro"), ("DeepSeek", "deepseek-v4-flash"),
    ]

    static func consumerID(_ vendor: String, _ model: String) -> String { "\(vendor.lowercased())-model:\(model)" }

    /// What spends the sample's tokens, as the providers describe the models they find.
    public static var consumers: [AgentDescriptor] {
        models.map { vendor, model in
            let id = consumerID(vendor, model)
            let source = vendor == "Claude" ? L10n.sourceClaudeCode : vendor == "Codex" ? L10n.sourceCodexAppServer : L10n.sourceDeepSeekSessions
            return AgentDescriptor(id: id, vendor: vendor, model: ModelCatalog.consumerName(of: id), source: source, enabled: true)
        }
    }

    /// The rows a demo starts with: both accounts' windows, and DeepSeek's models, which are its rows as an API billed by
    /// use. The tests and snapshots are written against these.
    public static var agents: [AgentDescriptor] { claudeRows + codexRows + consumers.filter { $0.vendor == "DeepSeek" } }

    /// The other vendors the app ships artwork for: a row and a reading each, remaining share and seconds to its reset.
    static let extras: [(id: String, vendor: String, model: String, remaining: Double, resetIn: TimeInterval?)] = [
        ("antigravity", "Antigravity", "Agent", 91, 6 * 3600 + 40 * 60), ("cursor", "Cursor", "Agent", 83, 3 * 3600 + 12 * 60),
        ("copilot", "GitHub Copilot", "Agent", 12, 5 * 3600), ("grok", "Grok", "Code", 66, 90 * 60), ("kimi", "Kimi", "K3", 38, 2 * 3600),
        ("glm", "GLM", "Coding", 95, 8 * 3600), ("opencode", "OpenCode", "CLI", 51, nil), ("openclaw", "OpenClaw", "Agent", 4, 33 * 60),
        ("hermes", "Hermes", "Agent", 77, 4 * 3600 + 25 * 60), ("zcode", "ZCode", "CLI", 29, 70 * 60),
        ("codebuddy", "CodeBuddy", "Agent", 88, 6 * 3600), ("workbuddy", "WorkBuddy", "Agent", 19, 45 * 60),
        ("qwen", "Qwen", "Code", 47, 2 * 3600 + 30 * 60), ("pi", "Pi", "Agent", 60, 3 * 3600),
    ]

    /// Every vendor the app ships artwork for, all switched on. This is what the running demo uses, so the HUD is shown
    /// carrying a full queue rather than the marks of the sample's three vendors.
    public static var everyAgent: [AgentDescriptor] {
        agents + extras.map { AgentDescriptor(id: $0.id, vendor: $0.vendor, model: $0.model, source: L10n.sourceNotConnected, enabled: true) }
    }

    /// A window's reading, with a playing script's share used in place of the sample's where it has set one.
    static func reading(_ key: String, stage: DemoStage?) -> Reading? {
        guard var reading = readings[key] else { return nil }
        if let used = stage?.used[key] { reading.used = used }
        return reading
    }

    /// The readings of the sample's windows among `rows`, and of the other vendors' rows among them.
    /// - stage: a playing script's readings, which take the place of the sample's where it has set any.
    public static func snapshots(for rows: [AgentDescriptor]? = nil, now: Date, stage: DemoStage? = nil) -> [UsageSnapshot] {
        let rows = rows ?? agents
        // A provider reports its account's week beside each window: Claude's weekly window, a Codex bucket's own.
        func week(of row: AgentDescriptor) -> Reading? {
            switch row.windowKey {
            case let key where key.hasPrefix("claude-"): reading("claude-weekly", stage: stage)
            case "codex": reading("codex", stage: stage)
            case let key where key.hasPrefix("codex:spark:"): reading("codex:spark:secondary", stage: stage)
            default: nil
            }
        }
        return rows.compactMap { row in
            if row.account != nil, let reading = reading(row.windowKey, stage: stage) {
                let week = week(of: row)
                return UsageSnapshot(agentId: row.id, remainingPct: QuotaMath.remaining(usedPercent: reading.used),
                                     weeklyRemainingPct: week.map { QuotaMath.remaining(usedPercent: $0.used) },
                                     resetAt: now.addingTimeInterval(reading.resetIn), windowDuration: reading.duration,
                                     weeklyResetAt: week.map { now.addingTimeInterval($0.resetIn) }, updatedAt: now)
            }
            guard let extra = extras.first(where: { $0.id == row.id }) else { return nil }
            return UsageSnapshot(agentId: row.id, remainingPct: stage?.used[row.id].map { 100 - $0 } ?? extra.remaining,
                                 resetAt: extra.resetIn.map { now.addingTimeInterval($0) },
                                 windowDuration: extra.resetIn == nil ? nil : (row.id == "antigravity" ? 24 : 5) * 3600, updatedAt: now)
        }
    }

    /// What the last week says of a window: how fast it burns, when it would run out at that rate, and the waits at its
    /// cap. nil for a row that is no window of the sample.
    public static func insights(for row: AgentDescriptor, now: Date, stage: DemoStage? = nil) -> UsageInsights? {
        guard row.account != nil, let reading = reading(row.windowKey, stage: stage) else { return nil }
        return UsageInsights(burnRatePctPerHour: reading.burn,
                             timeToExhaust: reading.burn.flatMap { $0 > 0 ? (100 - reading.used) / $0 * 3600 : nil },
                             weeklyCapHits: reading.caps?.hits ?? 0, weeklyWaitTotal: reading.caps?.wait ?? 0,
                             weeklyWaitLongest: reading.caps?.longest ?? 0,
                             weeklyWaitLongestAt: reading.caps.map { now.addingTimeInterval(-$0.daysAgo * 86400) })
    }

    /// Both accounts as their providers observed them, Codex's with its earned resets.
    public static func accounts(now: Date) -> [String: [AccountObservation]] {
        ["Claude": [AccountObservation(account: claudeAccount, label: "Personal", plan: "max_20x", observedAt: now)],
         "Codex": [AccountObservation(account: codexAccount, label: "Personal", plan: "pro", observedAt: now,
                                      resetCredits: codexResetCredits(now: now))]]
    }

    public static func codexResetCredits(now: Date) -> CodexResetCredits {
        CodexResetCredits(availableCount: 2, credits: [26, 40].map { days in
            .init(id: "demo-reset-\(days)", expiresAt: now.addingTimeInterval(Double(days) * 86400).timeIntervalSince1970)
        })
    }

    /// DeepSeek's balance, what the last day and the days before it cost, and what its session cost.
    public static func deepSeekBilling(now: Date) -> APIBilling {
        let balance = Decimal(string: "8.85")!
        let bucket = (now.timeIntervalSince1970 / UsageBucket.duration).rounded(.down) * UsageBucket.duration
        return APIBilling(
            vendor: "DeepSeek",
            balances: [AccountBalance(currency: "CNY", total: balance, granted: 0, toppedUp: balance,
                                      runsOutAt: now.addingTimeInterval(23.4 * 86400))],
            isAvailable: true, updatedAt: now,
            costs: [(1800.0, "0.01239"), (3 * 86400.0, "0.04512")].map { age, amount in
                CostBucket(start: Date(timeIntervalSince1970: bucket - age), amounts: ["CNY": Decimal(string: amount)!])
            },
            sessionCosts: ["s8": deepSeekSessionCost],
            notice: nil
        )
    }

    private static let deepSeekSessionCost: [String: Decimal] = ["CNY": Decimal(string: "0.01239")!, "USD": Decimal(string: "0.0017")!]

    // MARK: Sessions

    /// A session of the sample: its model, what it works on and where, its turns and the seed they are drawn from, the
    /// minutes since it last did anything, and the client it runs in.
    struct Plan {
        let id: String
        let vendor: String
        let model: String
        let title: String
        let project: String
        let turns: Int
        let seed: Int
        let idle: Double
        let client: String
        /// In a turn now, where no script says which sessions run.
        var running = false
        /// The turn that came back after its cache had lapsed.
        var lapse: Int?
        /// The days the session began before its turns.
        var days: Double = 0

        var agentId: String { DemoData.consumerID(vendor, model) }
        func lastActivity(_ now: Date) -> Date { now.addingTimeInterval(-idle * 60) }
        func start(_ now: Date) -> Date { lastActivity(now).addingTimeInterval(-Double(turns) * 150 - days * 86400) }
    }

    static let plans: [Plan] = [
        Plan(id: "s1", vendor: "Claude", model: "claude-fable-5-1", title: "Build the iOS dashboard", project: "~/work/hud-ios",
             turns: 26, seed: 7, idle: 1, client: "Claude Code", running: true),
        Plan(id: "s2", vendor: "Codex", model: "gpt-6-astra", title: "Review App Store sandbox support", project: "~/work/agent-hud",
             turns: 30, seed: 51, idle: 2, client: "Codex Desktop", running: true),
        Plan(id: "s3", vendor: "Claude", model: "claude-opus-5-5", title: "Refine settings and colors", project: "~/work/agent-hud",
             turns: 12, seed: 33, idle: 38, client: "Claude Code CLI"),
        Plan(id: "s4", vendor: "Codex", model: "gpt-6.1-sol", title: "Run the regression suite", project: "~/work/agent-hud-open",
             turns: 9, seed: 12, idle: 3, client: "Codex CLI"),
        // Started before the week and picked up again today.
        Plan(id: "s5", vendor: "Claude", model: "claude-sonnet-5-5", title: "Update the documentation", project: "~/work/agent-hud-all",
             turns: 17, seed: 19, idle: 62, client: "Claude Code IDE extension", lapse: 11, days: 9),
        Plan(id: "s6", vendor: "Claude", model: "claude-opus-5-5", title: "Package the Mac release", project: "~/work/agent-hud",
             turns: 14, seed: 61, idle: 125, client: "Claude Code"),
        Plan(id: "s7", vendor: "Codex", model: "gpt-6.1-sol", title: "Check the release scripts", project: "~/work/agent-hud",
             turns: 5, seed: 23, idle: 4, client: "Codex CLI"),
        Plan(id: "s8", vendor: "DeepSeek", model: "deepseek-v4-pro", title: "Review the API integration", project: "~/work/agenthud-web",
             turns: 6, seed: 41, idle: 5, client: "DeepSeek Harness"),
        // Last active on an earlier day.
        Plan(id: "s9", vendor: "Codex", model: "gpt-6.1-sol", title: "Draft the release notes", project: "~/work/agent-hud",
             turns: 8, seed: 71, idle: 26 * 60, client: "Codex CLI"),
    ]

    /// The model a Claude session hands part of every fourth turn to.
    private static let helper = consumerID("Claude", "claude-haiku-4-5")

    /// - stage: a playing script decides which sessions run and when the others ended; without one the first two run.
    public static func sessions(now: Date, stage: DemoStage? = nil) -> [LiveSession] {
        let usage = sessionUsage(now: now), home = FileManager.default.homeDirectoryForCurrentUser.path
        return plans.map { plan in
            let last = plan.lastActivity(now)
            var start = plan.start(now), end: Date? = plan.running ? nil : last
            if let stage {
                if let since = stage.running[plan.id] { (start, end) = (since, nil) } else { end = stage.ended[plan.id] ?? last }
            }
            // The session's own counts: what its own model spent, without the sub-agent's.
            let own = usage[plan.id]?.models.first { $0.agentId == plan.agentId }?.tokens ?? .init()
            let directory = home + plan.project.dropFirst()
            return LiveSession(id: plan.id, agentId: plan.agentId, task: plan.title,
                               terminal: URL(fileURLWithPath: directory).lastPathComponent, startedAt: start, endedAt: end,
                               pctOfWindow: plan.vendor == "Claude" ? Double(plan.turns) / 4 : nil,
                               tokensIn: own.tokensIn, tokensOut: own.tokensOut, client: plan.client,
                               cacheReadTokens: own.cacheReadTokens, observedAt: now, workingDirectory: directory,
                               lastActivityAt: end == nil ? now : last)
        }
    }

    /// The sessions' turns: a context that grows by what each turn writes to the cache, reasoning on about half of them,
    /// now and then a large paste, and a compaction as the context nears its window. A Claude session hands part of
    /// every fourth turn to a sub-agent on Haiku, and at `lapse` its turn comes back after the cache lapsed and writes
    /// the whole context again. DeepSeek's session is billed, so it carries what it cost and no list price.
    public static func sessionUsage(now: Date) -> [String: SessionUsage] {
        Dictionary(uniqueKeysWithValues: plans.map { ($0.id, usage(of: $0, now: now)) })
    }

    private static func tokens(_ kinds: TokenKinds) -> SessionUsage.Tokens {
        SessionUsage.Tokens(tokensIn: kinds.input + kinds.cacheWrite, tokensOut: kinds.output + kinds.reasoning,
                            cacheReadTokens: kinds.cacheRead, cacheWriteTokens: kinds.cacheWrite, reasoningTokens: kinds.reasoning)
    }

    private static func usage(of plan: Plan, now: Date) -> SessionUsage {
        var state = UInt64(plan.seed * 9973 + 1)
        func random() -> Double {
            state = state * 16807 % 2_147_483_647
            return Double(state) / 2_147_483_647
        }
        let claude = plan.vendor == "Claude", billed = plan.vendor == "DeepSeek"
        func cost(_ kinds: TokenKinds, _ agentId: String) -> Decimal? {
            billed ? nil : ModelCatalog.cost(agentId: agentId, summed: kinds)?.amount
        }
        let window: Int? = claude ? 1_000_000 : plan.vendor == "Codex" ? 258_400 : nil
        let end = plan.lastActivity(now), start = plan.start(now), span = end.timeIntervalSince(start)
        var context = claude ? 140_000 : 24_000
        var turns: [SessionUsage.Turn] = [], byModel: [String: TokenKinds] = [:], periods: [Date: [String: TokenKinds]] = [:]
        var helped: TokenKinds?
        for index in 0..<plan.turns {
            let calls = 3 + Int(random() * 12)
            let input = Int(random() < 0.18 ? 7_000 + random() * 16_000 : 150 + random() * 1_800)
            let output = Int(250 + random() * random() * 4_200)
            let reasoning = random() < 0.55 ? Int(400 + random() * 5_000) : 0
            var write = Int(4_000 + random() * (claude ? 26_000 : 9_000)), compacted = false, peak: Int?
            if let window, context + write + input > window * 82 / 100 {
                compacted = true; peak = context + write + input; context = 22_000; write = 22_000
            }
            // After the cache lapsed, the turn's first call writes the whole context again.
            let lapsed = index == plan.lapse && !compacted
            let rewritten = lapsed ? context : 0
            context += write + input
            let kinds = TokenKinds(cacheWrite: write + rewritten, input: input, reasoning: reasoning, output: output,
                                   cacheRead: context * calls * 3 / 5)
            let turnStart = start.addingTimeInterval(span * (Double(index) + random() * 0.4) / Double(plan.turns))
            let helping = claude && index % 4 == 1 && !lapsed
            let part = TokenKinds(cacheWrite: kinds.cacheWrite * 2 / 5, input: kinds.input * 2 / 5, reasoning: kinds.reasoning * 2 / 5,
                                  output: kinds.output * 2 / 5, cacheRead: kinds.cacheRead * 2 / 5)
            let rest = kinds - part
            let turnCost = helping ? cost(rest, plan.agentId).flatMap { own in cost(part, helper).map { own + $0 } } : cost(kinds, plan.agentId)
            turns.append(.init(start: turnStart, end: min(end, turnStart.addingTimeInterval(20 + random() * 150)), tokens: tokens(kinds),
                               calls: calls, contextTokens: context, compacted: compacted, subagents: helping ? tokens(part) : nil,
                               peakContextTokens: peak, recachedTokens: lapsed ? rewritten + input : nil, listCost: turnCost))
            let period = Date(timeIntervalSince1970: (turnStart.timeIntervalSince1970 / UsageBucket.duration).rounded(.down) * UsageBucket.duration)
            if helping {
                byModel[helper, default: .init()] += part
                periods[period, default: [:]][helper, default: .init()] += part
                helped = (helped ?? .init()) + part
                byModel[plan.agentId, default: .init()] += rest
                periods[period, default: [:]][plan.agentId, default: .init()] += rest
            } else {
                byModel[plan.agentId, default: .init()] += kinds
                periods[period, default: [:]][plan.agentId, default: .init()] += kinds
            }
        }
        let listCost = billed ? nil : byModel.reduce(Decimal(0) as Decimal?) { sum, entry in
            guard let sum, let amount = cost(entry.value, entry.key) else { return nil }
            return sum + amount
        }
        return SessionUsage(
            models: byModel.map { SessionUsage.Model(agentId: $0.key, tokens: tokens($0.value)) }
                .sorted { ($0.tokens.kinds.total, $0.agentId) > ($1.tokens.kinds.total, $1.agentId) },
            periods: periods.keys.sorted().flatMap { start in
                periods[start]!.keys.sorted().map { SessionUsage.Period(start: start, agentId: $0, tokens: tokens(periods[start]![$0]!)) }
            },
            subagents: helped.map(tokens), calls: turns.reduce(0) { $0 + $1.calls }, contextTokens: turns.last?.contextTokens,
            costs: billed ? deepSeekSessionCost : nil, turns: turns, contextWindow: window, listCost: listCost)
    }

    /// A demo turn's calls, as the session page lays them out.
    public static func turnCalls(session: String, turn: SessionUsage.Turn) -> [TurnCall] {
        plans.first { $0.id == session }.map { calls(of: turn, plan: $0) } ?? []
    }

    /// A turn's calls, which add up to the turn. The session's own calls read a context that grows to where the turn
    /// ended, later calls reading more of it: a re-cached turn first writes it all again, a compacted one starts from its
    /// peak. One call reads in a large tool result; a sub-agent's calls follow the call that handed it work.
    private static func calls(of turn: SessionUsage.Turn, plan: Plan) -> [TurnCall] {
        var state = UInt64(RecordCoding.milliseconds(turn.start) % 2_147_483_646 + 1)
        func random() -> Double {
            state = state * 16807 % 2_147_483_647
            return Double(state) / 2_147_483_647
        }
        func split(_ total: Int, _ weights: [Double]) -> [Int] {
            let sum = weights.reduce(0, +)
            guard sum > 0 else { return weights.indices.map { $0 == weights.count - 1 ? max(0, total) : 0 } }
            var parts = weights.map { Int(Double(max(0, total)) * $0 / sum) }
            if !parts.isEmpty { parts[parts.count - 1] += max(0, total) - parts.reduce(0, +) }
            return parts
        }
        let sub = turn.subagents ?? .init(), all = turn.tokens
        let subCount = turn.subagents == nil ? 0 : max(1, turn.calls / 3), ownCount = max(2, turn.calls - subCount)
        let ownWrite = all.cacheWriteTokens - sub.cacheWriteTokens
        let ownFresh = all.tokensIn - all.cacheWriteTokens - (sub.tokensIn - sub.cacheWriteTokens)
        let burst = 1 + Int(random() * Double(ownCount - 1)), handoff = max(0, min(ownCount - 2, burst))
        var inWeights = (0..<ownCount).map { _ in 0.3 + random() }
        inWeights[burst] += 4
        if turn.recachedTokens != nil { inWeights[0] += 1_000 }
        let outWeights = (0..<ownCount).map { _ in 0.2 + random() }
        var writes = split(ownWrite, inWeights)
        if turn.compacted { writes = [0] + split(ownWrite, Array(inWeights.dropFirst())) }
        let fresh = split(ownFresh, inWeights)
        // A turn that writes its context again reads none of it on its first call.
        let reads = split(all.cacheReadTokens - sub.cacheReadTokens,
                          (0..<ownCount).map { $0 == 0 && turn.recachedTokens != nil ? 0 : Double($0 + 1) })
        let thoughts = split(all.reasoningTokens - sub.reasoningTokens, outWeights)
        let outputs = split(all.tokensOut - all.reasoningTokens - (sub.tokensOut - sub.reasoningTokens), outWeights)
        let tools = [["Grep"], ["Edit"], ["Bash"], ["Read"], ["Edit"]]
        let source = plan.vendor.lowercased(), billed = plan.vendor == "DeepSeek"
        let times = { (position: Int, count: Int) -> Date in
            turn.start.addingTimeInterval(2 + max(0, turn.end.timeIntervalSince(turn.start) - 2) * Double(position) / Double(max(1, count - 1)))
        }
        func call(_ agentId: String, own: Bool, _ tokens: SessionUsage.Tokens, context: Int?, recached: Int?, tools: [String]) -> TurnCall {
            TurnCall(timestamp: .distantPast, agentId: agentId, tokens: tokens, own: own,
                     log: own ? "demo/\(plan.id).jsonl" : "demo/\(plan.id)/subagent.jsonl", source: source, context: context,
                     recached: recached, listCost: billed ? nil : ModelCatalog.cost(agentId: agentId, kinds: tokens.kinds)?.amount,
                     tools: tools)
        }
        // The context each of the session's own calls leaves: from where the turn began, or from its peak down to what a
        // compaction kept, up to where the turn ended.
        var held = max(0, (turn.contextTokens ?? 0) - ownWrite - ownFresh)
        var result: [TurnCall] = []
        for index in 0..<ownCount {
            let tokens = SessionUsage.Tokens(tokensIn: writes[index] + fresh[index], tokensOut: outputs[index] + thoughts[index],
                                             cacheReadTokens: reads[index], cacheWriteTokens: writes[index], reasoningTokens: thoughts[index])
            held += writes[index] + fresh[index]
            let context = index == 0 && turn.compacted ? turn.peakContextTokens ?? held : held
            let asked = index == ownCount - 1 ? [] : index == handoff && subCount > 0 ? ["Task"] : index == burst - 1 ? ["Read"]
                : index == 0 ? ["Read", "Read"] : tools[index % tools.count]
            result.append(call(plan.agentId, own: true, tokens, context: context,
                               recached: index == 0 && turn.recachedTokens != nil ? tokens.tokensIn : nil, tools: asked))
            guard index == handoff, subCount > 0 else { continue }
            let even = Array(repeating: 1.0, count: subCount)
            let subWrites = split(sub.cacheWriteTokens, even), subFresh = split(sub.tokensIn - sub.cacheWriteTokens, even)
            let subThoughts = split(sub.reasoningTokens, even), subOutputs = split(sub.tokensOut - sub.reasoningTokens, even)
            let subReads = split(sub.cacheReadTokens, (0..<subCount).map { Double($0) + 0.5 })
            for part in 0..<subCount {
                let tokens = SessionUsage.Tokens(tokensIn: subWrites[part] + subFresh[part], tokensOut: subOutputs[part] + subThoughts[part],
                                                 cacheReadTokens: subReads[part], cacheWriteTokens: subWrites[part], reasoningTokens: subThoughts[part])
                result.append(call(helper, own: false, tokens, context: nil, recached: nil,
                                   tools: part == subCount - 1 ? [] : [["Read"], ["Grep"], ["Glob"]][part % 3]))
            }
        }
        return result.enumerated().map { position, call in
            TurnCall(timestamp: times(position, result.count), agentId: call.agentId, tokens: call.tokens, own: call.own, log: call.log,
                     source: call.source, context: call.context, recached: call.recached, listCost: call.listCost, tools: call.tools)
        }
    }

    // MARK: Tokens

    /// A month of tokens in quarter hours, 15 million a day before cache reads, with a model mix that changes through the
    /// day. The same series drives the charts, the model shares and the heat map on every device.
    public static func usage(now: Date) -> [UsageBucket] {
        let end = (now.timeIntervalSince1970 / UsageBucket.duration).rounded(.down) * UsageBucket.duration
        let heights = [64, 16, 34, 4, 24, 48, 6, 6, 22, 24, 12, 20, 44, 62, 38, 4, 72, 16, 6, 24, 8, 44, 62, 72]
        let spenders = [("Claude", "claude-fable-5-1"), ("Claude", "claude-opus-5-5"), ("DeepSeek", "deepseek-v4-flash"),
                        ("Codex", "codex-auto-review"), ("Codex", "gpt-6.1-sol"), ("Claude", "claude-sonnet-5-5")].map(consumerID)
        let mixes = [[5, 3, 0, 0, 0, 0], [1, 0, 0, 0, 0, 0], [2, 0, 1, 0, 0, 0], [0, 0, 1, 0, 0, 0],
                     [1, 0, 0, 0, 0, 0], [3, 2, 0, 0, 0, 0], [1, 0, 0, 0, 0, 0], [1, 0, 0, 0, 0, 0],
                     [1, 0, 0, 0, 0, 0], [1, 0, 0, 0, 0, 0], [1, 0, 0, 0, 0, 0], [1, 0, 0, 0, 0, 0],
                     [2, 3, 0, 1, 0, 0], [1, 4, 0, 3, 0, 0], [0, 3, 0, 2, 0, 0], [0, 1, 0, 0, 0, 0],
                     [0, 2, 0, 1, 0, 0], [0, 1, 0, 0, 0, 0], [0, 0, 0, 0, 1, 0], [0, 0, 0, 0, 3, 1],
                     [0, 0, 0, 0, 0, 1], [1, 3, 0, 1, 0, 0], [0, 3, 0, 1, 0, 0], [0, 2, 0, 1, 0, 0]]
        let multiplier = 15_000_000.0 / Double(heights.reduce(0, +) * 4)
        // Thirty days, so the month differs from the week.
        let count = 30 * 96
        return (0..<count).flatMap { index -> [UsageBucket] in
            let start = Date(timeIntervalSince1970: end - Double(count - index) * UsageBucket.duration)
            let hour = index / 4 % 24, mix = mixes[hour], weight = mix.reduce(0, +)
            return spenders.enumerated().compactMap { position, id in
                let total = Int(Double(heights[hour]) * multiplier * Double(mix[position]) / Double(weight))
                guard total > 0 else { return nil }
                return UsageBucket(start: start, agentId: id, tokensIn: total * 4 / 5, tokensOut: total - total * 4 / 5,
                                   cacheReadTokens: total * (position + 1))
            }
        }
    }

    // MARK: First launch and requests

    /// The sources the demo's first-launch screen lists.
    public static var sources: [SourceStatus] {
        [
            SourceStatus(id: "claude-code", name: "Claude", detail: L10n.text("额度、会话与用量统计", "Quota, sessions and usage"), state: .ready(plan: "max_20x")),
            SourceStatus(id: "codex-cli", name: "Codex", detail: L10n.text("额度、会话与用量统计", "Quota, sessions and usage"), state: .ready(plan: "pro")),
            SourceStatus(id: "deepseek", name: "DeepSeek", detail: L10n.text("余额、会话与用量统计", "Balance, sessions and usage"), state: .ready(plan: nil)),
            SourceStatus(id: "antigravity", name: "Antigravity", detail: L10n.text("安装后自动出现", "Appears once installed"), state: .notDetected),
        ]
    }

    /// The requests the demo shows: clients caught mid-task, the way a working morning actually looks — the test run
    /// the iPhone's demo asks about, one edit worth reading, one build, one ticket and one file. No client is waiting
    /// behind them, so answering one only takes it off the HUD.
    public static func permissionRequests(now: Date = Date()) -> [PermissionRequest] {
        [("demo-tests", -40.0), ("demo-edit", -38), ("demo-build", -124), ("demo-ticket", -71), ("demo-read", -9)]
            .compactMap { permissionRequest($0.0, at: now.addingTimeInterval($0.1)) }
    }

    /// One of the demo's requests by id, as asked at `at`.
    public static func permissionRequest(_ id: String, at: Date) -> PermissionRequest? {
        switch id {
        case "demo-tests":
            return PermissionRequest(
                id: "demo-tests", source: .claude, sessionID: "s1", toolName: "Bash",
                summary: L10n.text("运行测试", "Run the test suite"), detail: "swift test --filter SyncRecordTests",
                cwd: "~/work/agent-hud", at: at)
        case "demo-edit":
            return PermissionRequest(
                id: "demo-edit", source: .claude, sessionID: "demo-1", toolName: "Edit",
                summary: "Avatar.tsx", detail: "~/Projects/acme-web/src/components/Avatar.tsx", cwd: "~/Projects/acme-web",
                path: "~/Projects/acme-web/src/components/Avatar.tsx",
                removed: "  const initials = user.name.slice(0, 2)", added: "  const initials = user?.name?.slice(0, 2) ?? '?'",
                suggestions: [.object([
                    "type": .string("addRules"), "behavior": .string("allow"),
                    "destination": .string("localSettings"),
                    "rules": .array([.object(["toolName": .string("Edit"), "ruleContent": .string("src/**")])]),
                ])],
                at: at)
        case "demo-build":
            return PermissionRequest(
                id: "demo-build", source: .codex, sessionID: "demo-2", toolName: "Bash",
                summary: L10n.text("构建生产版本", "Build for production"), detail: "npm run build",
                cwd: "~/Projects/acme-api", at: at)
        case "demo-ticket":
            return PermissionRequest(
                id: "demo-ticket", source: .codebuddy, sessionID: "demo-3",
                toolName: "mcp__linear__create_issue", summary: "linear · create_issue",
                detail: "team: Mobile\ntitle: Settings screen crashes when offline",
                cwd: "~/Projects/acme-mobile", at: at)
        case "demo-read":
            return PermissionRequest(
                id: "demo-read", source: .claude, sessionID: "demo-4", toolName: "Read",
                summary: "tsconfig.base.json", detail: "~/Projects/acme-shared/tsconfig.base.json", cwd: "~/Projects/acme-web",
                path: "~/Projects/acme-shared/tsconfig.base.json", at: at)
        default:
            return nil
        }
    }
}
