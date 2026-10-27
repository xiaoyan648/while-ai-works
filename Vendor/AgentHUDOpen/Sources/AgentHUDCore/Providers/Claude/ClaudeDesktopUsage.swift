import Foundation
import CryptoKit
import SQLite3

/// The helper sends quota and identity metadata only. Tokens and the Safe Storage key never leave its memory.
public struct ClaudeDesktopUsageReply: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case available, missing, locked, expired, failed, accountChanged }
    public var status: Status
    public var limits: Data?
    public var account: String?
    public var organization: String?
    public var plan: String?
    public var observedAt: Date?
    public var retryAt: Date?
    public var failureStatus: Status?

    public init(status: Status, limits: Data? = nil, account: String? = nil, organization: String? = nil, plan: String? = nil) {
        self.status = status; self.limits = limits; self.account = account; self.organization = organization; self.plan = plan
    }

    var reading: EngineUsageCache.Reading? {
        guard status == .available, let limits, let usage = try? ClaudeUsage.parse(limits),
              let account = ProviderAccount.identified(provider: "Claude", user: account, workspace: organization) else { return nil }
        return .init(usage: .init(usage: usage, subscriptionType: plan, rateLimitsAvailable: true),
                     identity: .init(account: account, email: nil), plan: plan, signedIn: true,
                     warning: failureStatus == nil ? nil : "额度暂未更新，显示上次读数；已延后重试。")
    }
}

/// All Claude quota callers share these limits. Jitter spreads load; it does not disguise requests.
public enum ClaudeQuotaPolling {
    public static let manualSpacing: TimeInterval = 5 * 60
    public static func interval(failures: Int, random: Double) -> TimeInterval {
        let jitter = min(1, max(0, random))
        if failures == 0 { return (15 + 5 * jitter) * 60 }
        let base = min(120, 30 * pow(2, Double(min(failures - 1, 3))))
        return base * (1 + 0.5 * jitter) * 60
    }
}

/// Shared, persistent cooldown and last good reading. Never persists credentials or starts login UI.
public actor ClaudeDesktopUsageClient {
    public static let shared = ClaudeDesktopUsageClient(
        helper: Bundle.main.url(forResource: "while-ai-works-claude-usage", withExtension: nil),
        cacheURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WhileAIWorks/claude-quota-cache-v1.json"),
        identity: { ClaudeDesktopQuotaIdentity.current() })
    private struct Cache: Codable {
        var identity: String
        var attemptedAt: Date
        var nextAttemptAt: Date
        var failures: Int
        var reply: ClaudeDesktopUsageReply
    }
    private let helper: URL?
    private let cacheURL: URL?
    private let clock: @Sendable () -> Date
    private let random: @Sendable () -> Double
    private let identity: @Sendable () -> String?
    private var cached: Cache?
    private var pending: (id: UUID, task: Task<ClaudeDesktopUsageReply, Never>)?

    public init(helper: URL?, cacheURL: URL? = nil, clock: @escaping @Sendable () -> Date = { Date() },
                random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
                identity: @escaping @Sendable () -> String? = { "isolated-client" }) {
        self.helper = helper; self.cacheURL = cacheURL; self.clock = clock; self.random = random; self.identity = identity
        if let cacheURL, let data = try? Data(contentsOf: cacheURL), data.count <= 128 * 1024,
           let cache = try? JSONDecoder().decode(Cache.self, from: data),
           cache.attemptedAt <= clock(), clock().timeIntervalSince(cache.attemptedAt) < 24 * 3600,
           cache.nextAttemptAt.timeIntervalSince(cache.attemptedAt) <= 3 * 3600 {
            cached = cache
        }
    }

    public func fetch(authorize: Bool = false, refresh: Bool = false) async -> ClaudeDesktopUsageReply {
        let now = clock()
        guard let currentIdentity = identity() else {
            cached = nil; save(); return .init(status: .missing)
        }
        if let old = cached, old.identity != currentIdentity {
            // A switch/sign-out must never relabel an old quota as the new account's. Keep the request cooldown.
            cached = Cache(identity: currentIdentity, attemptedAt: old.attemptedAt,
                           nextAttemptAt: old.nextAttemptAt, failures: old.failures,
                           reply: .init(status: .accountChanged))
            save()
        }
        if let old = cached, old.reply.status == .available, let observed = old.reply.observedAt,
           now.timeIntervalSince(observed) >= 24 * 3600 {
            cached?.reply = .init(status: .failed); cached?.reply.retryAt = old.nextAttemptAt; save()
        }
        if !authorize, let cached, now < cached.nextAttemptAt {
            let manualAllowed = refresh && cached.failures == 0 && now.timeIntervalSince(cached.attemptedAt) >= ClaudeQuotaPolling.manualSpacing
            if !manualAllowed { return cached.reply }
        }
        if authorize { pending?.task.cancel(); pending = nil }
        if let pending { return await pending.task.value }
        guard let helper else { return .init(status: .missing) }
        let id = UUID()
        let task = Task<ClaudeDesktopUsageReply, Never> {
            let reply: ClaudeDesktopUsageReply
            do {
                let output = try await ChildProcess.run(helper, authorize ? ["--authorize"] : [],
                                                        timeout: authorize ? 120 : 20, stdoutLimit: 64 * 1024)
                if output.status == 0, !output.truncated,
                   let decoded = try? JSONDecoder().decode(ClaudeDesktopUsageReply.self, from: output.stdout),
                   decoded.status != .available || decoded.reading != nil { reply = decoded }
                else { reply = .init(status: .failed) }
            } catch { reply = .init(status: .failed) }
            return complete(reply, id: id, currentIdentity: currentIdentity)
        }
        pending = (id, task)
        return await task.value
    }

    private func complete(_ result: ClaudeDesktopUsageReply, id: UUID, currentIdentity: String) -> ClaudeDesktopUsageReply {
        var reply = result
        guard pending?.id == id else { return .init(status: .failed) }
        pending = nil
        guard identity() == currentIdentity else {
            cached = nil; save(); return .init(status: .accountChanged)
        }
        let completed = clock()
        let failures = reply.status == .failed ? min(4, (cached?.failures ?? 0) + 1) : 0
        let retryAt = completed.addingTimeInterval(ClaudeQuotaPolling.interval(failures: failures, random: random()))
        if reply.status == .available { reply.observedAt = completed }
        else if [.failed, .locked, .expired].contains(reply.status),
                let previous = cached?.reply, previous.status == .available,
                let observed = previous.observedAt, completed.timeIntervalSince(observed) < 24 * 3600 {
            let failure = reply.status
            reply = previous; reply.failureStatus = failure
        }
        reply.retryAt = retryAt
        cached = Cache(identity: currentIdentity, attemptedAt: completed, nextAttemptAt: retryAt, failures: failures, reply: reply)
        save()
        return reply
    }

    private func save() {
        guard let cacheURL else { return }
        guard let cached else { try? FileManager.default.removeItem(at: cacheURL); return }
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(cached).write(to: cacheURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        } catch { /* A cache failure cannot turn a successful remote reading into a login error. */ }
    }

    public func nextCheckAt() -> Date? { cached?.nextAttemptAt }

    public func invalidate() { pending?.task.cancel(); pending = nil; cached = nil; save() }
}

/// Local identity check only: no Keychain, no decryption and no network. Organization cookie ciphertext is hashed,
/// and the session cookie is checked for presence only. A different account/org or sign-out invalidates retained quota.
enum ClaudeDesktopQuotaIdentity {
    static func current(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude"), now: Date = Date()) -> String? {
        let url = directory.appendingPathComponent("config.json")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 8 * 1024 * 1024,
              let data = try? Data(contentsOf: url), let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = config["lastKnownAccountUuid"] as? String, UUID(uuidString: account) != nil,
              config["oauth:tokenCache"] is String || config["oauth:tokenCacheV2"] is String else { return nil }
        var database: OpaquePointer?
        guard sqlite3_open_v2(directory.appendingPathComponent("Cookies").path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = database else {
            sqlite3_close(database); return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        let sql = "SELECT name,host_key,encrypted_value,expires_utc,is_httponly FROM cookies WHERE host_key IN ('claude.ai','.claude.ai') AND name IN ('lastActiveOrg','sessionKey') AND path='/' AND is_secure=1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var organizations = [String](), session = false, count = 0
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { return nil }
            count += 1; guard count <= 16 else { return nil }
            let expiry = Double(sqlite3_column_int64(statement, 3)) / 1_000_000 - 11_644_473_600
            guard expiry <= -11_644_473_600 || expiry > now.timeIntervalSince1970,
                  let name = sqlite3_column_text(statement, 0), let host = sqlite3_column_text(statement, 1) else { continue }
            let size = Int(sqlite3_column_bytes(statement, 2))
            guard size > 3, size < 4096 else { continue }
            if String(cString: name) == "sessionKey" { session = session || sqlite3_column_int(statement, 4) != 0; continue }
            guard let bytes = sqlite3_column_blob(statement, 2) else { return nil }
            organizations.append(String(cString: host) + ":" + Data(bytes: bytes, count: size).base64EncodedString())
        }
        guard session, !organizations.isEmpty else { return nil }
        return SHA256.hash(data: Data(([account.lowercased()] + organizations.sorted()).joined(separator: "|").utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
