import Foundation
import Security
import CommonCrypto
import CryptoKit
import SQLite3
import AgentHUDCore

// This executable deliberately has no AppKit or browser-launch path. Only --authorize, invoked by a user button,
// permits the system Keychain dialog. Background invocations disable legacy Keychain interaction as well as LA UI.
final class ClaudeQuotaSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum DesktopReadFailure: Error { case missing, locked, expired, failed, accountChanged }
struct DesktopCredential {
    let token: String
    let account: String
    let organization: String
}

enum ClaudeDesktopReader {
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude")
    static let maximumFileSize = 8 * 1024 * 1024

    static func config(at directory: URL) throws -> [String: Any] {
        let url = directory.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw DesktopReadFailure.missing }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumFileSize,
              let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw DesktopReadFailure.failed }
        return object
    }

    static func key(authorize: Bool) throws -> Data {
        // kSecUseAuthenticationUIFail alone does not suppress legacy macOS ACL prompts reliably.
        // This is process-wide, hence the dedicated helper rather than a change in the host app.
        SecKeychainSetUserInteractionAllowed(authorize)
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "Claude Safe Storage",
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        if !authorize { query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let password = result as? Data,
              !password.isEmpty else { throw DesktopReadFailure.locked }
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let status = password.withUnsafeBytes { bytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), bytes.baseAddress!.assumingMemoryBound(to: CChar.self),
                                password.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        }
        guard status == kCCSuccess else { throw DesktopReadFailure.failed }
        return Data(key)
    }

    // Chromium macOS OSCrypt v10: PBKDF2-HMAC-SHA1, AES-128-CBC, PKCS#7; never accept plaintext fallback.
    static func decrypt(_ encrypted: Data, key: Data) throws -> Data {
        guard encrypted.starts(with: Data("v10".utf8)), encrypted.count > 3,
              (encrypted.count - 3) % kCCBlockSizeAES128 == 0, key.count == kCCKeySizeAES128 else { throw DesktopReadFailure.failed }
        let input = Array(encrypted.dropFirst(3)), iv = [UInt8](repeating: 32, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128), length = 0
        let status = key.withUnsafeBytes { bytes in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    bytes.baseAddress, key.count, iv, input, input.count, &output, output.count, &length)
        }
        guard status == kCCSuccess else { throw DesktopReadFailure.failed }
        return Data(output.prefix(length))
    }

    static func cookieValue(_ encrypted: Data, host: String, version: Int, key: Data) throws -> String {
        var clear = try decrypt(encrypted, key: key)
        if version >= 24 {
            let digest = Data(SHA256.hash(data: Data(host.utf8)))
            guard clear.starts(with: digest) else { throw DesktopReadFailure.failed }
            clear = clear.dropFirst(digest.count)
        }
        guard let value = String(data: clear, encoding: .utf8) else { throw DesktopReadFailure.failed }
        return value.removingPercentEncoding ?? value
    }

    static func activeOrganization(at directory: URL, key: Data, now: Date = Date()) throws -> String {
        var database: OpaquePointer?
        guard sqlite3_open_v2(directory.appendingPathComponent("Cookies").path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = database else { sqlite3_close(database); throw DesktopReadFailure.missing }
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw DesktopReadFailure.failed }
        var version = 0
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key='version'", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW { version = Int(sqlite3_column_int(statement, 0)) }
        sqlite3_finalize(statement); statement = nil
        let sql = "SELECT name,host_key,encrypted_value,expires_utc,is_secure,is_httponly FROM cookies WHERE host_key IN ('claude.ai','.claude.ai') AND name IN ('lastActiveOrg','sessionKey') AND path='/'"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw DesktopReadFailure.failed }
        defer { sqlite3_finalize(statement) }
        var organizations = Set<String>(), hasSession = false, count = 0
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw DesktopReadFailure.failed }
            count += 1; guard count <= 16 else { throw DesktopReadFailure.failed }
            let expiry = Double(sqlite3_column_int64(statement, 3)) / 1_000_000 - 11_644_473_600
            guard expiry <= -11_644_473_600 || expiry > now.timeIntervalSince1970,
                  sqlite3_column_int(statement, 4) != 0,
                  let namePointer = sqlite3_column_text(statement, 0), let hostPointer = sqlite3_column_text(statement, 1) else { continue }
            let name = String(cString: namePointer), host = String(cString: hostPointer)
            if name == "sessionKey" {
                hasSession = (sqlite3_column_int(statement, 5) != 0 && sqlite3_column_bytes(statement, 2) > 3) || hasSession
                continue
            }
            let size = Int(sqlite3_column_bytes(statement, 2))
            guard size > 0, size < 4096, let bytes = sqlite3_column_blob(statement, 2) else { continue }
            let value = try cookieValue(Data(bytes: bytes, count: size), host: host, version: version, key: key)
            guard let id = UUID(uuidString: value) else { throw DesktopReadFailure.failed }
            organizations.insert(id.uuidString.lowercased())
        }
        guard hasSession else { throw DesktopReadFailure.missing }
        guard organizations.count == 1, let organization = organizations.first else { throw DesktopReadFailure.failed }
        return organization
    }

    static func credential(config: [String: Any], organization: String, key: Data, now: Date = Date()) throws -> DesktopCredential {
        guard let rawAccount = config["lastKnownAccountUuid"] as? String, let account = UUID(uuidString: rawAccount)?.uuidString.lowercased()
        else { throw DesktopReadFailure.missing }
        var entries: [String: Any] = [:]
        for field in ["oauth:tokenCache", "oauth:tokenCacheV2"] {
            guard let encoded = config[field] as? String, let data = Data(base64Encoded: encoded) else { continue }
            guard let cache = try JSONSerialization.jsonObject(with: decrypt(data, key: key)) as? [String: Any] else { throw DesktopReadFailure.failed }
            entries.merge(cache) { _, newer in newer }
        }
        var matches: [(String, Double)] = [], expired = false
        let clients = ["9d1c250a-e61b-44d9-88ed-5944d1962f5e", "a473d7bb-17ac-43a7-abc0-a1343d7c2805"]
        for (name, object) in entries {
            guard let client = clients.first(where: { name.hasPrefix("acct:\(account)|\($0):\(organization):https://api.anthropic.com:") }) else { continue }
            let prefix = "acct:\(account)|\(client):\(organization):https://api.anthropic.com:"
            let scopes = Set(name.dropFirst(prefix.count).split(separator: " ").map(String.init))
            guard scopes.contains("user:profile"), scopes.contains("user:inference"), scopes.contains("user:sessions:claude_code"),
                  let entry = object as? [String: Any], let token = entry["token"] as? String, !token.isEmpty else { continue }
            let expiry = (entry["expiresAt"] as? Double ?? 0) / 1000
            guard expiry > now.timeIntervalSince1970 + 15 else { expired = true; continue }
            guard token.utf8.count < 16_384, !token.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw DesktopReadFailure.failed }
            matches.append((token, expiry))
        }
        guard let token = matches.max(by: { $0.1 < $1.1 })?.0 else { throw expired ? DesktopReadFailure.expired : DesktopReadFailure.missing }
        return DesktopCredential(token: token, account: account, organization: organization)
    }

    static func get(_ path: String, credential: DesktopCredential, session: URLSession) async throws -> Data {
        // Both destinations are observed in the installed Claude client. No configurable hosts or redirects.
        guard ["/api/oauth/profile", "/api/oauth/usage"].contains(path) else { throw DesktopReadFailure.failed }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com" + path)!)
        request.timeoutInterval = 8
        request.setValue("Bearer " + credential.token, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw DesktopReadFailure.failed }
        if response.statusCode == 401 { throw DesktopReadFailure.expired }
        guard response.statusCode == 200 else { throw DesktopReadFailure.failed }
        var body = Data()
        for try await byte in bytes {
            guard body.count < 256 * 1024 else { throw DesktopReadFailure.failed }
            body.append(byte)
        }
        return body
    }

    static func run(authorize: Bool, directory: URL = ClaudeDesktopReader.directory,
                    readKey: (Bool) throws -> Data = { try key(authorize: $0) },
                    testSession: URLSession? = nil) async -> ClaudeDesktopUsageReply {
        do {
            let before = try config(at: directory)
            guard before["oauth:tokenCache"] is String || before["oauth:tokenCacheV2"] is String else { throw DesktopReadFailure.missing }
            let key = try readKey(authorize)
            let organization = try activeOrganization(at: directory, key: key)
            let credential = try credential(config: before, organization: organization, key: key)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForResource = 10
            let session = testSession ?? URLSession(configuration: configuration, delegate: ClaudeQuotaSessionDelegate(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let profileData = try await get("/api/oauth/profile", credential: credential, session: session)
            guard let profile = try JSONSerialization.jsonObject(with: profileData) as? [String: Any],
                  let account = profile["account"] as? [String: Any], let org = profile["organization"] as? [String: Any],
                  (account["uuid"] as? String)?.lowercased() == credential.account,
                  (org["uuid"] as? String)?.lowercased() == credential.organization else { throw DesktopReadFailure.accountChanged }
            let limits = try await get("/api/oauth/usage", credential: credential, session: session)
            let usage = try ClaudeUsage.parse(limits)
            // Recheck the selected account, organization and token after suspension. Never label old-account quota as current.
            let after = try self.credential(config: config(at: directory), organization: activeOrganization(at: directory, key: key), key: key)
            guard after.account == credential.account, after.organization == credential.organization, after.token == credential.token else { throw DesktopReadFailure.accountChanged }
            func window(_ value: ClaudeUsageWindow?) throws -> Any {
                guard let value else { return NSNull() }
                guard value.utilizationPct.isFinite, (0...100).contains(value.utilizationPct) else { throw DesktopReadFailure.failed }
                return ["utilization": value.utilizationPct, "resets_at": value.resetsAt.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull()]
            }
            var clean: [String: Any] = ["five_hour": try window(usage.fiveHour), "seven_day": try window(usage.sevenDay),
                                       "seven_day_opus": try window(usage.sevenDayOpus), "seven_day_sonnet": try window(usage.sevenDaySonnet)]
            clean["limits"] = try usage.modelWeekly.sorted(by: { $0.key < $1.key }).map { family, value -> [String: Any] in
                let safe = try window(value) as! [String: Any]
                return ["kind": "weekly_scoped", "scope": ["model": ["display_name": family]],
                        "percent": safe["utilization"]!, "resets_at": safe["resets_at"]!]
            }
            var type = (org["organization_type"] as? String)?.replacingOccurrences(of: "claude_", with: "")
            if type == "max" {
                if org["rate_limit_tier"] as? String == "default_claude_max_5x" { type = "max_5x" }
                if org["rate_limit_tier"] as? String == "default_claude_max_20x" { type = "max_20x" }
            }
            return .init(status: .available, limits: try JSONSerialization.data(withJSONObject: clean), account: credential.account,
                         organization: credential.organization, plan: type)
        } catch DesktopReadFailure.missing { return .init(status: .missing) }
        catch DesktopReadFailure.locked { return .init(status: .locked) }
        catch DesktopReadFailure.expired { return .init(status: .expired) }
        catch DesktopReadFailure.accountChanged { return .init(status: .accountChanged) }
        catch { return .init(status: .failed) }
    }
}

#if !CLAUDE_DESKTOP_CHECKS
@main enum ClaudeDesktopUsageHelper {
    static func main() async {
        let result = await ClaudeDesktopReader.run(authorize: CommandLine.arguments.dropFirst().elementsEqual(["--authorize"]))
        if let data = try? JSONEncoder().encode(result) { FileHandle.standardOutput.write(data) }
    }
}
#endif
