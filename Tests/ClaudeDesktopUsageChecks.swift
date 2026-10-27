import Foundation
import CommonCrypto
import CryptoKit
import SQLite3
import AgentHUDCore

final class QuotaProtocol: URLProtocol {
    static var respond: (URLRequest) -> (Int, Data) = { _ in (500, Data()) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, body) = Self.respond(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main enum ClaudeDesktopUsageChecks {
    static let account = "11111111-1111-4111-8111-111111111111", org = "22222222-2222-4222-8222-222222222222"
    static let second = "33333333-3333-4333-8333-333333333333"
    static let key = Data(repeating: 7, count: 16)
    static let scope = "user:inference user:file_upload user:profile user:sessions:claude_code"
    static func entryName(_ account: String = account, _ org: String = org, host: String = "https://api.anthropic.com") -> String {
        "acct:\(account)|9d1c250a-e61b-44d9-88ed-5944d1962f5e:\(org):\(host):\(scope)"
    }
    static func encrypt(_ bytes: Data) -> Data {
        var output = [UInt8](repeating: 0, count: bytes.count + 16), count = 0
        let iv = [UInt8](repeating: 32, count: 16)
        let status = key.withUnsafeBytes { k in bytes.withUnsafeBytes { b in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    k.baseAddress, 16, iv, b.baseAddress, bytes.count, &output, output.count, &count)
        } }
        precondition(status == 0)
        return Data("v10".utf8) + Data(output.prefix(count))
    }
    static func encryptedJSON(_ value: Any) throws -> String { encrypt(try JSONSerialization.data(withJSONObject: value)).base64EncodedString() }
    static func token(_ expiry: Double = Date().timeIntervalSince1970 + 3600) -> [String: Any] {
        ["token": "test-only-bearer", "expiresAt": expiry * 1000, "subscriptionType": "pro"]
    }
    static func configuration(_ entries: [String: Any]) throws -> [String: Any] {
        ["lastKnownAccountUuid": account, "oauth:tokenCacheV2": try encryptedJSON(entries)]
    }
    static func expectFailure(_ error: DesktopReadFailure, _ operation: () throws -> Void) {
        do { try operation(); fatalError("expected failure") } catch let actual as DesktopReadFailure { precondition(String(describing: actual) == String(describing: error)) }
        catch { fatalError("unexpected error") }
    }
    static func main() async throws {
        let valid = try configuration([entryName(): token(), entryName(second): token()])
        let credential = try ClaudeDesktopReader.credential(config: valid, organization: org, key: key)
        precondition(credential.account == account && credential.organization == org)
        expectFailure(.missing) { _ = try ClaudeDesktopReader.credential(config: valid, organization: second, key: key) }
        expectFailure(.missing) { _ = try ClaudeDesktopReader.credential(config: configuration([entryName(host: "https://example.invalid"): token()]), organization: org, key: key) }
        expectFailure(.expired) { _ = try ClaudeDesktopReader.credential(config: configuration([entryName(): token(1)]), organization: org, key: key) }
        var revoked = valid
        revoked["oauth:tokenCache"] = try encryptedJSON([entryName(): token()])
        revoked["oauth:tokenCacheV2"] = try encryptedJSON([entryName(): NSNull()])
        expectFailure(.missing) { _ = try ClaudeDesktopReader.credential(config: revoked, organization: org, key: key) }
        expectFailure(.failed) { _ = try ClaudeDesktopReader.decrypt(Data("plaintext".utf8), key: key) }
        expectFailure(.failed) { _ = try ClaudeDesktopReader.decrypt(Data("v10short".utf8), key: key) }
        let cookie = encrypt(Data(SHA256.hash(data: Data(".claude.ai".utf8))) + Data(org.utf8))
        let cookieOrg = try ClaudeDesktopReader.cookieValue(cookie, host: ".claude.ai", version: 24, key: key)
        precondition(cookieOrg == org)
        expectFailure(.failed) { _ = try ClaudeDesktopReader.cookieValue(cookie, host: "example.invalid", version: 24, key: key) }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-quota-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("config.json")
        func save(_ object: [String: Any]) throws { try JSONSerialization.data(withJSONObject: object).write(to: configURL, options: .atomic) }
        var keyReads = 0
        let absent = await ClaudeDesktopReader.run(authorize: false, directory: root, readKey: { _ in keyReads += 1; return key })
        precondition(absent.status == .missing && keyReads == 0, "no credentials means no keychain attempt")
        try save(valid)
        let locked = await ClaudeDesktopReader.run(authorize: false, directory: root, readKey: { authorize in
            precondition(!authorize); throw DesktopReadFailure.locked
        })
        precondition(locked.status == .locked)
        var database: OpaquePointer?
        precondition(sqlite3_open(root.appendingPathComponent("Cookies").path, &database) == SQLITE_OK)
        func sql(_ value: String) { precondition(sqlite3_exec(database, value, nil, nil, nil) == SQLITE_OK) }
        sql("CREATE TABLE meta(key TEXT,value INTEGER); INSERT INTO meta VALUES('version',24)")
        sql("CREATE TABLE cookies(name TEXT,host_key TEXT,encrypted_value BLOB,expires_utc INTEGER,is_secure INTEGER,is_httponly INTEGER,path TEXT)")
        let hex = cookie.map { String(format: "%02x", $0) }.joined()
        sql("INSERT INTO cookies VALUES('lastActiveOrg','.claude.ai',X'\(hex)',0,1,0,'/')")
        sql("INSERT INTO cookies VALUES('sessionKey','.claude.ai',X'76313001020304050607080900112233445566',0,1,1,'/')")
        sqlite3_close(database)
        let activeOrg = try ClaudeDesktopReader.activeOrganization(at: root, key: key)
        precondition(activeOrg == org)

        var calls = 0, wrongProfile = false, responseCode = 200, switchAccount = false
        QuotaProtocol.respond = { request in
            calls += 1
            precondition(request.url?.host == "api.anthropic.com" && request.url?.scheme == "https")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-bearer")
            if request.url?.path == "/api/oauth/profile" {
                return (responseCode, try! JSONSerialization.data(withJSONObject: ["account": ["uuid": wrongProfile ? second : account], "organization": ["uuid": org, "organization_type": "claude_pro"]]))
            }
            precondition(request.url?.path == "/api/oauth/usage")
            if switchAccount { try! save(["lastKnownAccountUuid": second, "oauth:tokenCacheV2": try! encryptedJSON([entryName(second): token()])]) }
            return (responseCode, Data(#"{"five_hour":{"utilization":47,"resets_at":"2026-10-27T10:00:00Z"},"seven_day":{"utilization":27},"limits":[{"kind":"weekly_scoped","scope":{"model":{"display_name":"Fable"}},"percent":19}]}"#.utf8))
        }
        func session() -> URLSession {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [QuotaProtocol.self]
            return URLSession(configuration: config, delegate: ClaudeQuotaSessionDelegate(), delegateQueue: nil)
        }
        func read(_ authorize: Bool = false) async -> ClaudeDesktopUsageReply {
            await ClaudeDesktopReader.run(authorize: authorize, directory: root, readKey: { value in precondition(value == authorize); return key }, testSession: session())
        }
        let success = await read()
        precondition(success.status == .available && success.plan == "pro" && success.account == account && calls == 2)
        let usage = try ClaudeUsage.parse(success.limits!)
        precondition(usage.fiveHour?.remainingPct == 53 && usage.sevenDay?.remainingPct == 73 && usage.modelWeekly["fable"]?.remainingPct == 81)
        let encoded = try JSONEncoder().encode(success)
        precondition(!String(decoding: encoded, as: UTF8.self).contains("test-only-bearer"), "helper never emits credentials")
        wrongProfile = true; let mismatched = await read(); precondition(mismatched.status == .accountChanged && calls == 3)
        wrongProfile = false; responseCode = 401; let expired = await read(); precondition(expired.status == .expired)
        responseCode = 503; let failed = await read(); precondition(failed.status == .failed)
        responseCode = 302; let redirect = await read(); precondition(redirect.status == .failed)
        responseCode = 200; switchAccount = true; let switched = await read(); precondition(switched.status == .accountChanged)
        switchAccount = false; try save(valid)
        let manual = await read(true); precondition(manual.status == .available)
        print("ClaudeDesktopUsageChecks: encrypted cache, account/org isolation, revocation, expiry, silent access, quota API, identity changes and secret-free output passed")
    }
}
