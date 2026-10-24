import Foundation
import Combine
import AgentHUDCore

struct AgentNativeRequestSnapshot {
    var requests: [PermissionRequest]
    var observed: Set<String>
    var readSeconds: [String: TimeInterval] = [:]
}
enum AgentInteractionResult { case accepted, gone, uncertain, failed }
@MainActor protocol AgentNativeRequestBridge: AnyObject {
    func fetch(_ threadIDs: Set<String>) async throws -> AgentNativeRequestSnapshot
    func resolve(_ id: String, decision: PermissionDecision) async -> AgentInteractionResult
}

/// Uses upstream's exact-owner validation and question envelope, without modifying its SDK.
@MainActor final class CodexInteractionBridge: AgentNativeRequestBridge {
    private let client = CodexDesktopPermissions()
    private var pending: [String: CodexDesktopPermissions.Pending] = [:]
    func fetch(_ threadIDs: Set<String>) async throws -> AgentNativeRequestSnapshot {
        let snapshot = try await client.fetch(threadIDs: threadIDs)
        for (id, request) in pending where snapshot.observedThreadIDs.contains(request.threadID) {
            if !snapshot.pending.contains(where: { $0.id == id }) { pending.removeValue(forKey: id) }
        }
        for request in snapshot.pending { pending[request.id] = request }
        return .init(requests: snapshot.pending.map(\.request), observed: snapshot.observedThreadIDs, readSeconds: snapshot.readSeconds)
    }
    func resolve(_ id: String, decision: PermissionDecision) async -> AgentInteractionResult {
        guard let request = pending[id] else { return .gone }
        do { try await client.resolve(decision, for: request); return .accepted }
        catch CodexDesktopPermissions.Failure.noLongerWaiting { return .gone }
        catch CodexDesktopIPC.Failure.acceptanceUncertain { return .uncertain }
        catch { return .failed }
    }
}

@MainActor final class AgentInteractionController {
    private let state: AppState
    private let codex: AgentNativeRequestBridge
    private var subscriptions = Set<AnyCancellable>()
    private var task: Task<Void, Never>?
    private var answers: [String: Task<Void, Never>] = [:]
    private var threadIDs = Set<String>()
    private var rests: [String: TimeInterval] = [:]
    private var epoch = 0
    private var hookServer: AgentInteractionHookServer?
    init(state: AppState, codex: AgentNativeRequestBridge? = nil, start: Bool = true) {
        self.state = state; self.codex = codex ?? CodexInteractionBridge()
        state.answerAgentInteraction = { [weak self] id, decision in self?.answer(id, decision: decision) }
        state.installClaudeInteraction = { [weak self] remove in self?.installHook(remove: remove) }
        state.installCodexInteraction = { [weak self] remove in self?.installHook(remove: remove, source: .codex) }
        if start {
            state.$selectedSources.combineLatest(state.$agentInteractionsEnabled, state.$desktopPetEnabled).sink { [weak self] _, _, _ in
                DispatchQueue.main.async { self?.configure() }
            }.store(in: &subscriptions)
            configure()
        }
    }
    func updateSessions(_ sessions: [LiveSession]) {
        threadIDs = Set(sessions.flatMap { [$0] + $0.descendantSessions }.compactMap {
            guard $0.isLive, case .codexThread(let id) = $0.navigationTarget else { return nil }
            return id
        })
    }
    private func configure() {
        let sources = state.agentInteractionsEnabled && state.desktopPetEnabled ? state.selectedSources : []
        state.claudeInteractionInstalled = AgentInteractionHookInstallation.isInstalled(source: .claude)
        state.codexInteractionInstalled = AgentInteractionHookInstallation.isInstalled(source: .codex)
        if !sources.intersection([.claude, .codex, .hermes, .dsh]).isEmpty {
            if hookServer == nil {
                let server = AgentInteractionHookServer(state: state)
                if server.start() { hookServer = server }
                else { state.agentInteractionSetupMessage = "交互通道被其他实例占用；请在原客户端处理" }
            }
            hookServer?.setSources(sources)
        } else { hookServer?.stop(); hookServer = nil }
        if !sources.contains(.codex) {
            epoch += 1; task?.cancel(); task = nil; rests.removeAll()
            for (id, answer) in answers { answer.cancel(); answers.removeValue(forKey: id) }
            clear(source: .codex)
        } else if task == nil {
            let generation = epoch
            task = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await poll(generation: generation)
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                }
            }
        }
    }
    func poll(generation: Int? = nil) async {
        let generation = generation ?? epoch
        let ids = threadIDs.union(state.interactions(for: .codex).filter { !$0.viaHook }.map { $0.request.sessionID })
        let uptime = ProcessInfo.processInfo.systemUptime
        rests = rests.filter { ids.contains($0.key) }
        let due = ids.filter { (rests[$0] ?? 0) <= uptime }
        guard !due.isEmpty else { return }
        do {
            let snapshot = try await codex.fetch(due)
            guard !Task.isCancelled, epoch == generation else { return }
            reconcile(snapshot, queried: due)
        } catch {
            guard !Task.isCancelled, epoch == generation else { return }
            for index in state.agentInteractions.indices where state.agentInteractions[index].source == .codex && !state.agentInteractions[index].viaHook && due.contains(state.agentInteractions[index].request.sessionID) && state.agentInteractions[index].fresh {
                state.agentInteractions[index].fresh = false
            }
        }
    }
    func reconcile(_ snapshot: AgentNativeRequestSnapshot, queried: Set<String>) {
        for (id, seconds) in snapshot.readSeconds { rests[id] = ProcessInfo.processInfo.systemUptime + max(2, seconds * 10) }
        let ids = Set(snapshot.requests.map(\.id))
        let removed = state.interactions(for: .codex).filter { !$0.viaHook && snapshot.observed.contains($0.request.sessionID) && !ids.contains($0.id) }.map(\.id)
        for id in removed { remove(id) }
        // Each write to the published list re-renders every view observing the state; a
        // poll that found nothing new (most of them) writes nothing.
        for index in state.agentInteractions.indices where state.agentInteractions[index].source == .codex && !state.agentInteractions[index].viaHook && queried.contains(state.agentInteractions[index].request.sessionID) {
            let fresh = snapshot.observed.contains(state.agentInteractions[index].request.sessionID)
            if state.agentInteractions[index].fresh != fresh { state.agentInteractions[index].fresh = fresh }
        }
        let added = snapshot.requests.filter { request in !state.agentInteractions.contains(where: { $0.id == request.id }) }
        guard !added.isEmpty else { return }
        state.agentInteractions = (state.agentInteractions + added.map { AgentInteraction(request: $0) })
            .sorted { $0.request.at < $1.request.at }
    }
    func answer(_ id: String, decision: PermissionDecision) {
        guard let interaction = state.agentInteractions.first(where: { $0.id == id }), interaction.canAnswer,
              state.agentInteractionsEnabled, state.desktopPetEnabled, state.selectedSources.contains(interaction.source),
              AgentInteractionValidation.allows(decision, for: interaction.request) else { return }
        if interaction.viaHook { hookServer?.answer(id, decision: decision); return }
        setPhase(id, .sending)
        let generation = epoch
        answers[id] = Task { [weak self] in
            guard let self else { return }
            let result = await codex.resolve(id, decision: decision)
            guard !Task.isCancelled, generation == epoch else { return }
            answers.removeValue(forKey: id)
            switch result {
            case .accepted: setPhase(id, .confirming); rests[interaction.request.sessionID] = nil
            case .gone: remove(id)
            case .uncertain: setPhase(id, .uncertain)
            case .failed: setPhase(id, .failed)
            }
        }
    }
    private func setPhase(_ id: String, _ phase: AgentInteraction.Phase) {
        guard let index = state.agentInteractions.firstIndex(where: { $0.id == id }) else { return }
        state.agentInteractions[index].phase = phase
    }
    private func remove(_ id: String) {
        state.agentInteractions.removeAll { $0.id == id }; state.agentInteractionDrafts[id] = nil
        if state.agentInteractionInputID == id { state.agentInteractionInputID = nil }
    }
    private func clear(source: WorkSource) { for id in state.interactions(for: source).map(\.id) { remove(id) } }
    private func installHook(remove: Bool, source: WorkSource = .claude) {
        do {
            guard let helper = Bundle.main.url(forResource: "while-ai-works-agent-interaction", withExtension: nil) else {
                state.agentInteractionSetupMessage = "请使用完整应用包安装交互监听"; return
            }
            try AgentInteractionHookInstallation.configure(helper: helper, remove: remove, source: source)
            state.claudeInteractionInstalled = AgentInteractionHookInstallation.isInstalled(source: .claude)
            state.codexInteractionInstalled = AgentInteractionHookInstallation.isInstalled(source: .codex)
            state.agentInteractionSetupMessage = remove ? "已移除 \(source.clientName) 交互监听，请重启会话" : "已安装 \(source.clientName) 交互监听，请重启会话；保留原客户端的权限与审核方式"
        } catch { state.agentInteractionSetupMessage = "交互监听配置未能更新；保留原配置，请检查文件权限和格式" }
    }
    func stop() {
        epoch += 1; task?.cancel(); task = nil
        for answer in answers.values { answer.cancel() }; answers.removeAll()
        hookServer?.stop(); hookServer = nil; clear(source: .codex)
    }
}
