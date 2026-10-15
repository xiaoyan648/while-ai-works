import Foundation

/// Grok owns one account while its CLI and desktop client keep independent session layouts.
enum GrokLocalSessions: LocalSessionLayout {
    static let installPaths = GrokSessions.installPaths

    static func roots(home: URL, environment: [String: String]) -> [URL] {
        GrokSessions.roots(home: home, environment: environment) + GrokBotSessions.roots(home: home, environment: environment)
    }

    static func accepts(_ url: URL) -> Bool { GrokSessions.accepts(url) || GrokBotSessions.accepts(url) }
    static func skips(_ url: URL) -> Bool { GrokSessions.skips(url) || GrokBotSessions.skips(url) }
    static func related(_ url: URL) -> [URL] {
        GrokSessions.accepts(url) ? GrokSessions.related(url) : GrokBotSessions.related(url)
    }
    static func read(_ url: URL) throws -> ProviderSessions {
        GrokSessions.accepts(url) ? try GrokSessions.read(url) : try GrokBotSessions.read(url)
    }
    static func merge(_ sessions: [ProviderSession]) -> [ProviderSession] {
        GrokSessions.merge(sessions.filter { $0.client != "Grok Bot" }) + sessions.filter { $0.client == "Grok Bot" }
    }
    static func notice(merging sessions: [ProviderSession]) -> String? {
        GrokSessions.notice(merging: sessions.filter { $0.client != "Grok Bot" })
    }
}
