import Foundation

/// The helper sends quota and identity metadata only. Tokens and the Safe Storage key never leave its memory.
public struct ClaudeDesktopUsageReply: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case available, missing, locked, expired, failed, accountChanged }
    public var status: Status
    public var limits: Data?
    public var account: String?
    public var organization: String?
    public var plan: String?

    public init(status: Status, limits: Data? = nil, account: String? = nil, organization: String? = nil, plan: String? = nil) {
        self.status = status; self.limits = limits; self.account = account; self.organization = organization; self.plan = plan
    }

    var reading: EngineUsageCache.Reading? {
        guard status == .available, let limits, let usage = try? ClaudeUsage.parse(limits),
              let account = ProviderAccount.identified(provider: "Claude", user: account, workspace: organization) else { return nil }
        return .init(usage: .init(usage: usage, subscriptionType: plan, rateLimitsAvailable: true),
                     identity: .init(account: account, email: nil), plan: plan, signedIn: true)
    }
}

/// Shared between the connection indicator and quota collector, so startup/focus do not duplicate requests.
/// Keychain work is isolated in a bounded child process; a background call never permits a system prompt.
public actor ClaudeDesktopUsageClient {
    public static let shared = ClaudeDesktopUsageClient(helper: Bundle.main.url(forResource: "while-ai-works-claude-usage", withExtension: nil))
    private let helper: URL?
    private var cached: (Date, ClaudeDesktopUsageReply)?
    private var pending: (id: UUID, task: Task<ClaudeDesktopUsageReply, Never>)?

    public init(helper: URL?) { self.helper = helper }

    public func fetch(authorize: Bool = false, refresh: Bool = false) async -> ClaudeDesktopUsageReply {
        if !authorize, !refresh, let cached, Date().timeIntervalSince(cached.0) < 60 { return cached.1 }
        if authorize { pending?.task.cancel(); pending = nil; cached = nil }
        if let pending { return await pending.task.value }
        guard let helper else { return .init(status: .missing) }
        let id = UUID()
        let task = Task<ClaudeDesktopUsageReply, Never> {
            do {
                let output = try await ChildProcess.run(helper, authorize ? ["--authorize"] : [],
                                                        timeout: authorize ? 120 : 20, stdoutLimit: 64 * 1024)
                guard output.status == 0, !output.truncated,
                      let reply = try? JSONDecoder().decode(ClaudeDesktopUsageReply.self, from: output.stdout)
                else { return .init(status: .failed) }
                if reply.status == .available, reply.reading == nil { return .init(status: .failed) }
                return reply
            } catch { return .init(status: .failed) }
        }
        pending = (id, task)
        let reply = await task.value
        if pending?.id == id { cached = (Date(), reply); pending = nil }
        return reply
    }

    public func invalidate() { pending?.task.cancel(); pending = nil; cached = nil }
}
