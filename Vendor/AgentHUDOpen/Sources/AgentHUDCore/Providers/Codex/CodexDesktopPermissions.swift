import AgentHUDSupport
import Foundation

/// Native app approvals and mid-turn questions belong to Desktop's original owner, independently of CLI hooks.
public struct CodexDesktopPermissions: Sendable {
    public struct Pending: Sendable {
        public let request: PermissionRequest
        public let threadID: String
        public let ownerClientID: String
        public let wireRequest: JSONValue
        public let requestID: JSONValue
        public var id: String { request.id }
    }

    public struct Snapshot: Sendable {
        public let pending: [Pending]
        /// Only successfully read owners can establish that a previously visible request has disappeared.
        public let observedThreadIDs: Set<String>
        /// How long each thread's read took, whether or not it succeeded. Desktop builds the thread's whole state for
        /// every read, so a slow read is one to repeat less often.
        public var readSeconds: [String: TimeInterval] = [:]
    }

    public enum Failure: Error, Equatable, Sendable {
        case noLongerWaiting, unsupportedDecision
    }

    private let dataDirectory: URL
    private let timeout: TimeInterval
    var clock: @Sendable () -> Date = { Date() }

    public init(dataDirectory: URL = CodexLocator.dataDirectory, timeout: TimeInterval = 3) {
        self.dataDirectory = dataDirectory
        self.timeout = timeout
    }

    public func fetch(threadIDs: Set<String>) async throws -> Snapshot {
        guard timeout.isFinite, timeout > 0, !threadIDs.contains(where: { $0.isEmpty }) else {
            throw CodexDesktopIPC.Failure.invalidInput
        }
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: Snapshot.self) { group in
            var remaining = threadIDs.sorted().makeIterator()
            func enqueue(_ threadID: String) {
                group.addTask { [self] in try await detached { [self] in try read(threadID: threadID) } }
            }
            // Bound socket work while allowing an unavailable owner to time out independently of the others.
            for _ in 0..<min(4, threadIDs.count) {
                if let threadID = remaining.next() { enqueue(threadID) }
            }
            var found: [Pending] = [], observed = Set<String>(), seconds: [String: TimeInterval] = [:]
            while let result = try await group.next() {
                found += result.pending
                observed.formUnion(result.observedThreadIDs)
                seconds.merge(result.readSeconds) { max($0, $1) }
                if let threadID = remaining.next() { enqueue(threadID) }
            }
            return Snapshot(pending: found.sorted { $0.id < $1.id }, observedThreadIDs: observed, readSeconds: seconds)
        }
    }

    /// Re-read the exact owner and request before sending only the option the user selected.
    public func resolve(_ decision: PermissionDecision, for pending: Pending) async throws {
        guard let response = try Self.response(decision, for: pending) else { return }
        guard timeout.isFinite, timeout > 0 else { throw CodexDesktopIPC.Failure.invalidInput }
        try await detached { [self] in
            try Task.checkCancellation()
            let connection = try CodexDesktopIPC(path: socketPath, timeout: timeout)
            defer { connection.close() }
            let clientID = try Self.initialize(connection)
            let owner: String
            do { owner = try Self.owner(connection, source: clientID, threadID: pending.threadID) }
            catch CodexDesktopIPC.Failure.rejected("no-client-found") { throw Failure.noLongerWaiting }
            guard owner == pending.ownerClientID else { throw Failure.noLongerWaiting }
            let state = try connection.conversationState(source: clientID, owner: owner, threadID: pending.threadID)
            let current = try Self.pending(state, threadID: pending.threadID, ownerClientID: owner, now: clock())
            guard current.contains(where: { $0.id == pending.id && $0.wireRequest == pending.wireRequest }) else {
                throw Failure.noLongerWaiting
            }
            try Task.checkCancellation()
            let method: String
            let params: [String: Any]
            switch pending.request.nativeApproval {
            case .computerUseApp:
                method = Self.answerMethod
                params = ["conversationId": pending.threadID,
                          "requestId": try Self.foundation(pending.requestID),
                          "response": try Self.foundation(response)]
            case .asynchronousQuestion(let turnID):
                guard try CodexDesktopQuestions.currentTurnID(state) == turnID,
                      let text = response.stringValue else { throw Failure.noLongerWaiting }
                method = Self.questionAnswerMethod
                let messageID = UUID().uuidString.lowercased()
                var context: [String: Any] = ["prompt": text, "turnTrigger": "send_user_message_async_question",
                    "addedFiles": [], "fileAttachments": [], "ideContext": NSNull(), "imageAttachments": []]
                var restore: [String: Any] = ["id": messageID, "text": text, "context": context,
                                             "createdAt": clock().timeIntervalSince1970 * 1000]
                if let cwd = state["cwd"].stringValue {
                    context["workspaceRoots"] = [cwd]
                    restore["context"] = context
                    restore["cwd"] = cwd
                }
                params = ["conversationId": pending.threadID, "clientUserMessageId": messageID,
                          "input": [["type": "text", "text": text, "text_elements": []]],
                          "attachments": [], "restoreMessage": restore]
            case nil: throw Failure.unsupportedDecision
            }
            let reply: [String: Any]
            var wroteAnswer = false
            do {
                reply = try connection.request(method: method, version: 1, source: clientID,
                    target: owner, params: params, didWrite: { wroteAnswer = true })
            } catch let error as CodexDesktopIPC.Failure {
                if case .rejected(let reason) = error,
                   !["request-timeout", "server-closed", "client-disconnected"].contains(reason) { throw error }
                throw wroteAnswer ? CodexDesktopIPC.Failure.acceptanceUncertain : error
            } catch {
                if wroteAnswer { throw CodexDesktopIPC.Failure.acceptanceUncertain }
                throw error
            }
            let receipt = try Self.json(reply)
            guard receipt["handledByClientId"].stringValue == owner,
                  receipt["result"]["method"].stringValue == method else {
                throw CodexDesktopIPC.Failure.acceptanceUncertain
            }
            switch pending.request.nativeApproval {
            case .computerUseApp:
                guard receipt["result"]["result"]["ok"] == .bool(true) else {
                    throw CodexDesktopIPC.Failure.acceptanceUncertain
                }
            case .asynchronousQuestion(let turnID):
                guard receipt["result"]["result"]["result"]["turnId"].stringValue == turnID else {
                    throw CodexDesktopIPC.Failure.acceptanceUncertain
                }
            case nil: throw Failure.unsupportedDecision
            }
        }
    }

    private static let answerMethod = "thread-follower-submit-mcp-server-elicitation-response"
    private static let questionAnswerMethod = "thread-follower-steer-turn"
    private var socketPath: String { dataDirectory.appendingPathComponent("ipc/ipc.sock").path }

    private func read(threadID: String) throws -> Snapshot {
        try Task.checkCancellation()
        // A missing socket is a service failure. A missing or unreadable owner is unknown for that thread alone.
        let started = ProcessInfo.processInfo.systemUptime
        let connection = try CodexDesktopIPC(path: socketPath, timeout: timeout)
        defer { connection.close() }
        var seconds: [String: TimeInterval] { [threadID: ProcessInfo.processInfo.systemUptime - started] }
        do {
            let clientID = try Self.initialize(connection)
            let owner = try Self.owner(connection, source: clientID, threadID: threadID)
            let state = try connection.conversationState(source: clientID, owner: owner, threadID: threadID)
            let requests = try Self.pending(state, threadID: threadID, ownerClientID: owner, now: clock())
            try Task.checkCancellation()
            return Snapshot(pending: requests, observedThreadIDs: [threadID], readSeconds: seconds)
        } catch {
            try Task.checkCancellation()
            return Snapshot(pending: [], observedThreadIDs: [], readSeconds: seconds)
        }
    }

    private static func initialize(_ connection: CodexDesktopIPC) throws -> String {
        let initialized = try connection.request(method: "initialize", version: 0,
            source: "initializing-client", params: ["clientType": "agent-hud"])
        guard let clientID = (initialized["result"] as? [String: Any])?["clientId"] as? String,
              !clientID.isEmpty else { throw CodexDesktopIPC.Failure.protocolError }
        return clientID
    }

    private static func owner(_ connection: CodexDesktopIPC, source: String, threadID: String) throws -> String {
        let discovered = try connection.request(method: "thread-owner-discovery", version: 1,
            source: source, params: ["hostId": "local", "conversationId": threadID])
        guard let owner = discovered["handledByClientId"] as? String, !owner.isEmpty else {
            throw CodexDesktopIPC.Failure.protocolError
        }
        return owner
    }

    static func pending(_ state: JSONValue, threadID: String, ownerClientID: String, now: Date) throws -> [Pending] {
        guard let requests = state["requests"].arrayValue else { throw CodexDesktopIPC.Failure.protocolError }
        let approvals = try requests.compactMap { wire -> Pending? in
            let params = wire["params"], metadata = params["_meta"]
            guard wire["method"].stringValue == "mcpServer/elicitation/request", wire["completed"].boolValue != true,
                  params["threadId"].stringValue == threadID, params["mode"].stringValue == "form",
                  metadata["codex_approval_kind"].stringValue == "mcp_tool_call",
                  metadata["connector_id"].stringValue == "computer-use",
                  let app = metadata["tool_params"]["app"].stringValue,
                  !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let requestID = wire["id"]
            switch requestID {
            case .string(let value) where !value.isEmpty: break
            case .integer: break
            default: return nil
            }
            guard let modes = metadata["persist"].arrayValue,
                  modes.allSatisfy({ $0.stringValue == "session" || $0.stringValue == "always" }),
                  modes.contains(.string("session")) else { return nil }
            let persist = modes.compactMap(\.stringValue)
            let displayName = metadata["tool_params_display"].arrayValue?.first(where: { $0["name"].stringValue == "app" })?["value"]
                .stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = displayName.flatMap { $0.isEmpty ? nil : $0 } ?? app
            let encodedID = String(decoding: try RecordCoding.encoder().encode(requestID), as: UTF8.self)
            let encodedWire = String(decoding: try RecordCoding.encoder().encode(wire), as: UTF8.self)
            let subtitle = metadata["subtitle"].stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let risk = metadata["riskLevel"].stringValue == "high" ? L10n.text("较高风险", "Elevated Risk") : nil
            let detail = [risk, subtitle.flatMap { $0.isEmpty ? nil : $0 }, app].compactMap { $0 }.joined(separator: "\n\n")
            let request = PermissionRequest(
                id: "codex-desktop-permission:\(RecordCoding.hash([threadID, ownerClientID, encodedID, encodedWire]))", source: .codex,
                vendor: "Codex", sessionID: threadID, toolName: "computer_use_app",
                summary: L10n.text("允许 ChatGPT 使用 \(name)？", "Allow ChatGPT to use \(name)?"),
                detail: detail, cwd: state["cwd"].stringValue,
                nativeApproval: .computerUseApp(persist: persist), at: now)
            return Pending(request: request, threadID: threadID, ownerClientID: ownerClientID,
                           wireRequest: wire, requestID: requestID)
        }
        return try approvals + CodexDesktopQuestions.pending(state, threadID: threadID,
                                                            ownerClientID: ownerClientID, now: now)
    }

    static func response(_ decision: PermissionDecision, for pending: Pending) throws -> JSONValue? {
        if case .asynchronousQuestion = pending.request.nativeApproval {
            switch decision {
            case .leave: return nil
            case .answer(let answers):
                guard let question = pending.request.questions.first,
                      answers.keys.allSatisfy({ $0 == question.answerKey }) else { throw Failure.unsupportedDecision }
                guard let answer = answers[question.answerKey] else { return nil }
                guard answer.selected.allSatisfy({ choice in question.options.contains(where: { $0.label == choice }) }) else {
                    throw Failure.unsupportedDecision
                }
                let text = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw Failure.unsupportedDecision }
                let value = JSONValue.array([.object(["questionItemId": pending.requestID,
                    "question": .string(question.question), "answer": .string(text)])])
                let encoded = String(decoding: try RecordCoding.encoder().encode(value), as: UTF8.self)
                return .string("<send_user_message_question_reply>\n\(encoded)\n</send_user_message_question_reply>")
            case .allow, .allowAlways, .deny: throw Failure.unsupportedDecision
            }
        }
        guard case .computerUseApp(let persist) = pending.request.nativeApproval else { throw Failure.unsupportedDecision }
        switch decision {
        case .leave: return nil
        case .allow:
            guard persist.contains("session") else { throw Failure.unsupportedDecision }
            return .object(["action": .string("accept"), "content": .object([:]),
                            "_meta": .object(["persist": .string("session")])])
        case .allowAlways(let update):
            guard persist.contains("always"), update == .object(["persist": .string("always")]) else {
                throw Failure.unsupportedDecision
            }
            return .object(["action": .string("accept"), "content": .object([:]), "_meta": update])
        case .deny: return .object(["action": .string("decline"), "content": .null, "_meta": .null])
        case .answer: throw Failure.unsupportedDecision
        }
    }

    private static func json(_ object: [String: Any]) throws -> JSONValue {
        try JSONValue.parse(JSONSerialization.data(withJSONObject: object))
    }

    private static func foundation(_ value: JSONValue) throws -> Any {
        try JSONSerialization.jsonObject(with: RecordCoding.encoder().encode(value), options: [.fragmentsAllowed])
    }

    private func detached<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        let task = Task.detached(priority: .utility, operation: operation)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
