import Foundation

/// Display-only metadata. Never retains prompts, responses, or authentication data.
public struct CodexDisplay: Equatable {
    public enum Status: String { case working = "运行中", completed = "本轮完成", interrupted = "已中断", unknown = "状态未知" }
    public struct Session: Equatable {
        public var number: Int
        public var status: Status
        public var startedAt: Date?
        public var updatedAt: Date
    }
    public struct Quota: Equatable {
        public var remaining: Int
        public var minutes: Int
        public var resetsAt: Date?
        public var label: String {
            if minutes == 10080 { return "周额度" }
            if minutes > 0 && minutes % 60 == 0 { return "\(minutes / 60)h额度" }
            return minutes > 0 ? "\(minutes)m额度" : "额度"
        }
    }
    public var sessions: [Session] = []
    public var quotas: [Quota] = []
    public var quotaUpdatedAt: Date?
    public var detail = "等待 Codex 本地会话"
    public init() {}
}

public struct CodexDisplayTracker {
    private struct Record {
        var session: CodexDisplay.Session
        var turn: String?
    }
    private var records: [String: Record] = [:]
    private var nextNumber = 1
    private var quotas: [CodexDisplay.Quota] = []
    private var quotaUpdatedAt: Date?
    private static let dates: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    public init() {}
    public mutating func remove(sessionID: String) { records.removeValue(forKey: sessionID) }

    public mutating func consume(line: Data, sessionID: String, now: Date = Date()) {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              root["type"] as? String == "event_msg", let payload = root["payload"] as? [String: Any],
              let type = payload["type"] as? String else { return }
        let stamp = root["timestamp"] as? String ?? ""
        let date = Self.dates.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp) ?? now
        if type == "token_count", date >= (quotaUpdatedAt ?? .distantPast),
           let limits = payload["rate_limits"] as? [String: Any],
           (limits["limit_id"] as? String ?? "codex") == "codex" {
            quotas = ["primary", "secondary"].compactMap { key in
                guard let window = limits[key] as? [String: Any],
                      let used = window["used_percent"] as? Double, used.isFinite else { return nil }
                let reset = (window["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
                return CodexDisplay.Quota(remaining: Int(max(0, min(100, 100 - used)).rounded(.down)),
                    minutes: window["window_minutes"] as? Int ?? 0, resetsAt: reset)
            }
            quotaUpdatedAt = date
        }
        let turn = payload["turn_id"] as? String
        let begins = ["task_started", "turn_started"].contains(type)
        let ends = ["task_complete", "turn_complete", "turn_aborted"].contains(type)
        let progress = type == "item_completed" && turn != nil
        if records[sessionID] == nil {
            guard begins || ends || progress else { return }
            records[sessionID] = Record(session: .init(number: nextNumber, status: .unknown,
                startedAt: nil, updatedAt: date), turn: turn)
            nextNumber += 1
        }
        guard var record = records[sessionID], date >= record.session.updatedAt else { return }
        if begins {
            // Duplicate starts should not restart the elapsed-time counter.
            if record.turn != turn || record.session.status != .working || record.session.startedAt == nil {
                record.session.startedAt = date
            }
            record.turn = turn; record.session.status = .working
        } else if ends {
            if let turn, let current = record.turn, turn != current { return }
            record.turn = turn ?? record.turn
            record.session.status = type == "turn_aborted" ? .interrupted : .completed
        } else if progress {
            if record.turn == turn && [.completed, .interrupted].contains(record.session.status) { return }
            if let current = record.turn, current != turn, record.session.status == .working { return }
            if record.turn != turn { record.session.startedAt = nil }
            record.turn = turn; record.session.status = .working
        } else {
            guard record.session.status == .working else { return }
            if let turn, let current = record.turn, turn != current { return }
        }
        record.session.updatedAt = date
        records[sessionID] = record
    }

    public mutating func snapshot(now: Date = Date()) -> CodexDisplay {
        records = records.filter { now.timeIntervalSince($0.value.session.updatedAt) < 86400 }
        var result = CodexDisplay()
        result.sessions = records.values.map { record in
            var session = record.session
            if session.status == .working && now.timeIntervalSince(session.updatedAt) >= 300 { session.status = .unknown }
            return session
        }.sorted {
            if ($0.status == .working) != ($1.status == .working) { return $0.status == .working }
            if $0.status == .working { return $0.number < $1.number }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.number < $1.number
        }
        result.quotas = quotas; result.quotaUpdatedAt = quotaUpdatedAt
        return result
    }
}
