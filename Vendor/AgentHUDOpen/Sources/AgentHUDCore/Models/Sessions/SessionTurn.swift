import AgentHUDSupport
import Foundation

/// An explicitly identified agent turn. Timestamps belong to source events, never a cache read.
public struct SessionTurn: Codable, Hashable, Sendable, Identifiable {
    /// `waitingForApproval` is a running turn the client says is blocked on the user.
    public enum State: String, Codable, Sendable { case running, waitingForApproval, completed, ended }
    public let provider: String
    public let sessionID: String
    public let turnID: String
    public let state: State
    public let startedAtMs: Int64?
    public let observedAtMs: Int64
    /// The agent's last visible output in this turn, from clients whose records carry it.
    public let message: String?
    public var id: String { RecordCoding.hash([provider, sessionID, turnID]) }

    public init(provider: String, sessionID: String, turnID: String, state: State,
                startedAtMs: Int64?, observedAtMs: Int64, message: String? = nil) {
        self.provider = provider; self.sessionID = sessionID; self.turnID = turnID
        self.state = state; self.startedAtMs = startedAtMs; self.observedAtMs = observedAtMs
        self.message = message
    }
}
