import Foundation
import SQLite3

/// The visible prompts and final replies in Antigravity's own conversation database. This is an explicit conversation
/// read, separate from the usage reader: reasoning, tool arguments/results and generated context never leave the file.
public enum AntigravityConversation {
    /// Latest user turns at or after `since`, at most `limit`, oldest first. The session is the database's own identity,
    /// with the usage reader's `antigravity:` prefix accepted. Pages share one committed SQLite/WAL read transaction.
    public static func turns(atPath path: String, sessionID: String, since: Date, limit: Int) -> [ConversationTurn] {
        let file = URL(fileURLWithPath: path)
        let id = sessionID.hasPrefix("antigravity:") ? String(sessionID.dropFirst("antigravity:".count)) : sessionID
        guard limit > 0, file.pathExtension == "db", !id.isEmpty,
              file.deletingPathExtension().lastPathComponent == id else { return [] }
        return (try? read(file, since: since, limit: limit)) ?? []
    }

    private struct Step {
        let index: Int64
        let kind: Int
        let status: Int
        let created: Date?
        let completed: Date?
        var text: String?
        var stopReason: Int = 0
        var hasTools = false
    }

    private struct Open {
        let id: String
        let prompt: String
        let started: Date
        var reply: String?
        var lastText: String?
        var ended: Date?
    }

    /// The installed 2.21.1 codeium_common_pb.StopReason descriptor, including its deprecated values.
    private enum StopReason: Int {
        case unspecified = 0, incomplete, stopPattern, maxTokens, minLogProbability, maxNewlines, exitScope
        case nonfiniteLogit, firstNonWhitespaceLine, partial, functionCall, contentFilter, nonInsertion
        case error, improperFormat, other, clientCanceled, toolParseError, streamError, looping, invalidMessageOrder

        var endsTurn: Bool {
            switch self {
            case .unspecified, .incomplete, .partial, .functionCall: false
            default: true
            }
        }
    }

    private static func read(_ file: URL, since: Date, limit: Int) throws -> [ConversationTurn] {
        let database = try ReadOnlySQLite(file)
        try database.requireTable("steps")
        var steps: [Step] = [], cursor: Int64?, prompts = 0, done = false
        // Tool steps are not conversation messages. Reading backwards stops at the requested prompt rather than
        // truncating a long file before its latest turns, or loading all of its historical tool payloads.
        while !done {
            let before = cursor.map { " AND idx < \($0)" } ?? ""
            var rows = 0
            try database.rows("SELECT idx, step_type, status, metadata, step_payload, step_format FROM steps NOT INDEXED "
                + "WHERE step_type IN (2, 14, 15) AND status NOT IN (4, 5)\(before) ORDER BY idx DESC LIMIT 256") { row in
                rows += 1
                guard !done else { return }
                guard sqlite3_column_type(row, 0) == SQLITE_INTEGER,
                      sqlite3_column_int(row, 5) == 0 else { throw ProviderFailure.format }
                let index = sqlite3_column_int64(row, 0)
                cursor = index
                let kind = Int(sqlite3_column_int(row, 1)), status = Int(sqlite3_column_int(row, 2))
                let time = try metadata(ReadOnlySQLite.blob(row, 3).map(Array.init) ?? [])
                if kind == 14, let created = time.created, created < since { done = true; return }
                var step = Step(index: index, kind: kind, status: status, created: time.created, completed: time.completed)
                if kind != 2 {
                    guard let payload = ReadOnlySQLite.blob(row, 4) else { throw ProviderFailure.format }
                    try content(Array(payload), into: &step)
                }
                steps.append(step)
                if kind == 14, step.text != nil, let created = time.created, created >= since {
                    prompts += 1
                    if prompts >= limit { done = true }
                }
            }
            if rows == 0 { break }
        }
        return assemble(steps.reversed(), since: since, limit: limit)
    }

    private static func assemble(_ steps: ReversedCollection<[Step]>, since: Date, limit: Int) -> [ConversationTurn] {
        var turns: [ConversationTurn] = [], open: Open?
        func close(at date: Date?) {
            guard let current = open else { return }
            let ended = current.ended ?? date.flatMap { $0 >= current.started ? $0 : nil }
            turns.append(ConversationTurn(turnID: current.id, prompt: current.prompt,
                reply: current.reply ?? (ended == nil ? nil : current.lastText), startedAt: current.started, endedAt: ended))
            open = nil
        }
        for step in steps {
            switch step.kind {
            case 14:
                // Another user message establishes a new boundary, not a recorded completion of the old turn.
                close(at: nil)
                if let text = step.text, let created = step.created {
                    open = Open(id: "step-\(step.index)", prompt: text, started: created)
                }
            case 15:
                guard open != nil else { continue }
                if let text = step.text { open?.lastText = text }
                // A completed model generation that requested tools is still inside its user's turn. StopPattern,
                // token limits, filtering and terminal failures are ends; Incomplete, Partial and FunctionCall are not.
                let stopped = StopReason(rawValue: step.stopReason)?.endsTurn == true
                let terminal = [6, 7, 12].contains(step.status)
                    || (step.status == 3 && stopped && !step.hasTools)
                if terminal {
                    let reply = step.text ?? open?.lastText
                    open?.reply = reply
                    if let ended = step.completed, ended >= open!.started { open?.ended = ended }
                }
            case 2:
                close(at: step.completed ?? step.created)
            default: break
            }
        }
        close(at: nil)
        return Array(turns.filter { $0.startedAt >= since }.suffix(limit))
    }

    /// The stored payload is a complete CortexStep: UserInput is field 19, PlannerResponse field 20. Field numbers and
    /// timestamps were verified in installed 2.21.1 descriptors and records. Its native UI displays response, not the
    /// deprecated modified_response, and prioritizes user_response over the ordered text items.
    private static func content(_ bytes: [UInt8], into step: inout Step) throws {
        var query: String?, response: String?, items: [String] = []
        try fields(bytes) { field in
            if step.kind == 14, field.number == 19 {
                try fields(Array(try field.message())) { input in
                    switch input.number {
                    case 1: query = try input.string()
                    case 2: response = try input.string()
                    case 3:
                        try fields(Array(try input.message())) { item in
                            if item.number == 1, let text = try item.string() { items.append(text) }
                        }
                    default: break
                    }
                }
            } else if step.kind == 15, field.number == 20 {
                try fields(Array(try field.message())) { reply in
                    switch reply.number {
                    case 1: step.text = try reply.string()
                    case 7: _ = try reply.message(); step.hasTools = true
                    case 12: step.stopReason = try reply.counter()
                    default: break
                    }
                }
            }
        }
        if step.kind == 14 { step.text = response ?? (items.isEmpty ? query : items.joined()) }
    }

    private static func metadata(_ bytes: [UInt8]) throws -> (created: Date?, completed: Date?) {
        var created: Date?, completed: Date?
        try fields(bytes) { field in
            if field.number == 1 { created = try timestamp(Array(try field.message())) }
            if field.number == 8 { completed = try timestamp(Array(try field.message())) }
        }
        return (created, completed)
    }

    private static func timestamp(_ bytes: [UInt8]) throws -> Date? {
        var seconds: UInt64?, nanos: UInt64 = 0
        try fields(bytes) { field in
            if field.number == 1 { seconds = try field.integer() }
            if field.number == 2 { nanos = try field.integer() }
        }
        guard let seconds else { return nil }
        guard seconds > 0, seconds <= 253_402_300_799, nanos <= 999_999_999 else { throw ProviderFailure.format }
        return Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000)
    }

    /// Uses the same wire reader as the account-usage metadata parser; there is no second protobuf decoder.
    private static func fields(_ bytes: [UInt8], visit: (AntigravityProtoReader.Field) throws -> Void) throws {
        var reader = AntigravityProtoReader(bytes: bytes)
        while let field = reader.nextField() {
            try Task.checkCancellation()
            try visit(field)
        }
        guard !reader.isMalformed else { throw ProviderFailure.format }
    }
}
