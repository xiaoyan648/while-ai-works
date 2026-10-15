import AgentHUDSupport
import Foundation

/// Incremental summary of Codex rollout JSONL, shared by Desktop and CLI.
/// It persists counters and lifecycle events; answer previews are kept only while the app runs.
public struct CodexTranscript: Codable, Sendable {
    public struct Usage: Codable, Sendable {
        public let timestamp: Date
        public let model: String
        public let input: Int
        public let output: Int
        public let cachedInput: Int
        /// The part of `input` written to the cache and the part of `output` spent reasoning.
        public var cacheWrite = 0
        public var reasoning = 0
        /// The model's context window as the rollout states it.
        public var contextWindow: Int? = nil

        public var event: UsageEvent {
            .init(timestamp: timestamp, agentId: "codex-model:\(model)", tokensIn: input, tokensOut: output, cacheReadTokens: cachedInput,
                  cacheWriteTokens: cacheWrite, reasoningTokens: reasoning)
        }
    }

    public private(set) var id: String?
    public private(set) var cwd: String?
    public private(set) var client = "Codex"
    /// The rollout's authoritative client distinguishes Desktop from a CLI that inherited its originator.
    public var navigationTarget: SessionNavigationTarget? {
        guard client == "Desktop", let id, !id.isEmpty else { return nil }
        return .codexThread(id: id)
    }
    public private(set) var isSubagent = false
    public private(set) var isInternal = false
    /// The thread that started this rollout's sub-agent: a spawned agent names it in its source, a guardian beside it.
    public private(set) var parentThreadID: String?
    public private(set) var agentName: String?
    private(set) var agentPath: String?
    public private(set) var startedAt: Date?
    public private(set) var lastActivityAt: Date?
    public private(set) var task: String?
    public private(set) var model = "Unknown"
    /// Usage read since the store last recorded it in the ledger; the totals below cover the whole rollout.
    public private(set) var usage: [Usage] = []
    public private(set) var inputTokens = 0
    public private(set) var outputTokens = 0
    public private(set) var cachedInputTokens = 0
    /// Models that reported usage in this rollout.
    public private(set) var models: Set<String> = []
    /// Usage entries already recorded, so each keeps its position as its ledger key.
    private var recordedUsage = 0
    private struct Turn: Codable, Sendable {
        let id: String?
        let startedAt: Date?
        var state: SessionTurn.State
        var observedAt: Date
        /// What the agent said, kept only while the app runs: the ledger stores no conversation text.
        var message: String?
        /// An explicitly final answer, kept apart from the agent's progress messages.
        var finalMessage: String?
        enum CodingKeys: String, CodingKey { case id, startedAt, state, observedAt }
    }
    /// How much of an agent message is kept; readers truncate it further.
    static let messageLength = 2048
    private var turns: [Turn]?
    public private(set) var completions: [SessionCompletion]?
    private var totalInput = 0
    private var totalCached = 0
    private var totalOutput = 0
    private var totalWrite = 0
    private var totalReasoning = 0
    private var hasTotals = false
    /// Newer forks restamp copied history and mark its last ordinal in their first metadata.
    private var inheritedThroughOrdinal: Int?
    /// Turn starts and compactions read since the store last took them.
    private var marks: [UsageLedger.Mark] = []

    public init() {}

    public mutating func ingest(_ line: Data) {
        // Rollouts can contain multi-MB tool outputs. Inspect the envelope before decoding.
        guard Self.envelopes.contains(where: { line.range(of: $0) != nil }) else { return }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String,
              let payload = object["payload"] as? [String: Any],
              let timestamp = (object["timestamp"] as? String).flatMap(ISO8601Fast.parse) else { return }
        if type == "session_meta" {
            // A fork starts with its own metadata, then can replay the parent's history and metadata.
            // The first valid identity owns this file and the inherited-history cutoff.
            guard id == nil, let sessionID = payload["id"] as? String, !sessionID.isEmpty else { return }
            id = sessionID
            inheritedThroughOrdinal = payload["subagent_history_start_ordinal"] as? Int
            cwd = payload["cwd"] as? String
            startedAt = (payload["timestamp"] as? String).flatMap(ISO8601Fast.parse) ?? timestamp
            let source = payload["source"] as? String
            let origin = payload["originator"] as? String
            isSubagent = (payload["source"] as? [String: Any])?["subagent"] != nil
            if let subagent = (payload["source"] as? [String: Any])?["subagent"] as? [String: Any] {
                let spawn = subagent["thread_spawn"] as? [String: Any]
                isInternal = subagent["other"] as? String == "guardian"
                parentThreadID = payload["parent_thread_id"] as? String
                    ?? spawn?["parent_thread_id"] as? String
                agentPath = (spawn?["agent_path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                agentName = [spawn?["agent_nickname"] as? String, payload["agent_nickname"] as? String,
                             agentPath.map { URL(fileURLWithPath: $0).lastPathComponent }].compactMap { $0 }.first { !$0.isEmpty }
            }
            // CLI launched from Desktop can inherit its originator; the rollout's source is authoritative. Otherwise the
            // originator names the client, and one the vendor catalog does not name is shown as written.
            if source == "cli" { client = "CLI" }
            else if source == "exec" { client = "CLI · exec" }
            else if let origin, !origin.isEmpty {
                if let named = VendorCatalog.client(origin, vendor: "Codex") { client = named }
                else { client = origin; VendorCatalog.noteUnnamed(origin, kind: "Codex client") }
            }
            else if source == "vscode" { client = "IDE" }
            return
        }
        if type == "turn_context" {
            if let value = payload["model"] as? String { model = value }
            return
        }
        // Forks copy earlier history. Read its cumulative baseline but do not count it again.
        let inherited = timestamp < (startedAt ?? .distantPast)
            || inheritedThroughOrdinal.map { boundary in (object["ordinal"] as? Int).map { $0 <= boundary } ?? false } == true
        if type == "compacted" {
            if !inherited { marks.append(.init(.compaction, at: timestamp)) }
            return
        }
        guard type == "event_msg", let kind = payload["type"] as? String else { return }
        if kind == "token_count" {
            guard let info = payload["info"] as? [String: Any],
                  let totals = info["total_token_usage"] as? [String: Any],
                  let input = totals["input_tokens"] as? Int,
                  let output = totals["output_tokens"] as? Int else { return }
            let cached = totals["cached_input_tokens"] as? Int ?? 0
            let written = totals["cache_write_input_tokens"] as? Int ?? 0
            let reasoned = totals["reasoning_output_tokens"] as? Int ?? 0
            let last = info["last_token_usage"] as? [String: Any]
            let reset = input < totalInput || output < totalOutput || cached < totalCached
            let inputDelta = hasTotals && !reset ? input - totalInput : (last?["input_tokens"] as? Int ?? input)
            let cachedDelta = hasTotals && !reset ? cached - totalCached : (last?["cached_input_tokens"] as? Int ?? cached)
            let outputDelta = hasTotals && !reset ? output - totalOutput : (last?["output_tokens"] as? Int ?? output)
            let writeDelta = hasTotals && !reset ? written - totalWrite : (last?["cache_write_input_tokens"] as? Int ?? written)
            let reasoningDelta = hasTotals && !reset ? reasoned - totalReasoning : (last?["reasoning_output_tokens"] as? Int ?? reasoned)
            totalInput = input; totalCached = cached; totalOutput = output; totalWrite = written; totalReasoning = reasoned; hasTotals = true
            guard !inherited, inputDelta > 0 || outputDelta > 0 else { return }
            // Cached input and cache writes are part of input_tokens; reasoning is part of output_tokens.
            var sample = Usage(timestamp: timestamp, model: model, input: max(0, inputDelta - cachedDelta), output: max(0, outputDelta),
                               cachedInput: max(0, cachedDelta))
            sample.cacheWrite = max(0, writeDelta)
            sample.reasoning = max(0, reasoningDelta)
            sample.contextWindow = info["model_context_window"] as? Int
            usage.append(sample)
            inputTokens += sample.input
            outputTokens += sample.output
            cachedInputTokens += sample.cachedInput
            models.insert(model)
            lastActivityAt = timestamp
        } else if !inherited {
            switch kind {
            case "task_started":
                lastActivityAt = max(lastActivityAt ?? timestamp, timestamp)
                marks.append(.init(.prompt, at: timestamp))
                let turnID = payload["turn_id"] as? String
                if !(turns ?? []).contains(where: { $0.id == turnID && (turnID != nil || ($0.state == .running && $0.startedAt == timestamp)) }),
                   timestamp >= (turns?.last?.startedAt ?? .distantPast) {
                    turns = Array(((turns ?? []) + [Turn(id: turnID, startedAt: timestamp, state: .running, observedAt: timestamp)]).suffix(32))
                }
            case "task_complete":
                lastActivityAt = max(lastActivityAt ?? timestamp, timestamp)
                let finished = finishTurn(payload["turn_id"] as? String, state: .completed, at: timestamp)
                if let id, !isSubagent, !isInternal {
                    let answer = (payload["last_agent_message"] as? String).flatMap {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
                    } ?? finished?.finalMessage
                    let completion = SessionCompletion(sessionID: id, vendor: "Codex",
                        turnID: payload["turn_id"] as? String ?? finished?.id ?? String(RecordCoding.milliseconds(timestamp)),
                        task: task ?? cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Codex",
                        model: model, startedAt: finished?.startedAt, completedAt: timestamp,
                        message: answer)
                    if completions?.contains(where: { $0.id == completion.id }) != true {
                        completions = (completions ?? []) + [completion]
                    }
                }
            case "turn_aborted":
                lastActivityAt = max(lastActivityAt ?? timestamp, timestamp)
                _ = finishTurn(payload["turn_id"] as? String, state: .ended, at: timestamp)
            case "user_message":
                if task == nil, let text = payload["message"] as? String {
                    task = SessionTitle.from(text)
                }
            case "agent_message":
                // The visible answer of the turn that is running, kept where the turn can carry it.
                if let text = payload["message"] as? String, let index = turns?.indices.last, turns?[index].state == .running {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { turns?[index].message = String(trimmed.prefix(Self.messageLength)) }
                }
                if payload["phase"] as? String == "final_answer" || payload["channel"] as? String == "final",
                   let text = payload["message"] as? String {
                    recordFinalMessage(text, turnID: payload["turn_id"] as? String, at: timestamp)
                }
            case "item_completed":
                // Current rollouts record a prompt only as a completed UserMessage item of text and image parts.
                guard let item = payload["item"] as? [String: Any], let content = item["content"] as? [[String: Any]] else { break }
                if task == nil, item["type"] as? String == "UserMessage" {
                    task = content.lazy.filter { $0["type"] as? String == "text" }.compactMap { ($0["text"] as? String).flatMap(SessionTitle.from) }.first
                } else if item["type"] as? String == "AgentMessage", item["phase"] as? String == "final_answer" {
                    let text = content.filter { $0["type"] as? String == "Text" }.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
                    recordFinalMessage(text, turnID: payload["turn_id"] as? String, at: timestamp)
                }
            default: break
            }
        }
        // A source event can refresh an explicitly started turn, but never start or resurrect one.
        if !inherited, let index = turns?.indices.last, turns?[index].state == .running,
           timestamp > turns![index].observedAt, kind != "task_complete", kind != "turn_aborted" {
            turns?[index].observedAt = timestamp
        }
    }

    /// Hands the usage read since the last call to the ledger, keyed by its position in the rollout.
    mutating func drainUsage() -> [UsageLedger.Event] {
        defer {
            recordedUsage += usage.count
            usage = []
        }
        return usage.enumerated().map { offset, sample in
            UsageLedger.Event(key: "u\(recordedUsage + offset)", timestamp: sample.timestamp, agentId: "codex-model:\(sample.model)",
                              tokensIn: sample.input, tokensOut: sample.output, cacheReadTokens: sample.cachedInput,
                              cacheWriteTokens: sample.cacheWrite, reasoningTokens: sample.reasoning, contextWindow: sample.contextWindow)
        }
    }

    /// Hands over the turn starts and compactions read since the last call.
    mutating func drainMarks() -> [UsageLedger.Mark] {
        defer { marks = [] }
        return marks
    }

    /// Whether this rollout has its session in flight at `now`, by the rollout rule of `SessionPhase.read(_:rule:at:)`.
    /// Quiet counts from the rollout's newest event, so `modifiedAt` is not read; nor are `freshness` and
    /// `abandonedAfter`, since the limits are `SessionPhase.Limits`.
    public func isLive(now: Date, modifiedAt: Date, freshness: TimeInterval = SessionPhase.Limits.quiet,
                       abandonedAfter: TimeInterval = UsageRefresh.abandonedTurnTimeout) -> Bool {
        SessionPhase.read(evidence, rule: .rollout, at: now).inFlight
    }

    /// What this rollout says about its session: its newest turn, one without an id included, and its newest event. A
    /// guardian's rollout, and one without any activity, recorded nothing that counts.
    var evidence: SessionPhase.SourceEvidence {
        SessionPhase.SourceEvidence(turn: turns?.last.map { turn in
            SessionTurn(provider: "codex", sessionID: id ?? "", turnID: turn.id ?? "", state: turn.state,
                        startedAtMs: turn.startedAt.map(RecordCoding.milliseconds),
                        observedAtMs: RecordCoding.milliseconds(turn.observedAt), message: turn.message)
        }, lastWriteAt: isInternal ? nil : lastEventAt)
    }

    /// The rollout's newest event: the latest of its counted activity and its newest turn's last event.
    var lastEventAt: Date? { lastActivityAt.map { max($0, turns?.last?.observedAt ?? $0) } }

    public var sessionTurns: [SessionTurn] {
        guard let id, !isInternal else { return [] }
        return (turns ?? []).compactMap { turn in
            guard let turnID = turn.id, !turnID.isEmpty else { return nil }
            return SessionTurn(provider: "codex", sessionID: id, turnID: turnID, state: turn.state,
                startedAtMs: turn.startedAt.map(RecordCoding.milliseconds), observedAtMs: RecordCoding.milliseconds(turn.observedAt),
                message: turn.message)
        }
    }

    private mutating func recordFinalMessage(_ text: String, turnID: String?, at date: Date) {
        let index = turnID.flatMap { id in turns?.lastIndex(where: { $0.id == id }) } ?? (turnID == nil ? turns?.indices.last : nil)
        guard let index, turns?[index].state == .running,
              date >= (turns?[index].startedAt ?? .distantPast) else { return }
        if let paragraph = SessionCompletion.lastParagraph(text) { turns?[index].finalMessage = paragraph }
    }

    private mutating func finishTurn(_ id: String?, state: SessionTurn.State, at date: Date) -> Turn? {
        if let index = turns?.lastIndex(where: { $0.id == id }) {
            guard date >= turns![index].observedAt else { return nil }
            // A terminal observation is final. Repeated lines do not change its timestamp or outcome.
            guard turns![index].state == .running else { return turns![index] }
            turns?[index].state = state; turns?[index].observedAt = date
            return turns![index]
        }
        // A terminal-only log still identifies its turn, but cannot provide a start time.
        guard turns?.last?.state != .running else { return nil }
        let value = Turn(id: id, startedAt: nil, state: state, observedAt: date)
        turns = Array(((turns ?? []) + [value]).suffix(32))
        return value
    }

    private static let envelopes = ["\"session_meta\"", "\"turn_context\"", "\"event_msg\"", "\"type\":\"compacted\""].map { Data($0.utf8) }
}

/// Cooperative tail reader over the usage ledger. A partially written final line is retried on the next poll.
/// Each rollout is one ledger contribution; when a session's rollout exists in several places, only its newest copy counts.
public actor CodexTranscriptStore {
    public struct Session: Sendable {
        public let transcript: CodexTranscript
        public let modifiedAt: Date
        public let path: String
        public let title: String?
    }

    public struct Result: Sendable {
        public let sessions: [Session]
        public let indexing: IndexProgress?
    }

    let roots: [URL]
    private let indexURL: URL?
    private let ledger: UsageLedger
    private let logs: TailLogStore<CodexRollouts>
    private var titles: (signature: String, values: [String: String]) = ("", [:])

    /// - watchesChanges: after the first listing, polls look only at rollouts a directory watch reports changed.
    public init(roots: [URL], indexURL: URL? = nil, ledger: UsageLedger = .inMemory(), watchesChanges: Bool = false) {
        self.roots = roots
        self.indexURL = indexURL
        self.ledger = ledger
        logs = TailLogStore(roots: roots, ledger: ledger, watchesChanges: watchesChanges) { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("rollout-") }
    }

    public static func standard(directory: URL = CodexLocator.dataDirectory, ledger: UsageLedger = .inMemory()) -> CodexTranscriptStore {
        CodexTranscriptStore(roots: [directory.appendingPathComponent("sessions"), directory.appendingPathComponent("archived_sessions")],
                             indexURL: directory.appendingPathComponent("session_index.jsonl"), ledger: ledger, watchesChanges: true)
    }

    public func fileChanges(_ paths: Set<String>?) { logs.noteChanges(paths) }

    /// Codex's 15-minute token totals from the period holding `since`.
    public func usage(since: Date) async -> [UsageBucket] {
        (try? await ledger.buckets(since: since, source: CodexRollouts.source)) ?? []
    }

    public func index(since cutoff: Date, timeBudget: TimeInterval = 1.5) async -> Result {
        let pass = await logs.index(since: cutoff, timeBudget: timeBudget)
        let titles = readTitles()
        // A rollout can move into archived_sessions. One session id contributes usage exactly once.
        var sessions: [String: Session] = [:]
        for log in pass.logs.sorted(by: { $0.file.modified > $1.file.modified }) {
            guard let entry = logs.entry(log.path), let id = entry.summary.id, sessions[id] == nil else { continue }
            sessions[id] = Session(transcript: entry.summary, modifiedAt: log.file.modified, path: log.path, title: titles[id])
        }
        return Result(sessions: Array(sessions.values),
                      indexing: pass.pending > 0 ? IndexProgress(done: pass.logs.count - pass.pending, total: pass.logs.count) : nil)
    }

    /// Thread names, read again only when the index file changed.
    private func readTitles() -> [String: String] {
        guard var indexURL else { return [:] }
        indexURL.removeAllCachedResourceValues()
        guard let values = try? indexURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return [:] }
        let signature = "\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values.fileSize ?? 0)"
        guard signature != titles.signature else { return titles.values }
        var result: [String: String] = [:]
        if let text = try? String(contentsOf: indexURL, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                if let item = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                   let id = item["id"] as? String, let title = item["thread_name"] as? String { result[id] = title }
            }
        }
        titles = (signature, result)
        return result
    }
}

/// Codex rollouts; an archived copy of a rollout counts once.
enum CodexRollouts: TailLog {
    static let source = "codex"
    static let summaryKey = "transcript"
    /// 5: keep the first valid metadata, so copied parent history cannot replace a spawned agent's identity.
    static let version = 5

    static func summary(for url: URL) -> CodexTranscript { CodexTranscript() }

    static func ingest(_ lines: Data, into transcript: inout CodexTranscript) -> [UsageLedger.Event] {
        for line in lines.split(separator: 0x0A) { transcript.ingest(line) }
        return transcript.drainUsage()
    }

    static func drainMarks(_ transcript: inout CodexTranscript) -> [UsageLedger.Mark] { transcript.drainMarks() }

    static func group(_ transcript: CodexTranscript) -> String? { transcript.id ?? "" }
}
