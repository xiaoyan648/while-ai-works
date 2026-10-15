import Foundation

/// The engine reports only "max" through get_usage; its account profile supplies the specific tier and the account.
enum ClaudeSubscription {
    /// `CLAUDE_CONFIG_DIR`, when it is set.
    static func configDirectory(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        ClientHome.variable("CLAUDE_CONFIG_DIR", in: environment).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Claude Code's configuration directory: `CLAUDE_CONFIG_DIR`, else `~/.claude`. The account profile and the hooks
    /// written into its settings both follow it.
    static func directory(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                          environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        configDirectory(environment) ?? home.appendingPathComponent(".claude", isDirectory: true)
    }

    /// Inside a configured directory, beside the default one.
    static var accountProfileURL: URL {
        (configDirectory() ?? FileManager.default.homeDirectoryForCurrentUser).appendingPathComponent(".claude.json")
    }

    /// `ClientHome.key` of the Claude Code configuration directory this app reads.
    static var home: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ClientHome.key(directory(home: home), defaultDirectory: home.appendingPathComponent(".claude", isDirectory: true))
    }

    static func plan(type: String?, profileData: Data?) -> String? {
        guard type == "max", let account = profileData.flatMap(decode), account.organizationType == "claude_max"
        else { return type }
        switch account.userRateLimitTier ?? account.organizationRateLimitTier {
        case "default_claude_max_5x": return "max_5x"
        case "default_claude_max_20x": return "max_20x"
        default: return type
        }
    }

    /// Claude Code itself treats the account and organization UUID pair as the login identity.
    static func identity(profileData: Data?) -> Identity? {
        guard let account = profileData.flatMap(decode),
              let provider = ProviderAccount.identified(provider: "Claude", user: account.accountUuid, workspace: account.organizationUuid)
        else { return nil }
        return Identity(account: provider, email: account.emailAddress)
    }

    struct Identity: Hashable, Sendable {
        let account: ProviderAccount
        let email: String?
    }

    private static func decode(_ data: Data) -> Profile.Account? {
        (try? JSONDecoder().decode(Profile.self, from: data))?.oauthAccount
    }

    private struct Profile: Decodable {
        let oauthAccount: Account?

        struct Account: Decodable {
            let organizationType: String?
            let organizationRateLimitTier: String?
            let userRateLimitTier: String?
            let accountUuid: String?
            let organizationUuid: String?
            let emailAddress: String?
        }
    }
}
