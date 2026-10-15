import Foundation

/// Observes the approvals Antigravity is already asking about; it installs no execution hook and creates no requests
/// for tools that the client has allowed. The native client remains the authority for each request's lifetime.
@MainActor
public final class AntigravityPermissionObserver {
    private let requests: PermissionRequests
    private let client: AntigravityPermissions
    private var task: Task<Void, Never>?

    public init() {
        requests = .shared
        client = AntigravityPermissions()
    }

    public func setEnabled(_ enabled: Bool) {
        guard enabled else { return stop() }
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let pending = try await client.fetch()
                    try Task.checkCancellation()
                    requests.updateNativeRequests(pending.map(\.request), source: .antigravity) { [client] request, decision in
                        guard let native = pending.first(where: { $0.id == request.id }) else { return }
                        try await client.resolve(decision, for: native)
                    }
                } catch {
                    if Task.isCancelled { return }
                    // An unavailable service cannot vouch for a waiting approval.
                    requests.removeNativeRequests(source: .antigravity)
                }
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        requests.stopNativeRequests(source: .antigravity)
    }
}
