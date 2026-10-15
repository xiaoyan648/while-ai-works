import Foundation

/// Detection result for one local data source, shown on the first-launch screen.
public struct SourceStatus: Hashable, Sendable, Identifiable {
    public enum State: Hashable, Sendable {
        case ready(plan: String?)
        case notDetected
        case installed
        case unavailable
    }

    public let id: String
    public let name: String
    /// The account provider, shared by execution clients that use the same service.
    public let provider: String
    /// Whether this build can read the client's session state.
    public let supportsLiveStatus: Bool
    public let detail: String
    public let state: State

    public init(id: String, name: String, detail: String, state: State, provider: String? = nil, supportsLiveStatus: Bool = true) {
        self.id = id
        self.name = name
        self.provider = provider ?? name
        self.supportsLiveStatus = supportsLiveStatus
        self.detail = detail
        self.state = state
    }

    /// Subscription badge beside the source name; provider-specific plan codes stay out of the UI.
    public var planLabel: String? {
        guard case .ready(let plan?) = state, !plan.isEmpty else { return nil }
        switch (id, plan.lowercased()) {
        case ("claude-code", "max_5x"): return "Max x5"
        case ("claude-code", "max_20x"): return "Max x20"
        case ("codex-cli", "prolite"): return "Pro x5"
        case ("codex-cli", "pro"): return "Pro x20"
        default: return plan.capitalized
        }
    }

    /// Connection status is independent of the subscription badge.
    public var statusLabel: String {
        switch state {
        case .ready: return L10n.text("已就绪", "Ready")
        case .notDetected: return L10n.text("未检测到", "Not detected")
        case .installed: return L10n.text("已安装 · 等待数据", "Installed · waiting for data")
        case .unavailable: return L10n.text("暂不可用", "Unavailable")
        }
    }
}
