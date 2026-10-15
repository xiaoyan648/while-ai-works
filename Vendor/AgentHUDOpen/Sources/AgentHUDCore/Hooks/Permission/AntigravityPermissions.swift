import AgentHUDSupport
import Foundation

/// The same waiting permissions Antigravity shows in its own dialog. No hook runs before already-approved tools.
public struct AntigravityPermissions: Sendable {
    public struct Pending: Sendable {
        public let request: PermissionRequest
        public var id: String { request.id }
        let endpoint: AntigravityService.Endpoint
        let cascadeID: String
        let trajectoryID: String
        let stepIndex: Int64
        let permission: ProviderJSON
    }

    var http = ProviderHTTP()
    /// Where the running services listen. Finding them lists every process, so a poll reuses what the last one found;
    /// `true` asks for a new search, after a service stopped answering and before an answer is sent.
    var discover: @Sendable (_ fresh: Bool) async throws -> [AntigravityService.Endpoint] = { fresh in
        try await AntigravityService.remembered.value(fresh: fresh)
    }
    var clock: @Sendable () -> Date = { Date() }

    public init() {}

    /// Summaries carry the waiting steps themselves, so polling reads no conversation transcript.
    public func fetch() async throws -> [Pending] {
        let known = try await discover(false)
        try Task.checkCancellation()
        do { return try await read(known) }
        catch Failure.unavailable {
            // A remembered service that no longer answers has usually quit. Only the same services, found again and
            // still silent, make the client unavailable.
            let current = try await discover(true)
            try Task.checkCancellation()
            guard current != known else { throw Failure.unavailable }
            return try await read(current)
        }
    }

    private func read(_ endpoints: [AntigravityService.Endpoint]) async throws -> [Pending] {
        guard !endpoints.isEmpty else { return [] }
        var found: [Pending] = [], readPIDs = Set<Int>()
        for endpoint in endpoints {
            try Task.checkCancellation()
            guard !readPIDs.contains(endpoint.pid) else { continue }
            do {
                let json = try await endpoint.json("GetAllCascadeTrajectories", http: http)
                try Task.checkCancellation()
                found += try Self.pending(json, endpoint: endpoint, now: clock())
                readPIDs.insert(endpoint.pid)
            } catch {
                try Task.checkCancellation()
            }
        }
        // A failed service is unknown, not an empty set of permissions. Never publish an incomplete snapshot.
        guard readPIDs == Set(endpoints.map(\.pid)) else { throw Failure.unavailable }
        return found.sorted { ($0.request.at, $0.id) < ($1.request.at, $1.id) }
    }

    /// An answer belongs to the exact permission the user read. A withdrawn or changed step is never answered.
    public func resolve(_ decision: PermissionDecision, for pending: Pending) async throws {
        let allow: Bool
        switch decision {
        case .leave: return
        case .allow: allow = true
        case .deny: allow = false
        case .allowAlways, .answer: throw Failure.unsupportedDecision
        }
        let endpoints = try await discover(true)
        try Task.checkCancellation()
        guard endpoints.contains(pending.endpoint) else { throw Failure.noLongerWaiting }
        let current = try await pending.endpoint.json("GetAllCascadeTrajectories", http: http)
        try Task.checkCancellation()
        guard let matching = try Self.pending(current, endpoint: pending.endpoint, now: clock()).first(where: { $0.id == pending.id }),
              matching.permission == pending.permission else { throw Failure.noLongerWaiting }
        try Task.checkCancellation()
        let body: ProviderJSON = .object([
            "cascadeId": .string(pending.cascadeID),
            "interaction": .object([
                "trajectoryId": .string(pending.trajectoryID), "stepIndex": .integer(pending.stepIndex),
                "permission": .object(["allow": .bool(allow), "scope": .string("PERMISSION_SCOPE_ONCE")]),
            ]),
        ])
        try Task.checkCancellation()
        _ = try await pending.endpoint.json("HandleCascadeUserInteraction", body: body, http: http)
    }

    static func pending(_ json: ProviderJSON, endpoint: AntigravityService.Endpoint, now: Date) throws -> [Pending] {
        guard json.objectValue != nil else { throw ProviderFailure.format }
        // An empty protobuf map is omitted from JSON.
        guard json["trajectorySummaries"] != .null else { return [] }
        guard let summaries = json["trajectorySummaries"].objectValue else { throw ProviderFailure.format }
        let serviceID = RecordCoding.hash([String(endpoint.pid), endpoint.base.absoluteString, endpoint.token])
        var result: [Pending] = []
        for (cascadeID, summary) in summaries.sorted(by: { $0.key < $1.key }) {
            guard !cascadeID.isEmpty else { continue }
            for waiting in summary["waitingSteps"].arrayValue ?? [] {
                let step = waiting["step"], metadata = step["metadata"], source = metadata["sourceTrajectoryStepInfo"]
                guard step["status"].stringValue == "CORTEX_STEP_STATUS_WAITING" || step["status"].numberValue == 9,
                      let permission = step["requestedInteraction"]["permission"].objectValue,
                      let trajectoryID = source["trajectoryId"].stringValue, !trajectoryID.isEmpty,
                      let action = permission["resource"]?["action"].stringValue, !action.isEmpty,
                      let target = permission["resource"]?["target"].stringValue, !target.isEmpty else { continue }
                let index = source["stepIndex"].numberValue ?? 0
                guard let stepIndex = Int64(exactly: index), (0...Int64(UInt32.max)).contains(stepIndex),
                      waiting["stepIndex"].numberValue.map({ $0 == index }) ?? true,
                      source["cascadeId"].stringValue.map({ $0 == cascadeID }) ?? true else { continue }
                let workspace = summary["workspaces"].arrayValue?.first?["workspaceFolderAbsoluteUri"].stringValue
                    .flatMap { URL(string: $0) }.flatMap { $0.isFileURL ? $0.path : nil }
                let tool = metadata["toolCall"]["name"].stringValue ?? action
                let description = permission["actionDescription"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                let identity: ProviderJSON = .object([
                    "permission": .object(permission), "toolCall": metadata["toolCall"],
                    "workspace": workspace.map { .string($0) } ?? .null, "executionId": metadata["executionId"],
                ])
                let interactionID = RecordCoding.hash([String(decoding: try RecordCoding.encoder().encode(identity), as: UTF8.self)])
                let request = PermissionRequest(
                    id: "antigravity:\(serviceID):\(cascadeID):\(trajectoryID):\(stepIndex):\(interactionID)", source: .antigravity,
                    sessionID: "antigravity:\(cascadeID)", toolName: tool,
                    summary: String((description.flatMap { $0.isEmpty ? nil : $0 } ?? action).prefix(PermissionRequest.detailLength)),
                    detail: String(target.prefix(PermissionRequest.detailLength)), cwd: workspace,
                    at: now
                )
                result.append(Pending(request: request, endpoint: endpoint, cascadeID: cascadeID, trajectoryID: trajectoryID,
                                      stepIndex: stepIndex, permission: .object(permission)))
            }
        }
        return result
    }

    enum Failure: LocalizedError {
        case unavailable, noLongerWaiting, unsupportedDecision
        var errorDescription: String? {
            switch self {
            case .unavailable: L10n.text("无法读取 Antigravity 的权限请求", "Antigravity's permission requests could not be read")
            case .noLongerWaiting: L10n.text("Antigravity 的请求已撤回或变更", "Antigravity's request was withdrawn or changed")
            case .unsupportedDecision: L10n.text("请在 Antigravity 中选择此权限选项", "Choose this permission option in Antigravity")
            }
        }
    }
}
