import AgentHUDCore
import Foundation
import SQLite3

/// What the agents keep about their sessions on this Mac, past the few the dock follows. It is read
/// here and never leaves here. Nothing is known about these beyond their records: anything alive
/// is already in the dock, which wins.
struct QuickInputLocalRecords: Equatable, Sendable {
    var sessions: [AgentDockSession] = []
    /// Directories those sessions worked in that still exist, most recently used first.
    var workspaces: [String] = []
}

actor QuickInputSessionIndex {
    static let shared = QuickInputSessionIndex()
    private static let claudeLimit = 500, rowLimit = "2000"
    private struct ClaudeRecord { let modified: Date; let size: Int; let title: String?; let directory: String? }
    private let desktop = ClaudeDesktopSessions()
    private var claudeRecords: [String: ClaudeRecord] = [:]
    private var codexOrigins: [String: String] = [:]

    func read(home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> QuickInputLocalRecords {
        let claude = await claude(home: home)
        let sessions = (codex(directory: CodexLocator.dataDirectory) + claude + Self.hermes(home: home))
            .filter { $0.navigationURL != nil || QuickInputCatalog.path(of: $0).map(Self.exists) == true }
            .sorted { $0.observedAt > $1.observedAt }
        var seen = Set<String>()
        let workspaces = sessions.compactMap(QuickInputCatalog.path(of:)).filter { seen.insert($0).inserted && Self.exists($0) }
        return QuickInputLocalRecords(sessions: sessions, workspaces: workspaces)
    }

    private static func exists(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
    static func record(_ id: String, _ source: WorkSource, title: String, directory: String?, at date: Date, url: URL? = nil, resume: String?) -> AgentDockSession {
        var session = AgentDockSession(id: id, source: source, title: title, project: nil, status: "最近会话", running: false, tokensIn: 0, tokensOut: 0, cacheRead: 0,
                                       reply: nil, observedAt: date, navigationURL: url, resumeCommand: resume, workingDirectory: directory)
        session.historical = true
        return session
    }
    /// One line of a title that can be a whole first message.
    static func headline(_ text: String?) -> String? {
        guard let line = text?.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces), !line.isEmpty else { return nil }
        return String(line.prefix(120))
    }

    // MARK: Codex keeps every thread in one database, and which client began it in the thread's log.

    private func codex(directory: URL) -> [AgentDockSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        guard let database = files.filter({ $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" })
            .max(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) else { return [] }
        var found: [AgentDockSession] = []
        Self.query(database, "SELECT id, rollout_path, cwd, title, first_user_message, updated_at FROM threads WHERE archived = 0 AND source IN ('vscode', 'cli') ORDER BY updated_at DESC LIMIT " + Self.rowLimit) { row in
            guard let id = Self.text(row, 0), UUID(uuidString: id) != nil, let log = Self.text(row, 1), FileManager.default.fileExists(atPath: log),
                  let title = Self.headline(Self.text(row, 3)) ?? Self.headline(Self.text(row, 4)) else { return }
            let origin = codexOrigins[id] ?? Self.originator(ofLog: log)
            codexOrigins[id] = origin
            guard origin != "dsh-tui" else { return }
            found.append(Self.record(id, .codex, title: title, directory: Self.text(row, 2), at: Self.date(sqlite3_column_double(row, 5)),
                                     url: origin == "Codex Desktop" ? URL(string: "codex://threads/" + id) : nil, resume: "codex resume " + id))
        }
        return found
    }
    static func originator(ofLog path: String) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
        guard let start = head.range(of: "\"originator\":\"")?.upperBound, let end = head[start...].firstIndex(of: "\"") else { return "" }
        return String(head[start..<end])
    }

    // MARK: Claude keeps a transcript per session, whichever client began it; the desktop app adds its own record.

    private func claude(home: URL) async -> [AgentDockSession] {
        let manager = FileManager.default, keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let projects = home.appendingPathComponent(".claude/projects", isDirectory: true)
        let folders = (try? manager.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        var files = folders.flatMap { (try? manager.contentsOfDirectory(at: $0, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)) ?? [] }
            .filter { $0.pathExtension == "jsonl" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .compactMap { file -> (url: URL, modified: Date, size: Int)? in
                guard let values = try? file.resourceValues(forKeys: keys), let modified = values.contentModificationDate, let size = values.fileSize else { return nil }
                return (file, modified, size)
            }
        files.sort { $0.modified > $1.modified }
        files = Array(files.prefix(Self.claudeLimit))
        var records: [String: ClaudeRecord] = [:]
        for file in files {
            if let known = claudeRecords[file.url.path], known.modified == file.modified, known.size == file.size { records[file.url.path] = known; continue }
            let read = Self.claudeTranscript(file.url, size: file.size)
            records[file.url.path] = ClaudeRecord(modified: file.modified, size: file.size, title: read.title, directory: read.directory)
        }
        claudeRecords = records
        let ids = files.map { $0.url.deletingPathExtension().lastPathComponent }
        let targets = await desktop.targets(sessionIDs: Set(ids))
        var links: [String: URL] = [:]
        for (id, target) in targets { links[id] = await AgentHubDataController.navigationURL(target) }
        return zip(files, ids).compactMap { file, id in
            guard let record = records[file.url.path], let title = record.title else { return nil }
            return Self.record(id, .claude, title: title, directory: record.directory, at: file.modified, url: links[id], resume: "claude --resume " + id)
        }
    }
    /// The start says where it ran and what was asked first; titles can land anywhere and the last one
    /// counts, so the end is looked at too. A transcript can be far too long to read whole every time.
    static func claudeTranscript(_ file: URL, size: Int, window: Int = 64 * 1024) -> (title: String?, directory: String?) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return (nil, nil) }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: window)) ?? Data()
        var tail = Data()
        if size > window, (try? handle.seek(toOffset: UInt64(size - window))) != nil { tail = (try? handle.read(upToCount: window)) ?? Data() }
        let last = FastTranscriptParser.titles(in: tail), first = FastTranscriptParser.titles(in: head)
        var directory: String?, asked: String?
        for line in head.split(separator: 0x0A) {
            guard let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            directory = directory ?? (entry["cwd"] as? String)
            if asked == nil, entry["type"] as? String == "user", entry["isMeta"] as? Bool != true, entry["isSidechain"] as? Bool != true {
                asked = plainText((entry["message"] as? [String: Any])?["content"])
            }
            if directory != nil, asked != nil { break }
        }
        return (headline(last.custom ?? first.custom ?? last.generated ?? first.generated ?? asked), directory)
    }
    /// What the person typed, leaving out what the client wraps in tags of its own.
    private static func plainText(_ content: Any?) -> String? {
        let text = (content as? String) ?? (content as? [[String: Any]])?.first { $0["type"] as? String == "text" }?["text"] as? String
        return text?.hasPrefix("<") == true ? nil : text
    }

    // MARK: Hermes

    private static func hermes(home: URL) -> [AgentDockSession] {
        let folder = ProcessInfo.processInfo.environment["HERMES_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".hermes")
        var found: [AgentDockSession] = []
        query(folder.appendingPathComponent("state.db"), "SELECT id, title, cwd, MAX(started_at, COALESCE(ended_at, 0)) AS active FROM sessions WHERE parent_session_id IS NULL AND COALESCE(message_count, 0) > 0 ORDER BY active DESC LIMIT " + rowLimit) { row in
            guard let id = text(row, 0), let title = headline(text(row, 1)) else { return }
            found.append(record(id, .hermes, title: title, directory: text(row, 2), at: date(sqlite3_column_double(row, 3)), resume: "hermes --resume " + QuickInputRun.quote(id)))
        }
        return found
    }

    // MARK: SQLite

    private static func text(_ row: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(row, column).map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 }
    }
    /// Some record seconds and some milliseconds.
    private static func date(_ value: Double) -> Date { Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value) }
    /// A database whose writer has gone can have lost the files a read-only connection needs. The file alone is then what was committed.
    private static func query(_ file: URL, _ sql: String, row: (OpaquePointer) -> Void) {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        for (name, flags) in [(file.path, SQLITE_OPEN_READONLY), (file.absoluteString + "?immutable=1", SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)] {
            var database: OpaquePointer?, statement: OpaquePointer?
            defer { sqlite3_finalize(statement); sqlite3_close(database) }
            guard sqlite3_open_v2(name, &database, flags, nil) == SQLITE_OK, let database else { continue }
            sqlite3_busy_timeout(database, 100)
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { continue }
            var result = sqlite3_step(statement), rows = 0
            while result == SQLITE_ROW { row(statement); rows += 1; result = sqlite3_step(statement) }
            if rows > 0 || result == SQLITE_DONE { return }
        }
    }
}
