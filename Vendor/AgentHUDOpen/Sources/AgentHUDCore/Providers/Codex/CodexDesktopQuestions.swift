import AgentHUDSupport
import Foundation

/// Desktop's asynchronous Question cards are agent-message questions, answered by a steering user message.
enum CodexDesktopQuestions {
    static func pending(_ state: JSONValue, threadID: String, ownerClientID: String,
                        now: Date) throws -> [CodexDesktopPermissions.Pending] {
        // Desktop selects the latest in-progress turn, which can precede a later completed turn.
        guard let turn = try turns(state).last(where: { $0["status"].stringValue == "inProgress" }),
              let turnID = turn["turnId"].stringValue, !turnID.isEmpty else { return [] }
        let items = turn["items"].arrayValue ?? []
        let answered = Set(items.flatMap(answeredQuestionIDs))
        var pending: [CodexDesktopPermissions.Pending] = []
        for item in items {
            guard item["type"].stringValue == "agentMessage",
                  let sourceID = item["id"].stringValue, !sourceID.isEmpty,
                  let questions = item["questions"].arrayValue else { continue }
            for (index, rawQuestion) in questions.enumerated() {
                guard let title = rawQuestion["title"].stringValue,
                      !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let labels: [String]
                if rawQuestion["options"] == .null {
                    labels = []
                } else {
                    guard let options = rawQuestion["options"].arrayValue,
                          options.allSatisfy({ $0.stringValue != nil }) else { continue }
                    labels = options.compactMap(\.stringValue)
                }
                let identity = JSONValue.array([.string("request_user_input_async"), .string(sourceID),
                                                .integer(Int64(index))])
                let questionID = String(decoding: try RecordCoding.encoder().encode(identity), as: UTF8.self)
                guard !answered.contains(questionID) else { continue }
                let wire: JSONValue = .object([
                    "turnId": .string(turnID), "sourceItemId": .string(sourceID),
                    "questionIndex": .integer(Int64(index)), "question": rawQuestion,
                ])
                let encodedWire = String(decoding: try RecordCoding.encoder().encode(wire), as: UTF8.self)
                let request = PermissionRequest(
                    id: "codex-desktop-question:\(RecordCoding.hash([threadID, ownerClientID, encodedWire]))",
                    source: .codex, vendor: "Codex", sessionID: threadID,
                    toolName: "request_user_input_async", summary: title, detail: nil,
                    cwd: state["cwd"].stringValue,
                    questions: [PermissionQuestion(id: questionID, question: title,
                                                   options: labels.map { .init(label: $0) })],
                    nativeApproval: .asynchronousQuestion(turnID: turnID), at: now)
                pending.append(.init(request: request, threadID: threadID, ownerClientID: ownerClientID,
                                     wireRequest: wire, requestID: .string(questionID)))
            }
        }
        return pending
    }

    /// The owner steers its latest real turn, or an unfinished placeholder awaiting a turn ID.
    static func currentTurnID(_ state: JSONValue) throws -> String? {
        // Desktop's current-turn selector reads the canonical store itself, rather than its display overlay.
        try turns(state, includeOverlay: false).last(where: {
            $0["turnId"] != .null || ($0["status"].stringValue != "completed" && $0["status"].stringValue != "failed")
        })?["turnId"].stringValue
    }

    private static func turns(_ state: JSONValue, includeOverlay: Bool = true) throws -> [JSONValue] {
        guard let fields = state.objectValue else { throw CodexDesktopIPC.Failure.protocolError }
        let overlay: [JSONValue]
        if let value = fields["turns"] {
            guard let values = value.arrayValue, values.allSatisfy({ $0.objectValue != nil }) else {
                throw CodexDesktopIPC.Failure.protocolError
            }
            overlay = values
        } else {
            // Permission-only snapshots and fixtures do not carry any turn store.
            overlay = []
        }
        guard let storage = fields["turnHistory"], storage != .null else { return overlay }
        guard storage.objectValue != nil else { throw CodexDesktopIPC.Failure.protocolError }
        guard storage["kind"].stringValue == "canonical" else { return overlay }
        let history = storage["history"]
        guard let islands = history["islands"].arrayValue,
              let entities = history["entitiesByKey"].objectValue else { throw CodexDesktopIPC.Failure.protocolError }
        var canonical: [JSONValue] = []
        for island in islands {
            guard let entries = island["entries"].arrayValue else { throw CodexDesktopIPC.Failure.protocolError }
            for entry in entries {
                guard let key = entry["value"].stringValue, let turn = entities[key], turn.objectValue != nil else {
                    throw CodexDesktopIPC.Failure.protocolError
                }
                canonical.append(turn)
            }
        }
        // Desktop's canonical store normally clears legacy turns. Disjoint overlay turns append in its merge;
        // overlapping stores need Desktop's full rendering merge, so they cannot safely establish withdrawal here.
        let canonicalIDs = Set(canonical.compactMap { $0["turnId"].stringValue })
        guard !overlay.contains(where: { $0["turnId"].stringValue.map(canonicalIDs.contains) == true }) else {
            throw CodexDesktopIPC.Failure.protocolError
        }
        return includeOverlay ? canonical + overlay : canonical
    }

    private static func answeredQuestionIDs(_ item: JSONValue) -> [String] {
        let content: JSONValue
        switch item["type"].stringValue {
        case "userMessage": content = item["content"]
        case "steeringUserMessage" where item["status"].stringValue == "accepted": content = item["input"]
        default: return []
        }
        guard let parts = content.arrayValue, parts.count == 1, parts[0]["type"].stringValue == "text",
              let text = parts[0]["text"].stringValue else { return [] }
        let opening = "<send_user_message_question_reply>", closing = "</send_user_message_question_reply>"
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(opening), trimmed.hasSuffix(closing) else { return [] }
        let payload = trimmed.dropFirst(opening.count).dropLast(closing.count)
        guard let value = try? JSONValue.parse(Data(payload.utf8)) else { return [] }
        let answers: [JSONValue]
        if let array = value.arrayValue, !array.isEmpty { answers = array }
        else if value.objectValue != nil { answers = [value] }
        else { return [] }
        // Desktop rejects the entire envelope when any answer lacks its required string fields.
        guard answers.allSatisfy({
            $0["questionItemId"].stringValue != nil && $0["question"].stringValue != nil && $0["answer"].stringValue != nil
        }) else { return [] }
        return answers.compactMap { $0["questionItemId"].stringValue }
    }
}
