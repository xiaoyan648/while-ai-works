import AppKit
import Combine
import AgentHUDCore
import AgentHUDSupport
import WhileCore

/// Finder does not inherit the user's terminal PATH. Extend only this app's environment;
/// never run shell startup files or inherit interactive aliases/permission flags.
enum AgentCommandEnvironment {
    static func searchPath(home: URL, inherited: String) -> String {
        var seen = Set<String>()
        let userPaths = [".local/bin", ".npm-global/bin", ".npm/bin"].map {
            home.appendingPathComponent($0, isDirectory: true).path
        }
        return (inherited.split(separator: ":").map(String.init) + userPaths +
                ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
            .filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    static func configure() {
        let path = searchPath(home: FileManager.default.homeDirectoryForCurrentUser,
                              inherited: ProcessInfo.processInfo.environment["PATH"] ?? "")
        setenv("PATH", path, 1)
    }
}

/// Owns only the two requested providers. No hooks, remote relay or demo assembly.
@MainActor
final class AgentHubDataController {
    private let state: AppState
    private let settings: SettingsStore
    private let ledger = UsageLedger.inMemory()
    private var store: UsageStore?
    private var observation: UsageChangeObservation?
    private var subscriptions = Set<AnyCancellable>()
    private let interactions: AgentInteractionController

    init(state: AppState) {
        self.state = state
        interactions = AgentInteractionController(state: state)
        L10n.setLanguage(.zhHans)
        settings = SettingsStore(defaults: UserDefaults(suiteName: "WhileAIWorks.AgentData")!)
        settings.update { $0.clientHooks = false; $0.language = .zhHans }
        state.refreshAgentData = { [weak self] in
            Task { [weak self] in
                guard let self, let store = self.store else { return }
                await store.refreshAccounts(); await store.refresh(); self.publish()
            }
        }
        state.openAgentSession = { [weak self] session in
            if let url = session.navigationURL, NSWorkspace.shared.open(url) { return }
            if let command = session.resumeCommand {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
                self?.state.agentMessageStatus[session.id] = "已复制原会话恢复命令，在原终端执行"
            } else { self?.state.agentMessageStatus[session.id] = "客户端未提供原会话入口" }
        }
        state.sendAgentMessage = { session, text in
            await Task.detached(priority: .userInitiated) { CodexOriginalConversation.send(session: session, text: text) }.value
        }
        state.$selectedSources.removeDuplicates().sink { [weak self] sources in
            self?.configure(sources: sources)
        }.store(in: &subscriptions)
        state.$agentReplyPreviews.removeDuplicates().sink { [weak self] enabled in
            self?.publish(showReplies: enabled)
        }.store(in: &subscriptions)
    }

    private func configure(sources: Set<WorkSource>) {
        store?.stop(); observation?.cancel()
        var providers: [CombinedUsageProvider.Source] = []
        if sources.contains(.codex) {
            let directory = CodexLocator.dataDirectory
            let provider = CodexUsageProvider(readLimits: {
                guard let executable = CodexLocator.find() else { throw UsageProviderError("安装并登录 Codex 后读取额度") }
                return try await CodexAppServerClient(executable: executable, dataDirectory: directory).fetch()
            }, transcripts: .standard(directory: directory, ledger: ledger),
               history: QuotaHistoryStore(ledger: ledger, scope: "while-codex"))
            providers.append(.init("Codex", provider))
        }
        if sources.contains(.claude) { providers.append(.init("Claude", ClaudeCodeProvider.standard(ledger: ledger, persistent: false))) }
        guard !providers.isEmpty else { store = nil; state.agentDashboard = AgentDockData(); return }
        let store = UsageStore(provider: CombinedUsageProvider(providers, ledger: ledger), settings: settings)
        self.store = store
        observation = store.observeChanges { [weak self] _ in self?.publish() }
        store.start()
    }

    private func publish(showReplies: Bool? = nil) {
        guard let report = store?.report else { return }
        state.agentDashboard = Self.adapt(report, showReplies: showReplies ?? state.agentReplyPreviews)
        interactions.updateSessions(report.sessions)
    }
    func stop() { interactions.stop(); store?.stop(); observation?.cancel() }
    private static func planTitle(_ value: String) -> String {
        switch value.lowercased() {
        case "pro": return "Pro"
        case "max", "max_5x": return "Max"
        case "max_20x": return "Max 20×"
        case "team": return "Team"
        default: return "订阅"
        }
    }

    static func adapt(_ report: UsageReport, showReplies: Bool, now: Date = Date()) -> AgentDockData {
        let agents = report.discoveredAgents + report.consumers
        let byID = Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func source(_ id: String, vendor: String? = nil) -> WorkSource? {
            let value = (vendor ?? byID[id]?.vendor ?? id).lowercased()
            if value.contains("codex") { return .codex }
            if value.contains("claude") { return .claude }
            return nil
        }
        var data = AgentDockData(updatedAt: report.generatedAt)
        for (name, plan) in report.subscriptions {
            if let source = vendor(name) { data.plans[source] = planTitle(plan) }
        }
        for (vendor, notice) in report.sourceNotices {
            if let source = source(vendor) { data.notices[source] = notice }
        }
        for snapshot in report.snapshots {
            guard let source = source(snapshot.agentId) else { continue }
            if let descriptor = byID[snapshot.agentId], !report.isCurrent(descriptor) { continue }
            let stale = now.timeIntervalSince(snapshot.updatedAt) > 15 * 60 ||
                report.quotaNotices?.contains(where: { key, _ in Self.vendor(key) == source }) == true
            let observedTitle = byID[snapshot.agentId]?.shortModel ?? byID[snapshot.agentId]?.model ?? "账户额度"
            let title = observedTitle == "Weekly" ? "每周" : L10n.modelLabel(observedTitle)
            let descriptor = byID[snapshot.agentId]
            let key = descriptor?.windowKey ?? snapshot.agentId
            let window: AgentQuotaWindow
            if source == .claude, key == ClaudeUsage.sessionRowId { window = .session }
            else if source == .claude, key == ClaudeUsage.weeklyRowId { window = .weekly }
            else if source == .claude, key.hasPrefix(ClaudeUsage.weeklyRowId + "-") { window = .modelWeekly }
            else if descriptor?.allModels == false { window = .other }
            else if snapshot.windowDuration.map({ $0 >= 6 * 86400 && $0 <= 8 * 86400 }) == true ||
                        observedTitle.lowercased().contains("week") || observedTitle.contains("周") { window = .weekly }
            else if snapshot.windowDuration.map({ $0 > 0 && $0 <= 86400 }) == true { window = .session }
            else { window = .other }
            data.quotas.append(.init(id: snapshot.agentId, source: source, title: title,
                remaining: snapshot.remainingPct.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil },
                resetAt: snapshot.resetAt, observedAt: snapshot.updatedAt, stale: stale, window: window,
                windowDuration: snapshot.windowDuration))
            if let weekly = snapshot.weeklyRemainingPct, weekly.isFinite,
               !observedTitle.lowercased().contains("week"), !observedTitle.contains("周") {
                data.quotas.append(.init(id: snapshot.agentId + "-weekly", source: source, title: "每周",
                    remaining: min(100, max(0, weekly)), resetAt: snapshot.weeklyResetAt,
                    observedAt: snapshot.updatedAt, stale: stale, window: .weekly, windowDuration: 7 * 86400))
            }
        }
        let turns = Dictionary(report.turns.map { ($0.sessionID, $0) }, uniquingKeysWith: { $0.observedAtMs > $1.observedAtMs ? $0 : $1 })
        let completions = Dictionary(report.completions.map { ($0.sessionID, $0) }, uniquingKeysWith: { $0.completedAt > $1.completedAt ? $0 : $1 })
        for session in report.sessions.flatMap({ [$0] + $0.descendantSessions }) {
            let turn = turns[session.id]
            guard let source = source(session.agentId, vendor: turn?.provider) else { continue }
            let running = session.isLive(at: now) && turn?.state != .completed && turn?.state != .ended
            let status = turn?.state == .waitingForApproval ? "需要你回应" :
                turn?.state == .completed ? "已回复" : turn?.state == .ended ? "已停止" : running ? "工作中" : "最近会话"
            let url = Self.navigationURL(session.navigationTarget)
            let resume = UUID(uuidString: session.id) == nil ? nil : (source == .claude ? "claude --resume " : "codex resume ") + session.id
            let completion = completions[session.id]
            let completedWithoutTurn = turn == nil && !running && completion.map {
                (session.lastActivityAt ?? session.startedAt) <= $0.completedAt
            } == true
            var completedAt: Date? = completedWithoutTurn ? completion?.completedAt : nil
            let finalReply: String?
            if let completion, let turn, turn.state == .completed {
                // Completion exports a vendor/session/turn identity, rather than its raw turn ID.
                let identity = SessionCompletion(sessionID: session.id, vendor: completion.vendor, turnID: turn.turnID,
                    task: "", model: "", startedAt: nil, completedAt: completion.completedAt).id
                if identity == completion.id { completedAt = completion.completedAt }
                finalReply = identity == completion.id ? completion.message : nil
            } else if let completion, completedWithoutTurn {
                finalReply = completion.message
            } else { finalReply = nil }
            let reply = showReplies ? (turn?.message ?? finalReply) : nil
            data.sessions.append(.init(id: session.id, source: source,
                title: session.agentName ?? (session.task.isEmpty ? "未命名会话" : String(session.task.prefix(120))),
                project: session.terminal, status: status, running: running,
                tokensIn: max(0, session.tokensIn), tokensOut: max(0, session.tokensOut), cacheRead: max(0, session.cacheReadTokens),
                reply: reply, observedAt: session.lastActivityAt ?? session.observedAt, navigationURL: url, resumeCommand: resume,
                event: turn?.state == .waitingForApproval ? .approval : (turn?.state == .completed || completedWithoutTurn) ? .finished : running ? .working : .recent,
                eventAt: completedAt ?? turn.map { Date(timeIntervalSince1970: Double($0.observedAtMs) / 1000) },
                turnStartedAt: running ? turn?.startedAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } : nil))
        }
        data.sessions = Array(Dictionary(data.sessions.map { ($0.dockIdentity, $0) }, uniquingKeysWith: {
            $0.observedAt >= $1.observedAt ? $0 : $1
        }).values)
        data.sessions.sort {
            let lhs = AgentDockSessionRow(session: $0, requests: []), rhs = AgentDockSessionRow(session: $1, requests: [])
            if lhs.priority(at: now) != rhs.priority(at: now) { return lhs.priority(at: now) < rhs.priority(at: now) }
            if lhs.eventAt != rhs.eventAt { return lhs.eventAt > rhs.eventAt }
            return lhs.id < rhs.id
        }
        var counts: [WorkSource: Int] = [:]
        data.sessions = data.sessions.filter { session in
            guard counts[session.source, default: 0] < 15 else { return false }
            counts[session.source, default: 0] += 1
            return true
        }
        return data
    }

    private static func vendor(_ value: String) -> WorkSource? {
        value.lowercased().contains("codex") ? .codex : value.lowercased().contains("claude") ? .claude : nil
    }
    static func navigationURL(_ target: SessionNavigationTarget?) -> URL? {
        guard let target else { return nil }
        var url = URLComponents()
        switch target {
        case .codexThread(let id):
            guard UUID(uuidString: id) != nil else { return nil }
            url.scheme = "codex"; url.host = "threads"; url.path = "/" + id
        case .claudeDesktopSession(let id), .claudeCoworkSession(let id):
            guard id.hasPrefix("local_"), UUID(uuidString: String(id.dropFirst(6))) != nil else { return nil }
            url.scheme = "claude"; url.host = "claude.ai"
            let path = if case .claudeCoworkSession = target { "/cowork/" } else { "/epitaxy/" }
            url.path = path + id
        case .iTermSession(let id):
            guard !id.isEmpty else { return nil }
            url.scheme = "iterm2"; url.path = "reveal"; url.queryItems = [.init(name: "sessionid", value: id)]
        default: return nil
        }
        return url.url
    }
}

/// User-triggered input follows the existing desktop owner. Never launches a second agent.
enum CodexOriginalConversation {
    static func send(session: AgentDockSession, text: String) -> AgentMessageOutcome {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard session.canSend, UUID(uuidString: session.id) != nil, !text.isEmpty, text.utf8.count <= 16_384 else { return .unavailable }
        var wrote = false
        do {
            let connection = try CodexDesktopIPC(path: CodexLocator.dataDirectory.appendingPathComponent("ipc/ipc.sock").path, timeout: 8)
            defer { connection.close() }
            let initialized = try connection.request(method: "initialize", version: 0, source: "initializing-client", params: ["clientType": "agent-hud"])
            guard let client = (initialized["result"] as? [String: Any])?["clientId"] as? String else { return .unavailable }
            let discovered = try connection.request(method: "thread-owner-discovery", version: 1, source: client,
                params: ["hostId": "local", "conversationId": session.id])
            guard let owner = discovered["handledByClientId"] as? String else { return .unavailable }
            let state = try connection.conversationState(source: client, owner: owner, threadID: session.id)
            let prepared = try prepare(state: state, sessionID: session.id, text: text)
            guard let prepared else { return .unavailable }
            let reply = try connection.request(method: prepared.method, version: prepared.version, source: client, target: owner,
                params: prepared.params, didWrite: { wrote = true })
            guard accepted(reply, owner: owner, prepared: prepared) else { return .uncertain }
            return .accepted
        } catch CodexDesktopIPC.Failure.rejected(let reason) {
            if ["request-timeout", "server-closed", "client-disconnected"].contains(reason) && wrote { return .uncertain }
            return .failed("原会话未接受消息，请在客户端继续")
        } catch { return wrote ? .uncertain : .unavailable }
    }

    struct Prepared {
        let method: String
        let version: Int
        let params: [String: Any]
        let expectedTurnID: String?
    }
    static func prepare(state: JSONValue, sessionID: String, text: String, messageID: String = UUID().uuidString.lowercased(), now: Date = Date()) throws -> Prepared? {
        guard UUID(uuidString: sessionID) != nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 16_384 else { return nil }
        let input: [[String: Any]] = [["type": "text", "text": text, "text_elements": []]]
        var context: [String: Any] = ["prompt": text, "turnTrigger": "composer", "addedFiles": [], "fileAttachments": [], "imageAttachments": [], "ideContext": NSNull()]
        var restore: [String: Any] = ["id": messageID, "text": text, "context": context, "createdAt": now.timeIntervalSince1970 * 1000]
        if let cwd = state.dock("cwd").dockString { context["workspaceRoots"] = [cwd]; restore["context"] = context; restore["cwd"] = cwd }
        let turns: [JSONValue]
        if state.dock("turnHistory").dock("kind").dockString == "canonical" {
            guard let islands = state.dock("turnHistory").dock("history").dock("islands").dockArray,
                  let entities = state.dock("turnHistory").dock("history").dock("entitiesByKey").dockObject else { return nil }
            var canonical: [JSONValue] = []
            for island in islands {
                guard let entries = island.dock("entries").dockArray else { return nil }
                for entry in entries {
                    guard let key = entry.dock("value").dockString, let turn = entities[key] else { return nil }
                    canonical.append(turn)
                }
            }
            turns = canonical
        } else { turns = state.dock("turns").dockArray ?? [] }
        if let active = turns.last, active.dock("status").dockString == "inProgress", let turnID = active.dock("turnId").dockString,
           state.dock("threadRuntimeStatus").dock("type").dockString != "idle" {
            return Prepared(method: "thread-follower-steer-turn", version: 1,
                params: ["conversationId": sessionID, "clientUserMessageId": messageID, "input": input,
                         "attachments": [], "restoreMessage": restore], expectedTurnID: turnID)
        }
        guard state.dock("threadRuntimeStatus").dock("type").dockString == "idle" else { return nil }
        // The owner fills in its saved model, collaboration and permission settings.
        let request: [String: Any] = ["threadId": sessionID, "input": input, "clientUserMessageId": messageID, "turnTrigger": "composer"]
        return Prepared(method: "thread-follower-start-turn", version: 2,
            params: ["conversationId": sessionID, "turnStart": ["context": context, "request": request]], expectedTurnID: nil)
    }
    static func accepted(_ reply: [String: Any], owner: String, prepared: Prepared) -> Bool {
        guard reply["handledByClientId"] as? String == owner,
              let envelope = reply["result"] as? [String: Any], envelope["method"] as? String == prepared.method,
              let outer = envelope["result"] as? [String: Any], let receipt = outer["result"] as? [String: Any] else { return false }
        if let expected = prepared.expectedTurnID { return receipt["turnId"] as? String == expected }
        guard let turn = receipt["turn"] as? [String: Any], let id = turn["id"] as? String, !id.isEmpty else { return false }
        return true
    }
}

private extension JSONValue {
    func dock(_ key: String) -> JSONValue {
        if case .object(let fields) = self { return fields[key] ?? .null }
        return .null
    }
    var dockString: String? { if case .string(let value) = self { return value }; return nil }
    var dockArray: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
    var dockObject: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }
}
