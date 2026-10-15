import AgentHUDSupport
import Foundation

/// Bot owns its account-scoped session metadata; Cursor owns the dashboard's billing events. Join their exact native
/// conversation identities for display without copying events to another source or inventing parent relationships:
/// a billed sub-agent gets a parent only where the Bot service's own records name one.
enum GrokBotUsage {
    /// The native Bot coordinator recognizes this namespace independently of roster membership or model selector.
    /// It identifies the execution client, but carries no parent-session identity.
    static func subagentID(_ conversationID: String) -> String? {
        let prefix = "sand-subagent-"
        guard conversationID.hasPrefix(prefix) else { return nil }
        let id = String(conversationID.dropFirst(prefix.count))
        return GrokBotCache.isAgentID(id) ? id : nil
    }

    /// Billing identifies an internal child, but does not establish an independently listed Bot conversation.
    /// Older reports called these rows Cursor, so their canonical ID, rather than the displayed client, owns this rule.
    static func isBillingOnlySubagent(_ session: LiveSession) -> Bool {
        guard session.transcriptPath == nil, session.navigationTarget == nil,
              let id = conversationID(session.id) else { return false }
        return subagentID(id) != nil
    }

    /// The run or sub-agent id of a billed conversation's session, nil for any other session.
    static func billedSubagentID(_ sessionID: String) -> String? {
        conversationID(sessionID).flatMap(subagentID)
    }

    /// - routineRuns: the bot each routine run belongs to, by run id, as the Bot service's routine records say. A billed
    ///   run they name becomes a sub-agent of that bot's session; any other billed sub-agent stays a session of its own.
    static func merge(_ sessions: [LiveSession], routineRuns: [String: GrokBotRoutineRuns.Run] = [:]) -> [LiveSession] {
        let billed = Dictionary(grouping: sessions.filter {
            conversationID($0.id) != nil
        }, by: { conversationID($0.id)! })
        let bots = Dictionary(grouping: sessions.filter {
            $0.client == "Grok Bot" && nativeID($0) != nil
        }, by: { nativeID($0)! })
        var joined: [String: LiveSession] = [:], consumed = Set<String>()
        for (id, candidates) in bots {
            guard candidates.count == 1, let bot = candidates.first,
                  let usage = billed[id], usage.count == 1, let bill = usage.first else { continue }
            joined[bot.id] = LiveSession(id: bot.id, agentId: bill.agentId, task: bot.task, terminal: bot.terminal,
                startedAt: min(bot.startedAt, bill.startedAt), endedAt: bot.endedAt.map { max($0, bill.endedAt ?? $0) },
                pctOfWindow: bill.pctOfWindow, tokensIn: bill.tokensIn, tokensOut: bill.tokensOut, client: bot.client,
                transcriptPath: bot.transcriptPath, cacheReadTokens: bill.cacheReadTokens, accountWide: bill.accountWide,
                observedAt: bot.observedAt, workingDirectory: bot.workingDirectory,
                subagentTranscripts: bot.subagentTranscripts, agentName: bot.agentName, subagentSessions: bot.subagentSessions,
                lastActivityAt: max(bot.lastActivityAt ?? bot.startedAt, bill.lastActivityAt ?? bill.startedAt),
                navigationTarget: bot.navigationTarget, usageKey: bill.id)
            consumed.insert(bill.id)
        }
        // A run keeps its billing id, which is its ledger contribution, so its own page and its bot's total read its usage.
        var runs: [String: [LiveSession]] = [:]
        for (conversation, usage) in billed {
            guard let id = subagentID(conversation), let run = routineRuns[id], usage.count == 1, let bill = usage.first,
                  !consumed.contains(bill.id), let owners = bots[run.agent], owners.count == 1, let bot = owners.first else { continue }
            runs[bot.id, default: []].append(LiveSession(id: bill.id, agentId: bill.agentId,
                task: L10n.text("例行任务", "Routine"), terminal: nil, startedAt: bill.startedAt, endedAt: bill.endedAt,
                pctOfWindow: bill.pctOfWindow, tokensIn: bill.tokensIn, tokensOut: bill.tokensOut, client: bot.client,
                cacheReadTokens: bill.cacheReadTokens, accountWide: bill.accountWide, observedAt: bill.observedAt,
                agentName: run.name.isEmpty ? nil : run.name, lastActivityAt: bill.lastActivityAt))
            consumed.insert(bill.id)
        }
        for (botID, children) in runs {
            guard let bot = joined[botID] ?? sessions.first(where: { $0.id == botID }) else { continue }
            let added = children.sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
            joined[botID] = LiveSession(id: bot.id, agentId: bot.agentId, task: bot.task, terminal: bot.terminal,
                startedAt: bot.startedAt, endedAt: bot.endedAt, pctOfWindow: bot.pctOfWindow, tokensIn: bot.tokensIn,
                tokensOut: bot.tokensOut, client: bot.client, transcriptPath: bot.transcriptPath,
                cacheReadTokens: bot.cacheReadTokens, accountWide: bot.accountWide, observedAt: bot.observedAt,
                workingDirectory: bot.workingDirectory, subagentTranscripts: (bot.subagentTranscripts ?? []) + added.map(\.id),
                agentName: bot.agentName, subagentSessions: (bot.subagentSessions ?? []) + added,
                lastActivityAt: bot.lastActivityAt, navigationTarget: bot.navigationTarget, usageKey: bot.usageKey)
        }
        return sessions.compactMap { consumed.contains($0.id) ? nil : joined[$0.id] ?? $0 }
    }

    private static func conversationID(_ id: String) -> String? {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "cursor-account", !parts[1].isEmpty,
              GrokBotCache.isAgentID(String(parts[2])) else { return nil }
        return String(parts[2])
    }

    private static func nativeID(_ session: LiveSession) -> String? {
        guard case .grokBotAgent(let id) = session.navigationTarget else { return nil }
        let parts = session.id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "grok-bot", !parts[1].isEmpty, parts[2] == id else { return nil }
        return id
    }
}
