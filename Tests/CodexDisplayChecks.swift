import Foundation
import WhileCore

@main enum CodexDisplayChecks {
    static func main() throws {
        var tracker = CodexDisplayTracker()
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        func event(_ type: String, _ turn: String? = "a", seconds: Double = 0, limits: [String: Any]? = nil) throws -> Data {
            let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var payload: [String: Any] = ["type": type]
            if let turn { payload["turn_id"] = turn }
            if let limits { payload["rate_limits"] = limits }
            return try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": format.string(from: base.addingTimeInterval(seconds)), "payload": payload])
        }
        tracker.consume(line: try event("task_started"), sessionID: "one", now: base)
        tracker.consume(line: try event("task_started", seconds: 1), sessionID: "one", now: base)
        var result = tracker.snapshot(now: base.addingTimeInterval(2))
        precondition(result.sessions.count == 1 && result.sessions[0].startedAt == base)
        let number = result.sessions[0].number
        tracker.consume(line: try event("task_started", "b", seconds: 3), sessionID: "one")
        tracker.consume(line: try event("task_complete", "a", seconds: 4), sessionID: "one")
        precondition(tracker.snapshot(now: base.addingTimeInterval(5)).sessions[0].status == .working, "old completion must not finish resumed turn")
        tracker.consume(line: try event("turn_aborted", "b", seconds: 6), sessionID: "one")
        tracker.consume(line: try event("item_completed", "b", seconds: 7), sessionID: "one")
        result = tracker.snapshot(now: base.addingTimeInterval(8))
        precondition(result.sessions[0].status == .interrupted && result.sessions[0].number == number)
        tracker.consume(line: try event("task_started", "c", seconds: 9), sessionID: "one")
        precondition(tracker.snapshot(now: base.addingTimeInterval(310)).sessions[0].status == .unknown, "silence is not success")
        tracker.consume(line: try event("item_completed", "c", seconds: 311), sessionID: "one")
        precondition(tracker.snapshot(now: base.addingTimeInterval(312)).sessions[0].status == .working)
        tracker.consume(line: try event("task_complete", "c", seconds: 313), sessionID: "one")
        precondition(tracker.snapshot(now: base.addingTimeInterval(314)).sessions[0].status == .completed)
        tracker.consume(line: try event("item_completed", "tail", seconds: 315), sessionID: "two")
        result = tracker.snapshot(now: base.addingTimeInterval(316))
        precondition(result.sessions[0].status == .working && result.sessions[0].startedAt == nil, "tail recovery cannot invent start time")
        let limits: [String: Any] = ["limit_id": "codex", "primary": ["used_percent": 90.0, "window_minutes": 10080, "resets_at": base.timeIntervalSince1970 + 86400], "secondary": NSNull()]
        tracker.consume(line: try event("token_count", nil, seconds: 317, limits: limits), sessionID: "two")
        var other = limits; other["limit_id"] = "other-model"
        tracker.consume(line: try event("token_count", nil, seconds: 318, limits: other), sessionID: "two")
        var older = limits; older["primary"] = ["used_percent": 20.0, "window_minutes": 300]
        tracker.consume(line: try event("token_count", nil, seconds: 316, limits: older), sessionID: "one")
        result = tracker.snapshot(now: base.addingTimeInterval(319))
        precondition(result.quotas.count == 1 && result.quotas[0].remaining == 10 && result.quotas[0].label == "周额度")
        precondition(result.quotaUpdatedAt == base.addingTimeInterval(317), "other buckets and older files cannot overwrite latest quota")
        let missing: [String: Any] = ["limit_id": "codex", "primary": NSNull(), "secondary": NSNull()]
        tracker.consume(line: try event("token_count", nil, seconds: 320, limits: missing), sessionID: "two")
        precondition(tracker.snapshot(now: base.addingTimeInterval(321)).quotas.isEmpty, "missing quota is not zero remaining")
        print("CodexDisplayChecks passed: resumed turns, late completion, abort, stale/recovered sessions, unknown start, stable numbering, quota freshness/buckets/nulls")
    }
}
