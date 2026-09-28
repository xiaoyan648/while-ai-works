import Foundation

/// A fixed vocabulary; never retains prompts, tool arguments or response text.
public enum WorkPhase: String, Codable {
    case running, thinking, tool, replying
    public var title: String {
        switch self {
        case .running: return "正在处理请求"
        case .thinking: return "正在思考"
        case .tool: return "正在调用工具"
        case .replying: return "正在整理回复"
        }
    }
}

/// Only lifecycle metadata is retained. Prompt and response text is never stored.
public struct WorkActivity {
    public struct Session: Equatable {
        public var turnID: String?
        public var updatedAt: Date
        public var phase: WorkPhase = .running
    }

    public private(set) var active: [String: Session] = [:]
    private var completedTurns: [String: String] = [:]
    public init() {}
    public var isWorking: Bool { !active.isEmpty }

    public mutating func consume(line: Data, sessionID: String, now: Date = Date()) {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = root["payload"] as? [String: Any],
              let type = payload["type"] as? String else { return }
        let timestamp = Self.date(root["timestamp"] as? String) ?? now
        let turnID = payload["turn_id"] as? String
        let recordType = root["type"] as? String
        if recordType == "response_item" {
            guard var current = active[sessionID], timestamp >= current.updatedAt else { return }
            switch type {
            case "function_call", "custom_tool_call": current.phase = .tool
            case "reasoning": current.phase = .thinking
            case "message":
                guard payload["role"] as? String == "assistant" else { return }
                current.phase = .replying
            default: return
            }
            active[sessionID] = current
            return
        }
        guard recordType == "event_msg" else { return }
        switch type {
        case "task_started", "turn_started":
            active[sessionID] = Session(turnID: turnID, updatedAt: timestamp)
        case "item_completed":
            // Current Codex emits stable turn IDs on tool/reasoning progress. This
            // recovers a running turn when the bounded log tail omits its start.
            guard let turnID, completedTurns[sessionID] != turnID else { return }
            if let current = active[sessionID], let existing = current.turnID, existing != turnID { return }
            active[sessionID] = Session(turnID: turnID, updatedAt: max(active[sessionID]?.updatedAt ?? timestamp, timestamp), phase: active[sessionID]?.phase ?? .running)
        case "task_complete", "turn_complete", "turn_aborted":
            // A delayed completion for an older turn must not clear a newer turn.
            if let current = active[sessionID],
               let incoming = turnID, let existing = current.turnID, incoming != existing { return }
            if let turnID { completedTurns[sessionID] = turnID }
            active.removeValue(forKey: sessionID)
        default:
            if var current = active[sessionID] {
                if timestamp >= current.updatedAt {
                    if type == "agent_reasoning" { current.phase = .thinking }
                    if type == "agent_message" { current.phase = .replying }
                }
                current.updatedAt = max(current.updatedAt, timestamp)
                active[sessionID] = current
            }
        }
    }

    public mutating func expire(before cutoff: Date) {
        active = active.filter { $0.value.updatedAt >= cutoff }
    }

    public mutating func remove(sessionID: String) {
        active.removeValue(forKey: sessionID)
        completedTurns.removeValue(forKey: sessionID)
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

/// Keeps partial UTF-8/JSON lines across reads and bounds memory for malformed logs.
public struct LineBuffer {
    private var pending = Data()
    private var discarding = false
    public init() {}
    public mutating func append(_ bytes: Data) -> [Data] {
        pending.append(bytes)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 10) {
            let line = Data(pending[..<newline])
            if !discarding && line.count <= 1_048_576 { lines.append(line) }
            pending.removeSubrange(...newline)
            discarding = false
        }
        if pending.count > 1_048_576 {
            pending.removeAll(keepingCapacity: false)
            discarding = true
        }
        return lines
    }
}
