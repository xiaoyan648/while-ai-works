import Foundation

/// Visible messages from Grok Bot's bounded local replica, which may have missing history or sequence gaps.
public enum GrokBotConversation {
    /// A sign-in switch changes which cached partition can be read, even when the replica itself did not change.
    public static func related(atPath path: String) -> [String] {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        return [GrokBotCache.url(for: GrokBotCache.accountKey, in: directory).path]
    }

    public static func turns(atPath path: String, sessionID: String, since: Date, limit: Int) -> [ConversationTurn] {
        turns(at: URL(fileURLWithPath: path), sessionID: sessionID, since: since, limit: limit, now: Date())
    }

    static func turns(at url: URL, sessionID: String, since: Date, limit: Int, now: Date) -> [ConversationTurn] {
        guard limit > 0 else { return [] }
        let directory = url.deletingLastPathComponent()
        guard let account = GrokBotCache.currentAccount(in: directory),
              let key = try? GrokBotCache.key(at: url), let agent = GrokBotCache.transcriptAgent(key: key, account: account),
              sessionID == GrokBotCache.sessionID(account: account, agent: agent),
              let value = try? GrokBotCache.value(at: url, key: key, schema: 1),
              let persisted = ProviderDate.milliseconds(value["persistedAt"]), now.timeIntervalSince(persisted) <= GrokBotCache.retention,
              let entries = value["entries"].arrayValue else { return [] }
        let result = turns(entries: entries, since: since, limit: limit)
        return GrokBotCache.currentAccount(in: directory) == account ? result : []
    }

    private static func turns(entries: [ProviderJSON], since: Date, limit: Int) -> [ConversationTurn] {
        var result: [ConversationTurn] = [], current: Open?, previousSequence: Int?, seen = Set<String>()
        for entry in entries {
            guard let id = entry["id"].stringValue, !id.isEmpty else { current = nil; previousSequence = nil; continue }
            let sequence = entry["seq"].countValue
            let identity = sequence.map { "\(id)@\($0)" } ?? id
            // Native replicas reject duplicate source identities, rather than treating them as another message.
            guard seen.insert(identity).inserted else { return [] }
            if let previousSequence, let sequence, sequence <= previousSequence || sequence - previousSequence != 1 { current = nil }
            // Without a sequence on either side, adjacency cannot establish that a reply belongs to this prompt.
            if previousSequence == nil || sequence == nil { current = nil }
            previousSequence = sequence
            let request = entry["requestId"].stringValue
            if entry["kind"].stringValue == "message", entry["role"].stringValue == "user" {
                current = nil
                guard let text = messageText(entry), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let date = ProviderDate.milliseconds(entry["timestampMs"]) else { current = nil; continue }
                result.append(.init(turnID: identity, prompt: text, reply: nil, startedAt: date, endedAt: nil))
                current = Open(index: result.count - 1, request: request)
            } else if let text = replyText(entry), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let open = current {
                guard open.request == nil || request == nil || open.request == request else { current = nil; continue }
                let turn = result[open.index]
                // Separate visible messages remain separate paragraphs; no missing content is supplied.
                let reply = turn.reply.map { $0 + "\n\n" + text } ?? text
                result[open.index] = .init(turnID: turn.turnID, prompt: turn.prompt, reply: reply, startedAt: turn.startedAt, endedAt: nil)
            }
        }
        // The cache records no turn-completion event. endedAt=nil is unknown, and is not a live running signal.
        return Array(result.filter { $0.startedAt >= since }.suffix(limit))
    }

    private static func messageText(_ entry: ProviderJSON) -> String? {
        // Native hd() hides suppressed messages; routed agent/human messages are not this agent's prompt or answer.
        guard entry["suppressed"] == .null, entry["fromAgent"] == .null, entry["toAgent"] == .null,
              entry["fromUser"] == .null else { return nil }
        return entry["content"].stringValue
    }

    private static func replyText(_ entry: ProviderJSON) -> String? {
        if entry["kind"].stringValue == "message", entry["role"].stringValue == "assistant" { return messageText(entry) }
        if entry["kind"].stringValue == "send-message", entry["message"]["type"].stringValue == "text" {
            return entry["message"]["content"].stringValue
        }
        return nil
    }

    private struct Open { let index: Int; let request: String? }
}
