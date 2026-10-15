import Foundation

/// An exact destination on this Mac. Session reports omit it; only a source's local observer record stores it.
public enum SessionNavigationTarget: Hashable, Codable, Sendable {
    case codexThread(id: String)
    case claudeDesktopSession(id: String)
    case claudeCoworkSession(id: String)
    case iTermSession(id: String)
    case antigravityConversation(id: String)
    case grokBotAgent(id: String)

    private enum Kind: String, Codable { case codexThread, claudeDesktopSession, claudeCoworkSession, iTermSession, antigravityConversation, grokBotAgent }
    private enum CodingKeys: String, CodingKey { case kind, id }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(String.self, forKey: .id)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .codexThread: self = .codexThread(id: id)
        case .claudeDesktopSession: self = .claudeDesktopSession(id: id)
        case .claudeCoworkSession: self = .claudeCoworkSession(id: id)
        case .iTermSession: self = .iTermSession(id: id)
        case .antigravityConversation: self = .antigravityConversation(id: id)
        case .grokBotAgent: self = .grokBotAgent(id: id)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .codexThread(let id):
            try values.encode(Kind.codexThread, forKey: .kind)
            try values.encode(id, forKey: .id)
        case .claudeDesktopSession(let id):
            try values.encode(Kind.claudeDesktopSession, forKey: .kind)
            try values.encode(id, forKey: .id)
        case .claudeCoworkSession(let id):
            try values.encode(Kind.claudeCoworkSession, forKey: .kind)
            try values.encode(id, forKey: .id)
        case .iTermSession(let id):
            try values.encode(Kind.iTermSession, forKey: .kind)
            try values.encode(id, forKey: .id)
        case .antigravityConversation(let id):
            try values.encode(Kind.antigravityConversation, forKey: .kind)
            try values.encode(id, forKey: .id)
        case .grokBotAgent(let id):
            try values.encode(Kind.grokBotAgent, forKey: .kind)
            try values.encode(id, forKey: .id)
        }
    }
}
