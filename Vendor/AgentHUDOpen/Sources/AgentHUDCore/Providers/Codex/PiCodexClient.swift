import Foundation

/// Pi owns its OAuth lifecycle. Only the existing access token is used, against the fixed first-party usage endpoint.
struct PiCodexClient: Sendable {
    let directory: URL
    var http = ProviderHTTP()

    static var directory: URL { OpenAgentPaths(home: FileManager.default.homeDirectoryForCurrentUser, environment: ProcessInfo.processInfo.environment).pi }

    func fetch(now: Date = Date()) async throws -> CodexRateLimits? {
        let file = directory.appendingPathComponent("auth.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let auth = try JSONDecoder().decode(AuthFile.self, from: Data(contentsOf: file)).codex
        guard let auth else { return nil }
        guard auth.type == "oauth", let token = auth.access, !token.isEmpty,
              let account = auth.accountId, !account.isEmpty,
              let expiry = auth.expires, expiry / 1000 > now.timeIntervalSince1970 else {
            throw UsageProviderError(L10n.text("请在 Pi 中重新登录 ChatGPT", "Sign in to ChatGPT again in Pi"))
        }
        let value = try await http.json(URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
            headers: ["Authorization": "Bearer " + token, "ChatGPT-Account-Id": account])
        return try Self.parse(JSONEncoder().encode(value), expectedAccount: account)
    }

    private struct AuthFile: Decodable {
        let codex: Credential?
        enum CodingKeys: String, CodingKey { case codex = "openai-codex" }
    }

    private struct Credential: Decodable {
        let type: String?
        let access: String?
        let accountId: String?
        let expires: Double?
    }

    /// Field names and window IDs follow the Codex backend-client mapping. Identity comes from the authenticated response.
    static func parse(_ data: Data, expectedAccount: String) throws -> CodexRateLimits {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(Payload.self, from: data)
        guard payload.accountId == expectedAccount, !payload.email.isEmpty else { throw ProviderFailure.format }
        func window(_ value: Payload.Window?) -> CodexRateLimits.Window? {
            value.map { .init(usedPercent: $0.usedPercent, windowDurationMins: $0.limitWindowSeconds.map { $0 / 60 }, resetsAt: $0.resetAt) }
        }
        func bucket(_ value: Payload.Limit, id: String, name: String? = nil) -> CodexRateLimits.Bucket {
            .init(limitId: id, limitName: name, primary: window(value.primaryWindow), secondary: window(value.secondaryWindow), planType: payload.planType)
        }
        var buckets: [String: CodexRateLimits.Bucket] = [:]
        if let limit = payload.rateLimit { buckets["codex"] = bucket(limit, id: "codex") }
        for additional in payload.additionalRateLimits ?? [] {
            buckets[additional.meteredFeature] = bucket(additional.rateLimit, id: additional.meteredFeature, name: additional.limitName)
        }
        return CodexRateLimits(rateLimits: nil, rateLimitsByLimitId: buckets,
            rateLimitResetCredits: payload.rateLimitResetCredits.map { .init(availableCount: $0.availableCount, credits: nil) },
            accountId: payload.accountId, account: .init(type: "chatgpt", email: payload.email, planType: payload.planType))
    }

    private struct Payload: Decodable {
        struct Window: Decodable {
            let usedPercent: Double
            let limitWindowSeconds: Int?
            let resetAt: Double?
        }
        struct Limit: Decodable { let primaryWindow: Window?; let secondaryWindow: Window? }
        struct Additional: Decodable { let meteredFeature: String; let limitName: String?; let rateLimit: Limit }
        struct Credits: Decodable { let availableCount: Int }
        let accountId: String
        let email: String
        let planType: String?
        let rateLimit: Limit?
        let additionalRateLimits: [Additional]?
        let rateLimitResetCredits: Credits?
    }
}
