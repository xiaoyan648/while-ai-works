import Foundation
import AgentHUDCore

/// Recent local session totals, not a time-bucketed account bill. Both official
/// providers normalize input to exclude cache reads before reaching this model.
struct AgentLocalUsage {
    let sessionCount: Int
    let input: Int
    let output: Int
    let cached: Int
    var total: Int { input + output + cached }
    /// No cache evidence means unknown, rather than an invented 0% hit rate.
    var cacheHitRate: Double? {
        cached > 0 ? Double(cached) / (Double(input) + Double(cached)) : nil
    }
    init(sessions: [AgentDockSession]) {
        let unique = Dictionary(sessions.map { ($0.dockIdentity, $0) }, uniquingKeysWith: {
            $0.observedAt >= $1.observedAt ? $0 : $1
        }).values
        sessionCount = unique.count
        input = unique.reduce(0) { $0 + max(0, $1.tokensIn) }
        output = unique.reduce(0) { $0 + max(0, $1.tokensOut) }
        cached = unique.reduce(0) { $0 + max(0, $1.cacheRead) }
    }
}

/// Ephemeral requests and drafts never enter preferences, conversation history or logs.
struct AgentInteraction: Identifiable, Equatable {
    enum Phase: Equatable { case ready, sending, confirming, uncertain, failed }
    let request: PermissionRequest
    var viaHook = false
    var phase: Phase = .ready
    var fresh = true
    var notice: String?
    var id: String { request.id }
    var source: WorkSource {
        if request.vendor == "Hermes" { return .hermes }
        if request.source == .deepseek { return .dsh }
        return request.source == .claude ? .claude : .codex
    }
    var canAnswer: Bool { fresh && !request.isPlan && (viaHook || request.nativeApproval != nil) && (phase == .ready || phase == .failed) }
    var status: String {
        if let notice { return notice }
        if !fresh { return "连接暂不可用，请在原客户端处理" }
        switch phase {
        case .ready: return request.isQuestion ? "等你回答" : request.isPlan ? "计划待审" : "等你授权"
        case .sending: return "发送中…"
        case .confirming: return "已发送，等待原会话确认"
        case .uncertain: return "发送结果待确认，请查看原会话，勿重复发送"
        case .failed: return "发送失败，请在原客户端继续"
        }
    }
}

struct AgentInteractionDraft: Equatable {
    var page = 0
    var picks: [String: Set<Int>] = [:]
    var custom: [String: String] = [:]
    var reviewedDetail: String?
    mutating func pick(_ index: Int, for question: PermissionQuestion) {
        guard question.options.indices.contains(index) else { return }
        if question.multiSelect { picks[question.answerKey, default: []].formSymmetricDifference([index]) }
        else { picks[question.answerKey] = [index]; custom[question.answerKey] = "" }
    }
    mutating func type(_ text: String, for question: PermissionQuestion) {
        custom[question.answerKey] = text
        if !question.multiSelect { picks[question.answerKey] = [] }
    }
    func answers(for questions: [PermissionQuestion]) -> [String: PermissionQuestion.Answer] {
        var result: [String: PermissionQuestion.Answer] = [:]
        for question in questions {
            let chosen = question.options.indices.filter { picks[question.answerKey]?.contains($0) == true }.map { question.options[$0].label }
            let text = (custom[question.answerKey] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !chosen.isEmpty || !text.isEmpty { result[question.answerKey] = .init(selected: chosen, custom: text.isEmpty ? nil : text) }
        }
        return result
    }
}

extension AppState {
    var activeInteractionEditID: String? {
        guard let id = agentInteractionInputID ?? agentInteractionSelectionID,
              let request = agentInteractions.first(where: { $0.id == id }), request.canAnswer else { return nil }
        let draft = agentInteractionDrafts[id]
        if agentInteractionInputID == id || draft?.picks.values.contains(where: { !$0.isEmpty }) == true ||
            draft?.custom.values.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) == true { return id }
        return nil
    }
    /// The rail represents one named window, never the lowest percentage from an unrelated window.
    func dockQuota(for source: WorkSource) -> AgentDockQuota? {
        let window: AgentQuotaWindow = source == .claude ? .session : .weekly
        return agentDashboard.quotas.filter { $0.source == source && $0.window == window }
            .sorted { lhs, rhs in
                if lhs.stale != rhs.stale { return !lhs.stale }
                if (lhs.remaining != nil) != (rhs.remaining != nil) { return lhs.remaining != nil }
                if lhs.observedAt != rhs.observedAt { return lhs.observedAt > rhs.observedAt }
                return lhs.id < rhs.id
            }.first
    }
    func sessionRows(for sources: [WorkSource]) -> [AgentDockSessionRow] {
        let sessions = Dictionary(agentDashboard.sessions.filter { sources.contains($0.source) }.map { ($0.dockIdentity, $0) },
            uniquingKeysWith: { $0.observedAt >= $1.observedAt ? $0 : $1 })
        var rows = sessions.values.map { session in
            AgentDockSessionRow(session: session, requests: agentInteractions.filter {
                $0.source == session.source && $0.request.sessionID == session.id
            }.sorted { $0.request.at > $1.request.at })
        }
        let known = Set(rows.map(\.id))
        let orphans = Dictionary(grouping: agentInteractions.filter {
            sources.contains($0.source) && !known.contains($0.source.rawValue + ":" + $0.request.sessionID)
        }, by: { $0.source.rawValue + ":" + $0.request.sessionID })
        for (_, requests) in orphans {
            let ordered = requests.sorted { $0.request.at > $1.request.at }
            let item = ordered[0], request = item.request
            rows.append(.init(session: .init(id: request.sessionID, source: item.source,
                title: request.project ?? item.source.clientName, project: nil, status: item.status, running: false,
                tokensIn: 0, tokensOut: 0, cacheRead: 0, reply: nil, observedAt: request.at,
                navigationURL: nil, resumeCommand: nil), requests: ordered))
        }
        let now = Date()
        let editingID = activeInteractionEditID
        return rows.sorted {
            let lhsEditing = $0.requests.contains { $0.id == editingID }, rhsEditing = $1.requests.contains { $0.id == editingID }
            if lhsEditing != rhsEditing { return lhsEditing }
            if $0.priority(at: now) != $1.priority(at: now) { return $0.priority(at: now) < $1.priority(at: now) }
            if $0.eventAt != $1.eventAt { return $0.eventAt > $1.eventAt }
            return $0.id < $1.id
        }
    }
    func interactions(for source: WorkSource) -> [AgentInteraction] { agentInteractions.filter { $0.source == source } }
    func openInteractionSession(_ request: PermissionRequest) {
        if let session = agentDashboard.sessions.first(where: { $0.id == request.sessionID }) { openAgentSession(session); return }
        if request.source == .deepseek {
            Task { @MainActor in
                let snapshot = await LocalAgentReader().read(sources: [.dsh], previews: false)
                if let session = snapshot.sessions.first(where: { $0.id == request.sessionID }) { openAgentSession(session) }
            }
            return
        }
        guard UUID(uuidString: request.sessionID) != nil else { return }
        let source: WorkSource = request.source == .claude ? .claude : .codex
        let url = source == .codex ? URL(string: "codex://threads/" + request.sessionID) : nil
        openAgentSession(.init(id: request.sessionID, source: source, title: request.project ?? source.clientName,
            project: request.project, status: "等待处理", running: true, tokensIn: 0, tokensOut: 0, cacheRead: 0,
            reply: nil, observedAt: request.at, navigationURL: url,
            resumeCommand: (source == .claude ? "claude --resume " : "codex resume ") + request.sessionID))
    }
}

struct AgentDockSessionRow: Identifiable, Equatable {
    let session: AgentDockSession
    let requests: [AgentInteraction]
    var id: String { session.dockIdentity }
    var event: AgentSessionEvent {
        if let request = requests.first { return request.request.isQuestion ? .input : .approval }
        return session.event
    }
    var eventAt: Date { requests.first?.request.at ?? session.eventAt ?? session.observedAt }
    func priority(at now: Date) -> Int {
        if !requests.isEmpty { return 0 }
        switch event {
        case .input, .approval: return 0
        case .finished: return now.timeIntervalSince(eventAt) <= 86400 ? 1 : 3
        case .working: return 2
        case .recent: return 3
        }
    }
}

/// Presentation hierarchy for a main Agent and its nested sandbox Agents.
/// A missing parent leaves the row at the top level so requests remain visible.
struct AgentDockSessionTree: Identifiable {
    let row: AgentDockSessionRow
    let children: [AgentDockSessionTree]
    var id: String { row.id }
    var descendants: [AgentDockSessionRow] { children.flatMap { [$0.row] + $0.descendants } }
    var pendingCount: Int {
        descendants.filter { $0.event == .input || $0.event == .approval }.count
    }
    func priority(at now: Date) -> Int {
        pendingCount > 0 ? 0 : row.priority(at: now)
    }

    struct Entry: Identifiable {
        let node: AgentDockSessionTree
        let depth: Int
        var id: String { node.id }
    }

    func visibleEntries(expanded: Set<String>, depth: Int = 0) -> [Entry] {
        [Entry(node: self, depth: depth)] + (expanded.contains(id)
            ? children.flatMap { $0.visibleEntries(expanded: expanded, depth: depth + 1) }
            : [])
    }

    static func roots(_ rows: [AgentDockSessionRow]) -> [Self] {
        let known = Set(rows.map(\.id))
        func parent(_ row: AgentDockSessionRow) -> String? {
            row.session.parentSessionID.map { row.session.source.rawValue + ":" + $0 }
        }
        let grouped = Dictionary(grouping: rows.filter { parent($0).map(known.contains) == true }, by: { parent($0)! })
        func tree(_ row: AgentDockSessionRow, ancestors: Set<String>) -> Self {
            let seen = ancestors.union([row.id])
            return Self(row: row, children: (grouped[row.id] ?? []).filter { !seen.contains($0.id) }
                .map { tree($0, ancestors: seen) })
        }
        let now = Date()
        let order = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
        func rank(_ node: Self) -> Int {
            ([node.row] + node.descendants).map { order[$0.id] ?? .max }.min() ?? .max
        }
        return rows.filter { parent($0).map(known.contains) != true }.map { tree($0, ancestors: []) }
            .sorted {
                if $0.priority(at: now) != $1.priority(at: now) {
                    return $0.priority(at: now) < $1.priority(at: now)
                }
                return rank($0) < rank($1)
            }
    }
}

enum AgentInteractionValidation {
    static func allows(_ decision: PermissionDecision, for request: PermissionRequest) -> Bool {
        guard !request.isPlan else { return false }
        if request.isQuestion {
            guard case .answer(let answers) = decision, answers.count == request.questions.count else { return false }
            return request.questions.allSatisfy { question in
                guard let answer = answers[question.answerKey], !answer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      answer.text.utf8.count <= 16_384, answer.selected.count <= (question.multiSelect ? question.options.count : 1),
                      answer.selected.allSatisfy({ label in question.options.contains { $0.label == label } }) else { return false }
                return true
            }
        }
        switch decision { case .allow, .deny: return true; default: return false }
    }
}
