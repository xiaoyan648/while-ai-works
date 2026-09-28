import Foundation
import Combine
import WhileCore

/// Reads Codex lifecycle logs and sanitized Claude Code/Qoder/WorkBuddy hook snapshots locally.
final class CodexMonitor {
    private struct Cursor {
        var offset: UInt64 = 0
        var buffer = LineBuffer()
    }
    private let state: AppState
    private let queue = DispatchQueue(label: "work-state.codex", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var subscription: AnyCancellable?
    private var enabled = false
    private var sources: Set<WorkSource> = []
    // Main-thread revision rejects a queued result even if selection changes away and back.
    private var configurationRevision = 0
    private var revision = 0
    private struct HookPace {
        var counts: [String: Int] = [:]
        var pulses: [Date] = []
        var primed = false
    }
    private var hookPaces: [HookProvider: HookPace] = [:]
    private var cursors: [String: Cursor] = [:]
    private var activity = WorkActivity()
    private var pace = WorkPace()
    private var ticks = 0
    private var candidates: [URL] = []
    private var displaySessions: [DesktopWorkSession] = []
    private let root: URL
    private let hookDirectory: URL

    init(state: AppState, codexRoot: URL? = nil, hookDirectory: URL = HookBridge.directory) {
        self.state = state
        self.hookDirectory = hookDirectory
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        root = codexRoot ?? home.appendingPathComponent("sessions")
        subscription = Publishers.CombineLatest4(state.$followAI, state.$selectedSources, state.$desktopEnabled, state.$desktopPetEnabled)
            .sink { [weak self] followAI, selected, desktopEnabled, petEnabled in
            guard let self else { return }
            self.configurationRevision += 1
            let revision = self.configurationRevision
            self.queue.async { [weak self] in
                guard let self else { return }
                self.revision = revision
                let monitoring = (followAI && desktopEnabled) || petEnabled
                let next = monitoring ? selected : []
                // Keep unchanged clients' cursors and pace; toggling Qoder must not replay Codex.
                if !next.contains(.codex) || !self.sources.contains(.codex) {
                    self.ticks = 0
                    self.activity = WorkActivity()
                    self.pace = WorkPace()
                    self.cursors.removeAll()
                    self.candidates.removeAll()
                }
                self.hookPaces = self.hookPaces.filter { next.contains(WorkSource(rawValue: $0.key.rawValue)!) }
                self.sources = next
                self.enabled = monitoring
                self.poll()
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.5)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }
    deinit { timer?.cancel() }

    private func poll() {
        displaySessions = []
        var counts: [WorkSource: Int] = [:]
        var intensity = 0.0
        var details: [String] = []
        var sourceDetails: [WorkSource: String] = [:]
        if enabled {
            for source in WorkSource.allCases where sources.contains(source) {
                let result: (count: Int, intensity: Double, detail: String)
                if let provider = source.hookProvider { result = pollHooks(provider) }
                else { result = pollCodex() }
                counts[source] = result.count
                sourceDetails[source] = result.detail
                intensity += result.intensity
                if !result.detail.isEmpty { details.append(result.detail) }
            }
        }
        let working = counts.values.contains { $0 > 0 }
        let level = working ? min(1, max(0.12, intensity)) : 0
        let detail = sources.isEmpty ? "请选择要跟随的 AI" :
            (details.isEmpty ? "等待 AI 开始工作" : details.joined(separator: " · "))
        let sessions = displaySessions
        let revision = self.revision
        DispatchQueue.main.async { [weak self] in
            guard let self, self.configurationRevision == revision else { return }
            self.state.activeSessionCounts = counts
            self.state.workSourceDetails = sourceDetails
            self.state.desktopWorkSessions = sessions
            self.state.detectedWorking = working
            self.state.workIntensity = level
            self.state.monitorDetail = detail
        }
    }

    private func pollCodex() -> (count: Int, intensity: Double, detail: String) {
        let exists = FileManager.default.fileExists(atPath: root.path)
        if ticks % 4 == 0 { discover() }
        ticks += 1
        var readAny = false
        for url in candidates {
            let id = url.path
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            guard let end = try? handle.seekToEnd() else { continue }
            let fresh = cursors[id] != nil
            var cursor = cursors[id] ?? Cursor()
            if end < cursor.offset { cursor = Cursor(); activity.remove(sessionID: id) }
            // The initial tail is bounded. Ongoing reads are chunked, preserving partial lines.
            if cursors[id] == nil && end > 2_097_152 {
                cursor.offset = end - 2_097_152
                try? handle.seek(toOffset: cursor.offset)
                if let fragment = try? handle.read(upToCount: 2_097_152), let newline = fragment.firstIndex(of: 10) {
                    cursor.offset += UInt64(fragment.distance(from: fragment.startIndex, to: newline) + 1)
                }
            }
            guard (try? handle.seek(toOffset: cursor.offset)) != nil else { continue }
            // At most 4 MB per session per poll. Remaining bytes are consumed next time.
            if let data = try? handle.read(upToCount: 4_194_304), !data.isEmpty {
                cursor.offset += UInt64(data.count)
                for line in cursor.buffer.append(data) {
                    activity.consume(line: line, sessionID: id)
                    pace.consume(line: line, fresh: fresh, now: Date())
                }
            }
            cursors[id] = cursor
            readAny = true
        }
        // A crashed or disconnected process should not leave an endless work state.
        let now = Date()
        // Keep recently silent lifecycle records so fresh progress can wake them again.
        // Five minutes governs the displayed count; one day only bounds retained metadata.
        activity.expire(before: now.addingTimeInterval(-86400))
        let active = activity.active.filter { now.timeIntervalSince($0.value.updatedAt) < HookBridge.inactivityTimeout }
        displaySessions += active.sorted { $0.key < $1.key }.map {
            DesktopWorkSession(id: "codex:" + $0.key, source: .codex, phase: $0.value.phase)
        }
        let count = active.count
        let intensity = pace.intensity(now: now)
        let detail = !exists ? "未找到 Codex 本地会话" : (!readAny && !candidates.isEmpty ? "无法读取 Codex 工作状态" : "")
        return (count, count > 0 ? max(0.12, intensity) : 0, detail)
    }

    private func pollHooks(_ provider: HookProvider) -> (count: Int, intensity: Double, detail: String) {
        let now = Date()
        let sessions = HookBridge.sessions(provider: provider, directory: hookDirectory, now: now)
        var pace = hookPaces[provider] ?? HookPace()
        for (id, session) in sessions {
            if pace.primed, session.updatedAt > now.addingTimeInterval(-10) {
                let added = max(0, session.count - (pace.counts[id] ?? 0))
                pace.pulses.append(contentsOf: repeatElement(session.updatedAt, count: min(added, 24)))
            }
        }
        pace.counts = sessions.mapValues(\.count)
        pace.primed = true
        pace.pulses.removeAll { now.timeIntervalSince($0) > 15 }
        if pace.pulses.count > 240 { pace.pulses = Array(pace.pulses.suffix(240)) }
        hookPaces[provider] = pace
        let active = sessions.filter { $0.value.working }
        let source = WorkSource(rawValue: provider.rawValue)!
        displaySessions += active.sorted { $0.key < $1.key }.map {
            DesktopWorkSession(id: provider.rawValue + ":" + $0.key, source: source, phase: $0.value.phase ?? .running)
        }
        let count = active.count
        let intensity = count > 0 ? max(0.12, min(1, pace.pulses.reduce(0.0) {
            $0 + exp(-max(0, now.timeIntervalSince($1)) / 5)
        } / 12)) : 0
        return (count, intensity, sessions.isEmpty ? "等待 \(provider.title) 监听状态" : "")
    }

    private func discover() {
        let manager = FileManager.default
        // A resumed task keeps its original creation-date folder, even months later.
        // Discover by file modification time across all session folders. Only metadata
        // is scanned here; the recent-file cap and bounded incremental reads stay below.
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let files = manager.enumerator(at: root, includingPropertiesForKeys: keys,
                                       options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var found: [URL] = []
        while let url = files?.nextObject() as? URL {
            if url.pathExtension == "jsonl",
               (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                found.append(url)
            }
        }
        let recent = Set(found).compactMap { url -> (URL, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let date = values.contentModificationDate, date > Date().addingTimeInterval(-3600) else { return nil }
            return (url, date)
        }.sorted { $0.1 > $1.1 }.prefix(24).map(\.0)
        // Retain active older session paths, including sessions that cross midnight.
        candidates = Array(Set(recent + activity.active.keys.map { URL(fileURLWithPath: $0) }))
        let valid = Set(candidates.map(\.path))
        cursors = cursors.filter { valid.contains($0.key) }
    }
}
