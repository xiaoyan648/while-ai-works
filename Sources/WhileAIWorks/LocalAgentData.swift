import AppKit
import Combine
import CryptoKit
import Darwin
import SQLite3
import AgentHUDCore
import AgentHUDSupport

/// Local adapters have their own task: a subscription refresh cannot delay their state.
@MainActor final class LocalAgentDataController {
    private let state: AppState
    private let reader = LocalAgentReader()
    private var task: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var revision = 0
    init(state: AppState) {
        self.state = state
        state.$selectedSources.combineLatest(state.$agentReplyPreviews).sink { [weak self] _, _ in
            DispatchQueue.main.async { self?.configure() }
        }.store(in: &subscriptions)
        state.installLocalAgentBridge = { source in LocalAgentInstallation.show(source: source, state: state) }
        configure()
    }
    private func configure() {
        revision += 1; task?.cancel()
        let generation = revision, sources = state.selectedSources.filter(\.isLocalAgent), previews = state.agentReplyPreviews
        state.agentDashboard.sessions.removeAll { $0.source.isLocalAgent && (!sources.contains($0.source) || !previews && $0.reply != nil) }
        state.localAgentCounts = state.localAgentCounts.filter { sources.contains($0.key) }
        state.localAgentNotices = state.localAgentNotices.filter { sources.contains($0.key) }
        guard !sources.isEmpty else { return }
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let snapshot = await reader.read(sources: sources, previews: previews)
                guard !Task.isCancelled, generation == revision else { return }
                var data = state.agentDashboard
                data.sessions.removeAll { $0.source.isLocalAgent }
                data.sessions += snapshot.sessions
                for source in [WorkSource.hermes, .dsh] { data.notices[source] = snapshot.notices[source] }
                if data != state.agentDashboard { state.agentDashboard = data }
                if state.localAgentCounts != snapshot.counts { state.localAgentCounts = snapshot.counts }
                if state.localAgentNotices != snapshot.notices { state.localAgentNotices = snapshot.notices }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            }
        }
    }
    func stop() { revision += 1; task?.cancel(); task = nil }
}

struct LocalAgentSnapshot {
    var sessions: [AgentDockSession] = []
    var counts: [WorkSource: Int] = [:]
    var notices: [WorkSource: String] = [:]
}

actor LocalAgentReader {
    let hermesRoot: URL
    let dshRoot: URL
    private let dsh: DeepSeekTranscriptStore
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, environment: [String: String] = ProcessInfo.processInfo.environment) {
        hermesRoot = environment["HERMES_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".hermes")
        dshRoot = DeepSeekLocator.dataDirectory(environment: environment, home: home)
        dsh = DeepSeekTranscriptStore(root: dshRoot.appendingPathComponent("sessions"))
    }
    func read(sources: Set<WorkSource>, previews: Bool, now: Date = Date()) async -> LocalAgentSnapshot {
        var result = LocalAgentSnapshot()
        if sources.contains(.hermes) {
            do {
                let value = try HermesLocalData.read(root: hermesRoot, previews: previews, now: now)
                result.sessions += value.sessions; result.counts[.hermes] = value.counts[.hermes] ?? 0
                result.notices[.hermes] = value.notices[.hermes]
            } catch { result.notices[.hermes] = "Hermes 本地记录暂不可读" }
        }
        if sources.contains(.dsh) {
            await dsh.fileChanges(nil)
            let indexed = await dsh.index(since: now.addingTimeInterval(-7 * 86400))
            let locks = await LocalAgentProcess.ownedLocks(indexed.sessions.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().appendingPathComponent("session.lock").path })
            for item in indexed.sessions {
                let t = item.transcript
                guard let raw = t.id else { continue }
                let id = "deepseek:" + raw, turn = t.sessionTurns.last
                let locked = locks.contains(URL(fileURLWithPath: item.path).deletingLastPathComponent().appendingPathComponent("session.lock").path)
                // A turn remains active during quiet work only while its session has a live lock owner.
                let running = t.isLive(processStarts: locked ? nil : [])
                let hook = LocalAgentBridgeRecord.read(source: .dsh, rawID: raw, root: dshRoot, now: now)
                let finished = turn?.state == .completed || (t.isSubagent && hook?.completed == true)
                let waiting = hook?.waiting == true && hook?.live == true
                let event: AgentSessionEvent = waiting ? (hook?.question == true ? .input : .approval) : finished ? .finished : running ? .working : .recent
                result.sessions.append(.init(id: id, source: .dsh, title: t.title ?? "DSH 会话", project: t.cwd,
                    status: waiting ? "等你处理" : finished ? "已完成" : running ? "工作中" : "最近会话", running: running && !waiting,
                    tokensIn: t.inputTokens, tokensOut: t.outputTokens, cacheRead: t.cachedInputTokens,
                    reply: nil, observedAt: t.lastActivityAt ?? item.modifiedAt, navigationURL: nil,
                    resumeCommand: Self.resume(source: .dsh, id: raw, root: dshRoot), event: event,
                    eventAt: turn.map { Date(timeIntervalSince1970: Double($0.observedAtMs) / 1000) },
                    turnStartedAt: turn?.startedAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                    parentSessionID: hook?.parentID.map { "deepseek:" + $0 }))
            }
            result.counts[.dsh] = result.sessions.filter { $0.source == .dsh && $0.running && $0.parentSessionID == nil }.count
            result.notices[.dsh] = indexed.notice ?? (FileManager.default.fileExists(atPath: dshRoot.path) ? nil : "未找到 DSH 本地目录")
        }
        // Keep active and waiting rows, then recent history. Parentless children remain visible.
        let known = Set(result.sessions.map(\.dockIdentity))
        for i in result.sessions.indices {
            if let parent = result.sessions[i].parentSessionID, !known.contains(result.sessions[i].source.rawValue + ":" + parent) {
                result.sessions[i].parentSessionID = nil
            }
        }
        result.sessions.sort { $0.observedAt > $1.observedAt }
        return result
    }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func resume(source: WorkSource, id: String, root: URL) -> String? {
        guard !id.isEmpty, id.utf8.count < 1024, !id.contains("\n"), !id.contains("\0") else { return nil }
        return source == .hermes ? "HERMES_HOME=" + quote(root.path) + " hermes --resume " + quote(id)
            : "DSH_HOME=" + quote(root.path) + " dsh tui --resume " + quote(id)
    }
}

enum LocalAgentProcess {
    static func start(_ pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == getuid(), info.pbi_start_tvsec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }
    static func command(_ executable: String, arguments: [String], timeout: TimeInterval = 3) async -> Data? {
        await Task.detached(priority: .utility) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("waw-command-" + UUID().uuidString)
            let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { return nil }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close(); try? FileManager.default.removeItem(at: url) }
            let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            process.standardOutput = handle; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
            if process.isRunning { process.terminate(); return nil }
            guard (try? handle.seekToEnd()) ?? .max <= 256 * 1024 else { return nil }
            try? handle.seek(toOffset: 0)
            return try? handle.readToEnd()
        }.value
    }
    static func ownedLocks(_ paths: [String]) async -> Set<String> {
        let paths = Array(Set(paths)).filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return [] }
        // lsof's exact open file paths distinguish live session owners from unrelated Harness processes.
        guard let data = await command("/usr/sbin/lsof", arguments: ["-nP", "-a", "-u", String(getuid()), "-Fpn", "--"] + paths) else { return [] }
        var found = Set<String>(), valid = false
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if line.first == "p" { valid = Int32(line.dropFirst()).flatMap(start) != nil }
            if valid, line.first == "n", paths.contains(String(line.dropFirst())) { found.insert(String(line.dropFirst())) }
        }
        return found
    }
}

/// Short-lived metadata from installed client extensions. Never contains a conversation or an API key.
struct LocalAgentBridgeRecord {
    let raw: [String: Any]
    let live: Bool
    var waiting: Bool { raw["waiting"] as? Bool == true }
    var question: Bool { raw["question"] as? Bool == true }
    var running: Bool { raw["running"] as? Bool == true && live && !waiting }
    var completed: Bool { raw["completed"] as? Bool == true }
    var parentID: String? { raw["parent_session_id"] as? String }
    var at: Date { Date(timeIntervalSince1970: raw["updated_at"] as? Double ?? 0) }
    static func read(source: WorkSource, rawID: String, root: URL, now: Date) -> Self? {
        let filename = SHA256.hash(data: Data(rawID.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
        let file = root.appendingPathComponent("while-ai-works").appendingPathComponent(filename)
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 16_384,
              let data = try? Data(contentsOf: file), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["session_id"] as? String == rawID, let stamp = json["updated_at"] as? Double,
              stamp <= now.timeIntervalSince1970 + 60, now.timeIntervalSince1970 - stamp < 7 * 86400 else { return nil }
        let owner = (json["pid"] as? Int32).flatMap(LocalAgentProcess.start)
        let began = json["process_started_at"] as? Double
        let live = owner.map { date in began.map { abs($0 - date.timeIntervalSince1970) < 1.1 } ?? false }
        return Self(raw: json, live: live ?? false)
    }
}

/// Normal read-only SQLite transactions see active WAL records. No credentials or messages are selected.
enum HermesLocalData {
    static func roots(_ root: URL) -> [URL] {
        let profiles = (try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("profiles"), includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return [root] + profiles.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }
    static func read(root: URL, previews: Bool, now: Date) throws -> LocalAgentSnapshot {
        var result = LocalAgentSnapshot(), aggregate = 0
        for folder in roots(root) {
            let gateway = gatewayCount(folder: folder, now: now)
            aggregate += gateway
            let dbPath = folder.appendingPathComponent("state.db").path
            guard FileManager.default.fileExists(atPath: dbPath) else { continue }
            var db: OpaquePointer?
            guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
                if let db { sqlite3_close(db) }; throw CocoaError(.fileReadUnknown)
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 100)
            sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 2 * 1024 * 1024)
            // Bound work even if an older database lacks indexes. Do not hold up other clients.
            let deadline = UnsafeMutablePointer<Double>.allocate(capacity: 1)
            deadline.initialize(to: Date().addingTimeInterval(0.5).timeIntervalSince1970)
            sqlite3_progress_handler(db, 1000, { pointer in
                guard let pointer else { return 1 }
                return Date().timeIntervalSince1970 > pointer.assumingMemoryBound(to: Double.self).pointee ? 1 : 0
            }, deadline)
            defer { sqlite3_progress_handler(db, 0, nil, nil); deadline.deinitialize(count: 1); deadline.deallocate() }
            guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
            defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
            let columns = try rows(db, "PRAGMA table_info(sessions)").compactMap { $0["name"] as? String }
            let names = Set(columns)
            guard names.contains("id"), names.contains("started_at") else { throw CocoaError(.fileReadCorruptFile) }
            let wanted = ["id", "title", "cwd", "source", "started_at", "ended_at", "last_activity_at", "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens", "model_config"]
            let usageColumns = Set(try rows(db, "PRAGMA table_info(session_model_usage)").compactMap { $0["name"] as? String })
            let counts = Set(["input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens"])
            let selected = wanted.filter(names.contains).map { name in
                if counts.contains(name), usageColumns.contains("session_id"), usageColumns.contains(name) {
                    return "COALESCE((SELECT SUM(u." + name + ") FROM session_model_usage u WHERE u.session_id = sessions.id), " + name + ") AS " + name
                }
                return name
            }.joined(separator: ",")
            let activity = names.contains("last_activity_at") ? "COALESCE(last_activity_at, started_at)" : "started_at"
            for row in try rows(db, "SELECT \(selected) FROM sessions ORDER BY \(activity) DESC LIMIT 200") {
                guard let rawID = row["id"] as? String else { continue }
                let started = Date(timeIntervalSince1970: row["started_at"] as? Double ?? 0)
                let observed = Date(timeIntervalSince1970: row["last_activity_at"] as? Double ?? started.timeIntervalSince1970)
                guard observed > now.addingTimeInterval(-7 * 86400) else { continue }
                let profile = folder == root ? "" : folder.lastPathComponent + ":"
                let id = "hermes:" + profile + rawID
                let hook = LocalAgentBridgeRecord.read(source: .hermes, rawID: rawID, root: folder, now: now)
                let waiting = hook?.waiting == true && hook?.live == true, running = hook?.running == true
                let completed = hook?.completed == true
                var parent: String? = hook?.parentID
                if parent == nil, let config = row["model_config"] as? String,
                   let object = try? JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any] {
                    parent = object["_delegate_from"] as? String
                }
                func count(_ name: String) -> Int { max(0, Int(min(1e15, row[name] as? Double ?? 0))) }
                result.sessions.append(.init(id: id, source: .hermes, title: row["title"] as? String ?? "Hermes · " + (row["source"] as? String ?? "会话"),
                    project: row["cwd"] as? String, status: waiting ? "等你处理" : running ? "工作中" : completed ? "已完成" : "最近会话", running: running,
                    tokensIn: count("input_tokens") + count("cache_write_tokens"), tokensOut: count("output_tokens"), cacheRead: count("cache_read_tokens"),
                    reply: nil, observedAt: max(observed, hook?.at ?? observed), navigationURL: nil,
                    resumeCommand: LocalAgentReader.resume(source: .hermes, id: rawID, root: folder),
                    event: waiting ? (hook?.question == true ? .input : .approval) : completed ? .finished : running ? .working : .recent,
                    eventAt: hook?.at, parentSessionID: parent.map { "hermes:" + profile + $0 }))
            }
        }
        result.counts[.hermes] = max(aggregate, result.sessions.filter { $0.running && $0.parentSessionID == nil }.count)
        if !FileManager.default.fileExists(atPath: root.path) { result.notices[.hermes] = "未找到 Hermes 本地目录" }
        else if result.sessions.isEmpty && aggregate > 0 { result.notices[.hermes] = "Gateway 正在工作，尚无会话记录" }
        return result
    }
    static func gatewayCount(folder: URL, now: Date) -> Int {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("gateway_state.json")), data.count < 1024 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              ["running", "degraded"].contains(object["gateway_state"] as? String ?? ""),
              let pid = object["pid"] as? Int32, let start = LocalAgentProcess.start(pid),
              let fingerprint = object["start_time"] as? Double,
              abs(start.timeIntervalSince1970 * 100 - fingerprint) <= 2 else { return 0 }
        // Hermes defines busy by the live owner and active count, not by heartbeat age.
        return max(0, min(10000, object["active_agents"] as? Int ?? 0))
    }
    static func rows(_ db: OpaquePointer, _ sql: String) throws -> [[String: Any]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw CocoaError(.fileReadCorruptFile) }
        defer { sqlite3_finalize(stmt) }
        var result: [[String: Any]] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw CocoaError(.fileReadUnknown) }
            var row: [String: Any] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let key = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_TEXT: if let text = sqlite3_column_text(stmt, i) { row[key] = String(cString: text) }
                case SQLITE_INTEGER, SQLITE_FLOAT: row[key] = sqlite3_column_double(stmt, i)
                default: break
                }
            }
            result.append(row)
        }
    }
}
