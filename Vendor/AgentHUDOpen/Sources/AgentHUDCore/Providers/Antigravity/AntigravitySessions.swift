import AgentHUDSupport
import Foundation
import SQLite3

enum AntigravitySessions: LocalSessionLayout {
    static let installPaths = [".gemini/antigravity", ".gemini/antigravity-cli", "Applications/Antigravity.app"]

    /// The Gemini home agy keeps its conversations and hooks in: `GEMINI_CLI_HOME`, else `~/.gemini`. Its reader and the
    /// completion hook written into it both follow it.
    static func home(_ home: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        ClientHome.variable("GEMINI_CLI_HOME", in: environment).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".gemini", isDirectory: true)
    }

    static func roots(home: URL, environment: [String: String]) -> [URL] {
        let base = self.home(home, environment: environment)
        return ["antigravity-cli/conversations", "antigravity", "antigravity/conversations"].map { base.appendingPathComponent($0) }
    }

    static func accepts(_ url: URL) -> Bool {
        url.pathExtension == "db" && url.lastPathComponent != "conversation_summaries.db"
    }

    /// The recognized SQLite roots are flat; configuration, summaries and storage beside the conversations are not scanned.
    static func skips(_ url: URL) -> Bool { !accepts(url) }

    static func related(_ url: URL) -> [URL] { [URL(fileURLWithPath: url.path + "-wal"), annotations(url)] }

    /// agy's annotations of a conversation, beside the conversations folder: the title it generates when the
    /// conversation starts, which a rename from its `/resume` list replaces. Headless runs get none.
    static func annotations(_ url: URL) -> URL {
        url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("annotations")
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent).appendingPathExtension("pbtxt")
    }

    static func title(_ url: URL) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64 * 1024,
              let data = try? Data(contentsOf: url) else { return nil }
        return SessionTitle.named(textField("title", in: [UInt8](data)))
    }

    /// A string field of a protobuf text-format message, with the format's escapes decoded.
    static func textField(_ name: String, in bytes: [UInt8]) -> String? {
        let key = [UInt8](name.utf8), spaces: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        var start = 0
        while let range = bytes[start...].firstRange(of: key) {
            start = range.upperBound
            // The field name starts a token and is followed by a colon and a quoted string.
            guard range.lowerBound == 0 || spaces.contains(bytes[range.lowerBound - 1]) || bytes[range.lowerBound - 1] == UInt8(ascii: "{") else { continue }
            var index = range.upperBound
            while index < bytes.count, spaces.contains(bytes[index]) { index += 1 }
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { continue }
            index += 1
            while index < bytes.count, spaces.contains(bytes[index]) { index += 1 }
            guard index < bytes.count, let quote = [UInt8(ascii: "\""), UInt8(ascii: "'")].first(where: { $0 == bytes[index] }) else { continue }
            index += 1
            var value: [UInt8] = []
            while index < bytes.count, bytes[index] != quote {
                guard bytes[index] == UInt8(ascii: "\\"), index + 1 < bytes.count else { value.append(bytes[index]); index += 1; continue }
                index += 1
                func number(radix: Int, digits: Int) -> UInt32? {
                    var code: UInt32 = 0, count = 0
                    while count < digits, index < bytes.count, let digit = Int(String(UnicodeScalar(bytes[index])), radix: radix) {
                        code = code * UInt32(radix) + UInt32(digit); index += 1; count += 1
                    }
                    return count > 0 ? code : nil
                }
                switch bytes[index] {
                case UInt8(ascii: "n"): value.append(0x0A); index += 1
                case UInt8(ascii: "r"): value.append(0x0D); index += 1
                case UInt8(ascii: "t"): value.append(0x09); index += 1
                case UInt8(ascii: "0")...UInt8(ascii: "7"): value.append(UInt8(truncatingIfNeeded: number(radix: 8, digits: 3) ?? 0))
                case UInt8(ascii: "x"): index += 1; value.append(UInt8(truncatingIfNeeded: number(radix: 16, digits: 2) ?? 0))
                case UInt8(ascii: "u"), UInt8(ascii: "U"):
                    let digits = bytes[index] == UInt8(ascii: "u") ? 4 : 8
                    index += 1
                    if let scalar = number(radix: 16, digits: digits).flatMap(UnicodeScalar.init) { value += Array(String(Character(scalar)).utf8) }
                default: value.append(bytes[index]); index += 1
                }
            }
            return String(decoding: value, as: UTF8.self)
        }
        return nil
    }

    static func read(_ url: URL) throws -> ProviderSessions {
        let database = try ReadOnlySQLite(url)
        try database.requireTable("gen_metadata")
        var rows: [(index: Int64, turn: AntigravityProtoReader.ParsedTurn)] = [], incomplete = false
        try database.rows("SELECT idx, data FROM gen_metadata NOT INDEXED") { row in
            guard sqlite3_column_type(row, 0) == SQLITE_INTEGER, let bytes = ReadOnlySQLite.blob(row, 1),
                  let turn = try AntigravityProtoReader.parseTurn(Array(bytes), checkCancellation: { try Task.checkCancellation() }) else {
                incomplete = true; return
            }
            rows.append((sqlite3_column_int64(row, 0), turn))
        }
        var steps: [AntigravityProtoReader.StepMetadata] = []
        if rows.contains(where: { $0.turn.usage?.hasTokens == true && $0.turn.timestampMs == nil }), (try? database.requireTable("steps")) != nil {
            try database.rows("SELECT metadata FROM steps NOT INDEXED") { row in
                guard let bytes = ReadOnlySQLite.blob(row, 0), let step = try AntigravityProtoReader.parseStepMetadata(Array(bytes)) else {
                    incomplete = true; return
                }
                steps.append(step)
            }
        }
        let id = "antigravity:\(url.deletingPathExtension().lastPathComponent)"
        let client = url.path.contains("antigravity-cli/") ? "Antigravity CLI" : "Antigravity"
        var session = ProviderSession(id: id, title: title(annotations(url)) ?? "\(client) · \(url.deletingPathExtension().lastPathComponent.prefix(8))",
                                      path: url.path, client: client)
        var identities: [String: ProviderEvent] = [:]
        let labels = Dictionary(grouping: rows.map(\.turn).filter { $0.label != nil && $0.model != nil }, by: { $0.label! })
            .mapValues { Set($0.compactMap(\.model)) }
        for row in rows {
            let turn = row.turn
            // Failed and unfinished generations can record only the model enum, with no token usage yet.
            guard let usage = turn.usage, usage.hasTokens else { continue }
            let timestamp = turn.timestampMs ?? matchedTimestamp(turn, generations: rows.map(\.turn), steps: steps)
            guard let timestamp else { incomplete = true; continue }
            let (input, overflowIn) = usage.input.addingReportingOverflow(usage.cacheWrite)
            guard !overflowIn else { throw ProviderFailure.format }
            let mapped = turn.label.flatMap { labels[$0] }.flatMap { $0.count == 1 ? $0.first : nil }
            let enumModel = (usage.modelID ?? turn.requestedModelID).flatMap { $0 > 0 ? "Antigravity model \($0)" : nil }
            let model = turn.model ?? mapped ?? turn.label ?? enumModel ?? "Unknown"
            let identity = id + ":" + (usage.responseID ?? "row-\(row.index)")
            // output_tokens is the total; thinking/response counters are its parts, not additional output.
            let event = ProviderEvent(id: identity, model: model, timestamp: RecordCoding.date(timestamp), input: input,
                                      output: usage.output, cacheRead: usage.cacheRead, cacheWrite: usage.cacheWrite,
                                      reasoning: usage.thinkingOutput)
            if let previous = identities[identity], previous != event { incomplete = true }
            else { identities[identity] = event }
        }
        session.events = identities.values.sorted { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }
        return ProviderSessions(sessions: [session], notice: incomplete
            ? L10n.text("部分 Antigravity 记录缺少可验证的时间或用量，未计入统计", "Some Antigravity records lack verifiable timestamps or usage and were excluded") : nil)
    }

    /// Only exact, unique joins are accepted. Context-window metadata and file modification times are never usage times.
    static func matchedTimestamp(_ turn: AntigravityProtoReader.ParsedTurn,
        generations: [AntigravityProtoReader.ParsedTurn], steps: [AntigravityProtoReader.StepMetadata]) -> Int64? {
        if let message = turn.usage?.messageID {
            guard generations.filter({ $0.usage?.messageID == message }).count == 1 else { return nil }
            let matches = steps.filter { $0.messageID == message }
            guard matches.count == 1, let step = matches.first,
                  turn.executionID == nil || step.executionID == turn.executionID else { return nil }
            return step.timestampMs
        }
        guard let execution = turn.executionID, generations.filter({ $0.executionID == execution }).count == 1 else { return nil }
        let matches = steps.filter { $0.executionID == execution }
        return matches.count == 1 ? matches.first?.timestampMs : nil
    }
}
