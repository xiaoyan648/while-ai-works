import Foundation

/// Rows of one account inside a vendor group.
public struct AccountSection: Identifiable, Sendable {
    public let id: String
    public let account: AccountObservation?
    public let isCurrent: Bool
    public let rows: [AgentRow]
}
