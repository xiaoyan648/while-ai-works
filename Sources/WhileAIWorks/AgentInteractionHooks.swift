import Foundation
import Network
import Darwin
import AgentHUDCore
import AgentHUDSupport

/// Only our named handler is changed; existing status hooks, gateways and other HUDs stay intact.
enum AgentInteractionHookInstallation {
    static let marker = "--cat-interaction-hook"
    static var socketPath: String { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".while-ai-works/interactions.sock").path }
    static func configuration(home: URL = FileManager.default.homeDirectoryForCurrentUser, source: WorkSource = .claude) -> URL {
        if source == .codex { return CodexLocator.dataDirectory.appendingPathComponent("hooks.json") }
        let directory = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".claude")
        return directory.appendingPathComponent("settings.json")
    }
    static func owns(_ hook: [String: Any], source: WorkSource = .claude) -> Bool {
        guard let command = hook["command"] as? String else { return false }
        return command.hasPrefix("'") && command.hasSuffix("/while-ai-works-agent-interaction' " + marker + " " + source.rawValue)
    }
    static func isInstalled(at file: URL? = nil, source: WorkSource = .claude) -> Bool {
        let file = (file ?? configuration(source: source)).resolvingSymlinksInPath()
        guard let data = try? Data(contentsOf: file), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = object["hooks"] as? [String: Any], let groups = hooks["PermissionRequest"] as? [[String: Any]] else { return false }
        return groups.contains { ($0["hooks"] as? [[String: Any]] ?? []).contains { owns($0, source: source) } }
    }
    static func configure(helper: URL, remove: Bool, file: URL? = nil, source: WorkSource = .claude) throws {
        let file = (file ?? configuration(source: source)).resolvingSymlinksInPath()
        var object: [String: Any] = [:]
        var original: Data?
        let permissions = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        if FileManager.default.fileExists(atPath: file.path) {
            original = try Data(contentsOf: file)
            guard let parsed = try JSONSerialization.jsonObject(with: original!) as? [String: Any] else { throw Failure.format }
            object = parsed
        }
        let updated = try updating(object, helper: helper, remove: remove, source: source)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".cat-hook-" + UUID().uuidString)
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Failure.write }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: bytes); try handle.synchronize(); try handle.close()
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
        let current = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
        guard current == original else { throw Failure.changed }
        guard Darwin.rename(temporary.path, file.path) == 0 else { throw Failure.write }
    }
    enum Failure: Error { case format, changed, write }
    static func updating(_ object: [String: Any], helper: URL, remove: Bool, source: WorkSource = .claude) throws -> [String: Any] {
        guard source == .claude || source == .codex else { throw Failure.format }
        guard object["hooks"] == nil || object["hooks"] is [String: Any] else { throw Failure.format }
        var result = object, hooks = object["hooks"] as? [String: Any] ?? [:]
        guard hooks["PermissionRequest"] == nil || hooks["PermissionRequest"] is [[String: Any]] else { throw Failure.format }
        var groups: [[String: Any]] = []
        for var group in hooks["PermissionRequest"] as? [[String: Any]] ?? [] {
            guard let entries = group["hooks"] as? [[String: Any]] else { throw Failure.format }
            group["hooks"] = entries.filter { !owns($0, source: source) }
            if !(group["hooks"] as! [[String: Any]]).isEmpty { groups.append(group) }
        }
        if !remove {
            let quoted = "'" + helper.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            groups.append(["matcher": "", "hooks": [["type": "command", "command": quoted + " " + marker + " " + source.rawValue, "timeout": 660]]])
        }
        hooks["PermissionRequest"] = groups.isEmpty ? nil : groups
        result["hooks"] = hooks.isEmpty && object["hooks"] == nil ? nil : hooks
        return result
    }
}

@MainActor final class AgentInteractionHookServer {
    private let state: AppState
    private let path: String
    private var listener: UnixSocketListener?
    private var waiting: [String: NWConnection] = [:]
    private var sources: Set<WorkSource> = [.claude, .codex]
    init(state: AppState, path: String = AgentInteractionHookInstallation.socketPath) { self.state = state; self.path = path }
    func start() -> Bool {
        let listener = UnixSocketListener(path: path, requestLimit: 1024 * 1024, category: "cat-interactions") { [weak self] data, connection in
            self?.register(data, connection: connection)
        }
        guard listener.start() else { return false }
        self.listener = listener; return true
    }
    private func register(_ data: Data, connection: NWConnection) {
        guard state.agentInteractionsEnabled, state.desktopPetEnabled,
              let request = try? Self.parse(data, id: "agent-hook:" + UUID().uuidString),
              let source = WorkSource(rawValue: request.source.rawValue), sources.contains(source), state.selectedSources.contains(source)
        else { connection.cancel(); return }
        let id = request.id
        waiting[id] = connection; state.agentInteractions.append(.init(request: request, viaHook: true))
        connection.stateUpdateHandler = { [weak self] status in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch status {
                case .cancelled, .failed:
                    if let index = self.state.agentInteractions.firstIndex(where: { $0.id == id }),
                       self.state.agentInteractions[index].phase == .sending || self.state.agentInteractions[index].phase == .uncertain {
                        self.waiting[id] = nil
                        self.state.agentInteractions[index].phase = .uncertain
                        self.state.agentInteractions[index].fresh = false
                    } else { self.remove(id) }
                default: break
                }
            }
        }
        // Returning no decision after ten minutes restores the client's own prompt.
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { [weak self] in
            guard let self, let connection = self.waiting[id] else { return }
            connection.cancel(); self.remove(id)
        }
    }
    func answer(_ id: String, decision: PermissionDecision) {
        guard let index = state.agentInteractions.firstIndex(where: { $0.id == id }),
              state.agentInteractionsEnabled, state.desktopPetEnabled, sources.contains(state.agentInteractions[index].source),
              state.selectedSources.contains(state.agentInteractions[index].source),
              state.agentInteractions[index].canAnswer, let connection = waiting[id],
              AgentInteractionValidation.allows(decision, for: state.agentInteractions[index].request) else { return }
        let bytes = decision.response(for: state.agentInteractions[index].request)
        guard !bytes.isEmpty else { return }
        state.agentInteractions[index].phase = .sending
        connection.send(content: bytes, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if error != nil, let index = self.state.agentInteractions.firstIndex(where: { $0.id == id }) {
                    self.state.agentInteractions[index].phase = .uncertain
                    self.state.agentInteractions[index].fresh = false
                } else {
                    if let item = self.state.agentInteractions.first(where: { $0.id == id }) {
                        let message = "已交给 " + item.source.clientName + " 原客户端"
                        self.state.agentInteractionDelivery[item.source] = message
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                            if self?.state.agentInteractionDelivery[item.source] == message { self?.state.agentInteractionDelivery[item.source] = nil }
                        }
                    }
                    self.remove(id)
                }
                connection.cancel()
            }
        })
    }
    private func remove(_ id: String) {
        waiting.removeValue(forKey: id)
        state.agentInteractions.removeAll { $0.id == id }; state.agentInteractionDrafts[id] = nil
        if state.agentInteractionInputID == id { state.agentInteractionInputID = nil }
    }
    func stop() {
        for (id, connection) in waiting { connection.cancel(); remove(id) }
        for id in state.agentInteractions.filter({ $0.viaHook }).map(\.id) { remove(id) }
        listener?.stop(); listener = nil
    }
    func setSources(_ sources: Set<WorkSource>) {
        self.sources = sources
        for request in state.agentInteractions where request.viaHook && !sources.contains(request.source) {
            waiting[request.id]?.cancel(); remove(request.id)
        }
    }
    /// Preserve full command/input for inspection; no truncation can conceal an approved suffix.
    static func parse(_ data: Data, id: String) throws -> PermissionRequest? {
        guard data.count <= 1024 * 1024, let payload = try JSONValue.parse(data).catObject,
              let name = payload["_catHubSource"]?.catString, let source = PermissionHooks.Source(rawValue: name),
              source == .claude || source == .codex,
              let session = payload["session_id"]?.catString, !session.isEmpty,
              let tool = payload["tool_name"]?.catString, !tool.isEmpty,
              payload["hook_event_name"]?.catString == "PermissionRequest" else { return nil }
        let input = payload["tool_input"] ?? .null
        if source == .codex, payload["_catReviewer"]?.catString != "user" { return nil }
        var questions: [PermissionQuestion] = []
        if tool == "AskUserQuestion", source == .claude {
            guard let list = input[cat: "questions"].catArray, !list.isEmpty, list.count <= 32 else { return nil }
            for item in list {
                guard let text = item[cat: "question"].catString, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let rawOptions = item[cat: "options"].catArray else { return nil }
                var options: [PermissionQuestion.Option] = []
                for option in rawOptions {
                    guard let label = option[cat: "label"].catString, !label.isEmpty else { return nil }
                    options.append(.init(label: label, description: option[cat: "description"].catString))
                }
                questions.append(.init(question: text, header: item[cat: "header"].catString, options: options, multiSelect: item[cat: "multiSelect"].catBool ?? false))
            }
            // Claude keys answers by question text: ambiguous duplicates must stay in its own prompt.
            guard Set(questions.map(\.answerKey)).count == questions.count else { return nil }
        }
        let detail = String(decoding: try RecordCoding.encoder().encode(input), as: UTF8.self)
        let summary = !questions.isEmpty ? questions[0].question : tool == "ExitPlanMode" ? "计划需要你审阅" : "允许 \(source.vendor) 使用 " + tool + "？"
        return .init(id: id, source: source, sessionID: session, toolName: tool, summary: summary,
            detail: questions.isEmpty ? detail : nil, cwd: payload["cwd"]?.catString,
            path: input[cat: "file_path"].catString, questions: questions, questionInput: input, at: Date())
    }
}
