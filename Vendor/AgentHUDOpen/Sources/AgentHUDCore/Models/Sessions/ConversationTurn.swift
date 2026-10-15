import Foundation

/// One source-identified user prompt and the agent's visible reply. Tool payloads and reasoning are excluded.
public struct ConversationTurn: Equatable, Sendable {
    public let turnID: String
    public let prompt: String
    public let reply: String?
    public let startedAt: Date
    public let endedAt: Date?

    public init(turnID: String, prompt: String, reply: String?, startedAt: Date, endedAt: Date?) {
        self.turnID = turnID; self.prompt = prompt; self.reply = reply
        self.startedAt = startedAt; self.endedAt = endedAt
    }
}
