import Foundation

/// A sign-in time is separate from token issuance and file modification, which change during automatic refresh.
enum CodexLoginTime {
    static func native(in directory: URL) -> Date? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("auth.json")),
              let record = try? JSONDecoder().decode(Native.self, from: data) else { return nil }
        return date(in: record.tokens?.idToken)
    }

    static func pi(in directory: URL) -> Date? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("auth.json")),
              let record = try? JSONDecoder().decode(Pi.self, from: data) else { return nil }
        return date(in: record.codex?.access)
    }

    private static func date(in token: String?) -> Date? {
        guard let parts = token?.split(separator: "."), parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload), let claims = try? JSONDecoder().decode(Claims.self, from: data),
              let time = claims.authTime else { return nil }
        return Date(timeIntervalSince1970: time)
    }

    private struct Claims: Decodable {
        let authTime: Double?
        enum CodingKeys: String, CodingKey { case authTime = "auth_time" }
    }
    private struct Native: Decodable {
        struct Tokens: Decodable {
            let idToken: String?
            enum CodingKeys: String, CodingKey { case idToken = "id_token" }
        }
        let tokens: Tokens?
    }
    private struct Pi: Decodable {
        struct Credential: Decodable { let access: String? }
        let codex: Credential?
        enum CodingKeys: String, CodingKey { case codex = "openai-codex" }
    }
}
