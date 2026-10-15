import AgentHUDSupport
import Foundation

/// An explicit, successful end of one turn. Inactivity is never a completion.
public struct SessionCompletion: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let sessionID: String
    public let vendor: String
    /// Execution client, distinct from the account provider.
    public var client: String?
    public var agentVendor: String { SessionSource(vendor: vendor, client: client).agentVendor ?? vendor }
    public var task: String
    public let model: String
    public let startedAt: Date?
    public let completedAt: Date
    /// The final reply's last paragraph, kept only in memory for the local completion reminder.
    public let message: String?
    /// Source-owned destination on this Mac; never encoded with completion reports.
    public var navigationTarget: SessionNavigationTarget?

    public init(sessionID: String, vendor: String, turnID: String, task: String, model: String,
                startedAt: Date?, completedAt: Date, message: String? = nil, navigationTarget: SessionNavigationTarget? = nil,
                client: String? = nil) {
        id = RecordCoding.hash([vendor, sessionID, turnID])
        self.sessionID = sessionID; self.vendor = vendor; self.task = task; self.model = model
        self.client = client
        self.startedAt = startedAt; self.completedAt = completedAt
        self.message = Self.lastParagraph(message)
        self.navigationTarget = navigationTarget
    }

    static func lastParagraph(_ message: String?) -> String? {
        guard let message else { return nil }
        var lines: [Substring] = []
        for line in message.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).reversed() {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !lines.isEmpty { break }
            } else {
                lines.append(line)
            }
        }
        let paragraph = lines.reversed().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paragraph.isEmpty else { return nil }
        return paragraph.count > 600 ? String(paragraph.prefix(599)) + "…" : paragraph
    }

    private enum CodingKeys: String, CodingKey {
        case id, sessionID, vendor, client, task, model, startedAt, completedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        sessionID = try values.decode(String.self, forKey: .sessionID)
        vendor = try values.decode(String.self, forKey: .vendor)
        client = try values.decodeIfPresent(String.self, forKey: .client)
        task = try values.decode(String.self, forKey: .task)
        model = try values.decode(String.self, forKey: .model)
        startedAt = try values.decodeIfPresent(Date.self, forKey: .startedAt)
        completedAt = try values.decode(Date.self, forKey: .completedAt)
        message = nil
        navigationTarget = nil
    }
}
