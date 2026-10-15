import Foundation

/// Reads Desktop's app approvals and unanswered mid-turn questions. Engine approvals continue through their hook.
@MainActor
public final class CodexDesktopPermissionObserver {
    private let requests: PermissionRequests
    private let client: CodexDesktopPermissions
    private var task: Task<Void, Never>?
    private var sessionIDs: Set<String> = []
    /// Retained across failed readings, so a disconnect does not settle a dismissed native prompt.
    private var pending: [String: CodexDesktopPermissions.Pending] = [:]
    /// Desktop builds a thread's whole history for every read: a third of a second of its CPU for a 33 MB thread.
    /// A thread therefore rests for this many times as long as its last read took, on the system's uptime.
    static let restFactor: TimeInterval = 10
    private var restsUntil: [String: TimeInterval] = [:]
    /// What the last pass showed. A resting thread is not asked, so its cards stand as they were.
    private var shown: [CodexDesktopPermissions.Pending] = []

    public init() {
        requests = .shared
        client = CodexDesktopPermissions()
    }

    init(requests: PermissionRequests, client: CodexDesktopPermissions) {
        self.requests = requests
        self.client = client
    }

    public func updateSessions(_ sessions: [LiveSession]) {
        sessionIDs = Self.threadIDs(in: sessions)
    }

    static func threadIDs(in sessions: [LiveSession]) -> Set<String> {
        Set(sessions.flatMap { [$0] + $0.descendantSessions }.compactMap { session in
            guard session.isLive, case .codexThread(let id) = session.navigationTarget else { return nil }
            return id
        })
    }

    public func setEnabled(_ enabled: Bool) {
        guard enabled else { return stop() }
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let ids = sessionIDs.union(pending.values.map(\.threadID))
                let due = due(ids, at: ProcessInfo.processInfo.systemUptime)
                do {
                    let snapshot = try await client.fetch(threadIDs: due)
                    try Task.checkCancellation()
                    reconcile(snapshot, resting: ids.subtracting(due))
                } catch {
                    if Task.isCancelled { return }
                    shown.removeAll()
                    requests.removeNativeRequests(source: .codex)
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    /// The threads a pass asks: those whose rest is over.
    func due(_ ids: Set<String>, at uptime: TimeInterval) -> Set<String> {
        restsUntil = restsUntil.filter { ids.contains($0.key) }
        return ids.filter { (restsUntil[$0] ?? 0) <= uptime }
    }

    func reconcile(_ snapshot: CodexDesktopPermissions.Snapshot, resting: Set<String> = [],
                   at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        for (threadID, seconds) in snapshot.readSeconds { restsUntil[threadID] = uptime + seconds * Self.restFactor }
        shown = (snapshot.pending + shown.filter { resting.contains($0.threadID) }).sorted { $0.id < $1.id }
        let current = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in pending.values where snapshot.observedThreadIDs.contains(item.threadID) && current[item.id] == nil {
            requests.settleNativeRequest(item.id, source: .codex)
            pending.removeValue(forKey: item.id)
        }
        for item in snapshot.pending { pending[item.id] = item }
        requests.updateNativeRequests(shown.map(\.request), source: .codex, preservesDismissals: true) { [client] request, decision in
            guard let item = current[request.id] else { return }
            try await client.resolve(decision, for: item)
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        pending.removeAll()
        shown.removeAll()
        restsUntil.removeAll()
        requests.stopNativeRequests(source: .codex)
    }
}
