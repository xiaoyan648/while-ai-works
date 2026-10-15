import AgentHUDSupport
import Foundation

/// The questions DeepSeek Harness's web host asks its user, read from the event stream it already serves on
/// loopback. Hosts exposing `host.describe` and `question/requested` replay pending questions on connect and
/// accept answers through the same host. Hosts using a different API remain on Harness's own surface.
public struct DeepSeekQuestions: Sendable {
    /// One waiting question, with everything answering it needs: the frame's `rpcId` is what `/api/respond`
    /// names, and the request's id is what the HUD's queue and this answer share.
    public struct Pending: Sendable {
        public let request: PermissionRequest
        public var id: String { request.id }
        let rpcID: String
        let port: Int
    }

    /// A host answering like Harness's web startup does: `version`, `provider` and `model` on a describe call.
    public struct Endpoint: Sendable, Equatable {
        let port: Int

        func json(_ method: String, body: ProviderJSON, http: ProviderHTTP, timeout: TimeInterval = 2) async throws -> ProviderJSON {
            try await post(Self.envelope(method, payload: body), http: http, timeout: timeout)
        }

        func post(_ body: ProviderJSON, http: ProviderHTTP, timeout: TimeInterval) async throws -> ProviderJSON {
            // Describe calls and answers both POST /api/<name>; an answer posts the client-response it already is.
            let path = body["type"].stringValue == "client-response" ? "respond" : "host.describe"
            return try await http.json(URL(string: "http://127.0.0.1:\(port)/api/\(path)")!,
                                       headers: ["Host": "127.0.0.1"], body: body, timeout: timeout)
        }

        static func envelope(_ method: String, payload: ProviderJSON) -> ProviderJSON {
            .object([
                "type": .string("client-request"), "rpcId": .string(RecordCoding.hash([method])),
                "method": .string(method), "payload": payload,
            ])
        }

        /// The frame carries the RPC result; a host that is not Harness's web startup has none of its fields.
        static func value(_ reply: ProviderJSON) throws -> ProviderJSON {
            guard reply["type"].stringValue == "server-response", let result = reply["result"].objectValue else {
                throw ProviderFailure.format
            }
            guard result["ok"]?.boolValue == true else { throw Failure.notHarness }
            return result["value"] ?? .object([:])
        }

        static func describe(_ reply: ProviderJSON) throws -> Bool {
            let value = try Self.value(reply)
            return value["version"].stringValue != nil
                && (value["provider"].stringValue != nil || value["model"].stringValue != nil)
        }
    }

    /// A `server-request` frame off the event stream, or nothing when it is not a question.
    struct Frame: Equatable {
        let rpcID: String
        let sessionID: String
        let questions: [PermissionQuestion]

        static func read(_ json: ProviderJSON) -> Frame? {
            guard json["type"].stringValue == "server-request",
                  json["method"].stringValue == Self.method,
                  let rpcID = json["rpcId"].stringValue, !rpcID.isEmpty else { return nil }
            let payload = json["payload"]
            guard let sessionID = payload["sessionId"].stringValue, !sessionID.isEmpty else { return nil }
            // Harness files answers under the caller's stable question id. Display text is not an identity;
            // two questions can have the same wording. Plans and supporting detail stay on the native surface,
            // where the user can read what the decision is about before answering.
            guard let items = payload["questions"].arrayValue, !items.isEmpty else { return nil }
            var ids: Set<String> = []
            var questions: [PermissionQuestion] = []
            for item in items {
                guard let id = item["id"].stringValue,
                      !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      ids.insert(id).inserted,
                      item["intent"]["kind"].stringValue != "plan-review",
                      item["detail"].stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
                      let question = PermissionQuestion.read(.array([item])).first else { return nil }
                questions.append(question)
            }
            return Frame(rpcID: rpcID, sessionID: sessionID, questions: questions)
        }

        static let method = "question/requested"
    }

    var http = ProviderHTTP()

    public init() {}

    /// Posts an envelope to a port's API and unwraps the reply. A body already carrying the client-response shape
    /// goes up as written; a method call is wrapped in the client-request envelope.
    func send(_ body: ProviderJSON, to endpoint: Endpoint, timeout: TimeInterval = 4) async throws -> ProviderJSON {
        try await endpoint.post(body, http: http, timeout: timeout)
    }

    func send(_ body: ProviderJSON, port: Int, timeout: TimeInterval = 4) async throws -> ProviderJSON {
        try await send(body, to: Endpoint(port: port), timeout: timeout)
    }

    /// Asks the port whether the process listening there is a Harness web host. Any host answering the envelope
    /// with a result at all is one of Harness's; the fields decide it is one that asks questions.
    func describe(port: Int) async throws -> Bool {
        let endpoint = Endpoint(port: port)
        return try await Endpoint.describe(try await endpoint.json("host.describe", body: .object([:]), http: http))
    }

    /// The waiting question a frame carries, named after this endpoint and its RPC.
    static func requestID(port: Int, rpcID: String) -> String { "deepseek:\(port):\(rpcID)" }

    static func pending(_ frame: Frame, port: Int, now: Date) -> Pending {
        let questions: [ProviderJSON] = frame.questions.map { question in
            .object([
                "id": .string(question.answerKey),
                "question": .string(question.question),
                "header": question.header.map { .string($0) } ?? .null,
                "options": .array(question.options.map { option in
                    .object(["label": .string(option.label),
                             "description": option.description.map { .string($0) } ?? .null])
                }),
                "multiSelect": .bool(question.multiSelect),
            ])
        }
        let input: ProviderJSON = .object(["questions": .array(questions)])
        let request = PermissionRequest(
            id: requestID(port: port, rpcID: frame.rpcID), source: .deepseek,
            sessionID: PermissionHooks.Source.deepseek.sessionID(frame.sessionID),
            toolName: PermissionQuestion.tool,
            summary: frame.questions.first?.question ?? "",
            detail: nil, cwd: nil,
            questions: frame.questions, questionInput: input, at: now
        )
        return Pending(request: request, rpcID: frame.rpcID, port: port)
    }

    /// The user's answer in the shape `/api/respond` files: each question's offered labels under `selected`, its
    /// `custom` beside them, a question the user skipped left with an empty `selected`. The answers arrive keyed by
    /// Harness's original question ids, with choices and free text kept separate all the way from the card.
    static func answer(_ decision: PermissionDecision, for pending: Pending) throws -> ProviderJSON {
        guard case .answer(let answers) = decision else { throw Failure.unsupportedDecision }
        var entries: [ProviderJSON] = []
        for question in pending.request.questions {
            let given = answers[question.answerKey] ?? PermissionQuestion.Answer()
            var entry: [String: ProviderJSON] = [
                "id": .string(question.answerKey),
                "selected": .array(given.selected.map { .string($0) }),
            ]
            if let custom = given.custom { entry["custom"] = .string(custom) }
            entries.append(.object(entry))
        }
        return .object([
            "type": .string("client-response"), "rpcId": .string(pending.rpcID),
            "result": .object(["ok": .bool(true), "value": .object([
                "sessionId": .string(String(pending.request.sessionID.dropFirst("deepseek:".count))),
                "answer": .object(["answers": .array(entries)]),
            ])]),
        ])
    }

    /// A confirmed receipt is terminal only when the host took the answer or explicitly says the question ended.
    enum Receipt: Equatable, Sendable {
        case accepted, notPending
    }

    static func receipt(_ reply: ProviderJSON) throws -> Receipt {
        let value = try Endpoint.value(reply)
        if value["accepted"].boolValue == true { return .accepted }
        if value["accepted"].boolValue == false, value["reason"].stringValue == "not-pending" { return .notPending }
        throw ProviderFailure.format
    }

    /// Whether the host took this answer; a malformed or unknown rejection does not settle the HUD's card.
    static func accepted(_ reply: ProviderJSON) -> Bool {
        (try? receipt(reply)) == .accepted
    }

    enum Failure: LocalizedError {
        case notHarness, unsupportedDecision
        var errorDescription: String? {
            switch self {
            case .notHarness: L10n.text("该端口上没有 DeepSeek Harness 的提问服务", "DeepSeek Harness's question service is not on that port")
            case .unsupportedDecision: L10n.text("DeepSeek Harness 的提问只能回答，不能批准", "DeepSeek Harness's questions can only be answered, not approved")
            }
        }
    }
}
