import Foundation
import AgentHUDCore
import AgentHUDSupport
import WhileCore

@main
struct AgentDockDataChecks {
    @MainActor static func main() throws {
        L10n.setLanguage(.zhHans)
        let now = Date(), id = "00000000-0000-0000-0000-000000000001"
        let agent = AgentDescriptor(id: "codex", vendor: "Codex", model: "5 小时", source: "fixture", enabled: true)
        let session = LiveSession(id: id, agentId: "codex", task: "修改导航", terminal: "cat-hud", startedAt: now,
            pctOfWindow: nil, tokensIn: 1200, tokensOut: 300, cacheReadTokens: 1000, observedAt: now,
            navigationTarget: .codexThread(id: id))
        let turn = SessionTurn(provider: "Codex", sessionID: id, turnID: "turn-1", state: .completed,
            startedAtMs: nil, observedAtMs: Int64(now.timeIntervalSince1970 * 1000), message: "修改完成")
        let snapshot = UsageSnapshot(agentId: "codex", remainingPct: 25, weeklyRemainingPct: 10,
            resetAt: now.addingTimeInterval(-5), updatedAt: now.addingTimeInterval(-1200))
        let report = UsageReport(generatedAt: now, snapshots: [snapshot], sessions: [session], discoveredAgents: [agent], turns: [turn])
        let hidden = AgentHubDataController.adapt(report, showReplies: false, now: now)
        precondition(hidden.sessions[0].reply == nil)
        let shown = AgentHubDataController.adapt(report, showReplies: true, now: now)
        precondition(shown.sessions[0].reply == "修改完成" && !shown.sessions[0].running)
        precondition(hidden.sessions[0].event == .finished, "explicit completion metadata survives reply privacy")
        let noBody = SessionTurn(provider: "Codex", sessionID: id, turnID: "turn-1", state: .completed,
            startedAtMs: nil, observedAtMs: turn.observedAtMs)
        let completion = SessionCompletion(sessionID: id, vendor: "Codex", turnID: "turn-1", task: "fixture",
            model: "fixture", startedAt: now, completedAt: now, message: "最终回复")
        let completionReport = UsageReport(generatedAt: now, snapshots: [], sessions: [session],
            discoveredAgents: [agent], completions: [completion], turns: [noBody])
        precondition(AgentHubDataController.adapt(completionReport, showReplies: true, now: now).sessions[0].reply == "最终回复")
        precondition(shown.sessions[0].tokensIn == 1200 && shown.sessions[0].cacheRead == 1000)
        let localUsage = AgentLocalUsage(sessions: shown.sessions + shown.sessions)
        precondition(localUsage.sessionCount == 1 && localUsage.input == 1200 && localUsage.cached == 1000,
                     "repeat snapshots cannot double count local usage")
        precondition(abs(localUsage.cacheHitRate! - 1000.0 / 2200.0) < 0.00001,
                     "cache hits divide by all prompt tokens, never by output or fresh input alone")
        let noUsage = AgentLocalUsage(sessions: [])
        precondition(noUsage.sessionCount == 0 && noUsage.total == 0 && noUsage.cacheHitRate == nil)
        func usageFixture(_ id: String, input: Int, output: Int, cache: Int, at: Date) -> AgentDockSession {
            .init(id: id, source: .codex, title: "fixture", project: nil, status: "已回复", running: false,
                  tokensIn: input, tokensOut: output, cacheRead: cache, reply: nil, observedAt: at, navigationURL: nil, resumeCommand: nil)
        }
        let latestUsage = AgentLocalUsage(sessions: [
            usageFixture("same", input: 800, output: 80, cache: 0, at: now.addingTimeInterval(-60)),
            usageFixture("same", input: 1000, output: 100, cache: 9000, at: now),
            usageFixture("negative", input: -1, output: -2, cache: -3, at: now)])
        precondition(latestUsage.sessionCount == 2 && latestUsage.total == 10100 && latestUsage.cacheHitRate == 0.9,
                     "latest session counters win and malformed negative counters contribute nothing")
        precondition(AgentLocalUsage(sessions: [usageFixture("new", input: 400, output: 20, cache: 0, at: now)]).cacheHitRate == nil,
                     "no cache evidence is unknown, not a fabricated zero-percent hit rate")
        precondition(AgentLocalUsage(sessions: [usageFixture("all-cached", input: 0, output: 40, cache: 1000, at: now)]).cacheHitRate == 1)
        precondition(shown.quotas.count == 2 && shown.quotas[0].remaining == 25 && shown.quotas.allSatisfy(\.stale))
        precondition(shown.quotas[0].resetAt == snapshot.resetAt, "past deadlines never manufacture a reset")
        let weeklyAgent = AgentDescriptor(id: "codex", vendor: "Codex", model: "Weekly", source: "fixture", enabled: true)
        let weeklyReport = UsageReport(generatedAt: now, snapshots: [snapshot], sessions: [], discoveredAgents: [weeklyAgent])
        precondition(AgentHubDataController.adapt(weeklyReport, showReplies: false, now: now).quotas.count == 1,
                     "a source that only reports its weekly window does not show that same window twice")
        let claudeRows = ClaudeUsage(fiveHour: .init(utilizationPct: 25, resetsAt: now.addingTimeInterval(300)),
            sevenDay: .init(utilizationPct: 23, resetsAt: now.addingTimeInterval(3600)),
            modelWeekly: ["sonnet": .init(utilizationPct: 6, resetsAt: now.addingTimeInterval(3600))]).rows
        let claudeReport = UsageReport(generatedAt: now,
            snapshots: claudeRows.map { UsageSnapshot(agentId: $0.id, remainingPct: $0.window.remainingPct,
                resetAt: $0.window.resetsAt, updatedAt: now) }, sessions: [], discoveredAgents: claudeRows.map(\.descriptor))
        let claudeQuotas = AgentHubDataController.adapt(claudeReport, showReplies: false, now: now).quotas
        precondition(claudeQuotas.map(\.title) == ["当前会话", "每周限制 · 所有模型", "每周限制 · Sonnet"],
                     "persisted engine window keys must become readable card labels")
        precondition(claudeQuotas.map(\.remaining) == [75, 77, 94] && claudeQuotas.allSatisfy { !$0.stale })
        precondition(claudeQuotas.map(\.window) == [.session, .weekly, .modelWeekly])
        let dockSuite = "WhileAIWorks.DockEventChecks." + UUID().uuidString
        let dockDefaults = UserDefaults(suiteName: dockSuite)!
        defer { dockDefaults.removePersistentDomain(forName: dockSuite) }
        let dockState = AppState(defaults: dockDefaults)
        precondition(dockState.desktopDockTab == .sessions)
        dockState.agentDashboard = shown
        precondition(dockState.dockQuota(for: .codex)?.remaining == 10, "Codex rail selects the weekly window")
        dockState.agentDashboard.quotas = claudeQuotas + [.init(id: "lower-weekly", source: .claude, title: "每周",
            remaining: 1, resetAt: nil, observedAt: now, stale: false, window: .weekly)]
        precondition(dockState.dockQuota(for: .claude)?.remaining == 75, "Claude rail must ignore a lower weekly quota")
        dockState.agentDashboard.quotas.removeAll { $0.window == .session }
        precondition(dockState.dockQuota(for: .claude) == nil, "a missing session limit must not be replaced with a weekly limit")
        let currentAccount = ProviderAccount(provider: "Claude", user: "fixture-current", workspace: "", evidence: .account)
        let previousAccount = ProviderAccount(provider: "Claude", user: "fixture-previous", workspace: "", evidence: .account)
        let currentDescriptor = AgentDescriptor(id: currentAccount.windowID(ClaudeUsage.sessionRowId), vendor: "Claude",
            model: "__window_session__", source: "fixture", enabled: true, account: currentAccount)
        let oldDescriptor = AgentDescriptor(id: previousAccount.windowID(ClaudeUsage.sessionRowId), vendor: "Claude",
            model: "__window_session__", source: "fixture", enabled: true, account: previousAccount)
        let accountReport = UsageReport(generatedAt: now,
            snapshots: [.init(agentId: currentDescriptor.id, remainingPct: 70, updatedAt: now),
                        .init(agentId: oldDescriptor.id, remainingPct: 1, updatedAt: now.addingTimeInterval(1))],
            sessions: [], discoveredAgents: [currentDescriptor, oldDescriptor],
            accounts: ["Claude": [.init(account: currentAccount, observedAt: now), .init(account: previousAccount, observedAt: now, isCurrent: false)]])
        dockState.agentDashboard = AgentHubDataController.adapt(accountReport, showReplies: false, now: now)
        precondition(dockState.agentDashboard.quotas.count == 1 && dockState.dockQuota(for: .claude)?.remaining == 70,
                     "account-scoped session windows select the current login rather than a newer former account")
        func rowSession(_ key: String, _ event: AgentSessionEvent, _ at: Date) -> AgentDockSession {
            .init(id: key, source: .codex, title: key, project: nil, status: "fixture", running: event == .working,
                  tokensIn: 0, tokensOut: 0, cacheRead: 0, reply: nil, observedAt: at, navigationURL: nil,
                  resumeCommand: nil, event: event, eventAt: at)
        }
        let question = PermissionQuestion(id: "q", question: "选择方向", options: [.init(label: "继续")])
        let ask = PermissionRequest(id: "ask", source: .codex, sessionID: "needs-answer", toolName: "request_user_input_async",
            summary: "选择方向", detail: nil, cwd: "/fixture", questions: [question],
            nativeApproval: .asynchronousQuestion(turnID: "fixture-turn"), at: now)
        let approval = PermissionRequest(id: "approval", source: .codex, sessionID: "needs-review", toolName: "Bash",
            summary: "运行检查", detail: "npm test", cwd: "/fixture", at: now.addingTimeInterval(-2))
        dockState.agentDashboard.sessions = [rowSession("running", .working, now), rowSession("done", .finished, now.addingTimeInterval(-3)),
            rowSession("old-done", .finished, now.addingTimeInterval(-172800)), rowSession("needs-review", .working, now)]
        dockState.agentInteractions = [.init(request: approval, viaHook: true), .init(request: ask)]
        let rows = dockState.sessionRows(for: [.codex])
        precondition(rows.map { $0.session.id } == ["needs-answer", "needs-review", "done", "running", "old-done"],
                     "questions and approvals merge into sessions ahead of recent completions, work and older history")
        precondition(rows[0].event == .input && rows[1].event == .approval && rows[1].requests.count == 1,
                     "requests without indexed sessions are retained and matched requests never duplicate their session")
        dockState.agentInteractions = []
        dockState.agentDashboard.sessions.append(rowSession("running", .working, now.addingTimeInterval(-1)))
        precondition(dockState.sessionRows(for: [.codex]).count == 4, "duplicate indexed sessions never duplicate event items")
        let newerAsk = PermissionRequest(id: "new-ask", source: .codex, sessionID: "new-question", toolName: "request_user_input_async",
            summary: "新的问题", detail: nil, cwd: "/fixture", questions: [question],
            nativeApproval: .asynchronousQuestion(turnID: "new-turn"), at: now.addingTimeInterval(1))
        dockState.agentInteractions = [.init(request: ask), .init(request: newerAsk)]
        dockState.agentInteractionSelectionID = ask.id; dockState.agentInteractionInputID = ask.id
        precondition(dockState.sessionRows(for: [.codex])[0].session.id == ask.sessionID,
                     "a request being answered retains its place ahead of newer incoming events")
        dockState.agentInteractionInputID = nil; dockState.agentInteractionSelectionID = nil; dockState.agentInteractions = []
        precondition(dockState.sessionRows(for: [.codex]).allSatisfy { $0.requests.isEmpty }, "original-client withdrawal removes inline actions")
        let endedSession = LiveSession(id: id, agentId: "codex", task: "finished", terminal: nil,
            startedAt: now.addingTimeInterval(-10), endedAt: now, pctOfWindow: nil, tokensIn: 0, tokensOut: 0, observedAt: now)
        let sparseCompletion = UsageReport(generatedAt: now, snapshots: [], sessions: [endedSession], discoveredAgents: [agent], completions: [completion])
        precondition(AgentHubDataController.adapt(sparseCompletion, showReplies: false, now: now).sessions[0].event == .finished,
                     "source-owned completion without a turn body remains a completion when replies are hidden")
        precondition(shown.sessions[0].canSend && shown.sessions[0].navigationURL?.lastPathComponent == id)
        precondition(AgentHubDataController.navigationURL(.codexThread(id: "wrong")) == nil)
        precondition(AgentHubDataController.navigationURL(.claudeDesktopSession(id: "wrong")) == nil)
        precondition(AgentHubDataController.navigationURL(.claudeDesktopSession(id: "local_" + id))?.scheme == "claude")
        let running = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"cwd":"/fixture","turns":[{"turnId":"t1","status":"inProgress"}],"threadRuntimeStatus":{"type":"active"}}"#.utf8))
        let prepared = try CodexOriginalConversation.prepare(state: running, sessionID: id, text: "继续", messageID: "message1", now: now)!
        precondition(prepared.method == "thread-follower-steer-turn" && prepared.version == 1 && prepared.expectedTurnID == "t1")
        let receipt: [String: Any] = ["handledByClientId": "owner", "result": ["method": prepared.method, "result": ["result": ["turnId": "t1"]]]]
        precondition(CodexOriginalConversation.accepted(receipt, owner: "owner", prepared: prepared))
        precondition(!CodexOriginalConversation.accepted(receipt, owner: "other", prepared: prepared))
        precondition(!CodexOriginalConversation.accepted(["handledByClientId": "owner"], owner: "owner", prepared: prepared))
        let idle = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"cwd":"/fixture","turns":[{"turnId":"old","status":"completed"}],"threadRuntimeStatus":{"type":"idle"}}"#.utf8))
        let start = try CodexOriginalConversation.prepare(state: idle, sessionID: id, text: "下一步")!
        precondition(start.method == "thread-follower-start-turn" && start.version == 2 && start.expectedTurnID == nil)
        let turnStart = start.params["turnStart"] as! [String: Any], request = turnStart["request"] as! [String: Any]
        precondition(request["threadId"] as? String == id && request["approvalPolicy"] == nil && request["model"] == nil)
        let startReceipt: [String: Any] = ["handledByClientId": "owner", "result": ["method": start.method, "result": ["result": ["turn": ["id": "new-turn"]]]]]
        precondition(CodexOriginalConversation.accepted(startReceipt, owner: "owner", prepared: start))
        let canonical = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"turnHistory":{"kind":"canonical","history":{"islands":[{"entries":[{"value":"k1"}]}],"entitiesByKey":{"k1":{"turnId":"canonical-turn","status":"inProgress"}}}},"threadRuntimeStatus":{"type":"active"}}"#.utf8))
        precondition(try! CodexOriginalConversation.prepare(state: canonical, sessionID: id, text: "补充")?.expectedTurnID == "canonical-turn")
        precondition(try! CodexOriginalConversation.prepare(state: .object([:]), sessionID: id, text: "hello") == nil)
        precondition(try! CodexOriginalConversation.prepare(state: running, sessionID: "malformed", text: "hello") == nil)
        precondition(try! CodexOriginalConversation.prepare(state: running, sessionID: id, text: " ") == nil)
        print("AgentDockDataChecks: quota freshness, token dimensions, reply privacy and original-session receipts passed; no live messages sent")
        if CommandLine.arguments.contains("--live-read") {
            let suite = "WhileAIWorks.AgentDataProbe." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let state = AppState(defaults: defaults)
            state.selectedSources = [.codex, .claude]; state.agentReplyPreviews = false
            let controller = AgentHubDataController(state: state)
            state.refreshAgentData()
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.25)) }
            for source in [WorkSource.codex, .claude] {
                let sessions = state.agentDashboard.sessions.filter { $0.source == source }
                print("Live \(source.rawValue): \(state.agentDashboard.quotas.filter { $0.source == source }.count) quota windows; \(sessions.count) sessions; tokens present=\(sessions.contains { $0.tokensIn > 0 || $0.tokensOut > 0 }); notice=\(state.agentDashboard.notices[source] != nil)")
            }
            precondition(state.agentDashboard.updatedAt != nil, "real providers returned a report")
            precondition(state.agentDashboard.sessions.allSatisfy { $0.reply == nil }, "probe keeps reply previews disabled")
            withExtendedLifetime(controller) {}
        }
        if let index = CommandLine.arguments.firstIndex(of: "--ipc-probe"), CommandLine.arguments.count > index + 1 {
            let threadID = CommandLine.arguments[index + 1]
            guard UUID(uuidString: threadID) != nil else { throw CodexDesktopIPC.Failure.invalidInput }
            let connection = try CodexDesktopIPC(path: CodexLocator.dataDirectory.appendingPathComponent("ipc/ipc.sock").path, timeout: 8)
            defer { connection.close() }
            let response = try connection.request(method: "initialize", version: 0, source: "initializing-client", params: ["clientType": "agent-hud"])
            let client = (response["result"] as! [String: Any])["clientId"] as! String
            let ownerReply = try connection.request(method: "thread-owner-discovery", version: 1, source: client, params: ["hostId": "local", "conversationId": threadID])
            let owner = ownerReply["handledByClientId"] as! String
            let state = try connection.conversationState(source: client, owner: owner, threadID: threadID)
            let prepared = try CodexOriginalConversation.prepare(state: state, sessionID: threadID, text: "read-only probe")
            print("Codex live owner snapshot: \(prepared?.method ?? "unavailable"); request prepared only, never submitted")
        }
    }
}
