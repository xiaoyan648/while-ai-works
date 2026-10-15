import Foundation

/// Display grouping for provider-owned client metadata, independent of invocation mode.
public struct SessionSource: Hashable, Sendable {
    /// Execution clients, independent of billing services and the models used inside each client.
    public static let agentVendors = ["Claude", "Codex", "DeepSeek"]
        + AdditionalSource.allCases.flatMap { $0 == .grok ? ["Grok CLI", "Grok Bot"] : [$0.vendor] }
        + OpenAgentSource.allCases.filter { $0 != .glm }.map(\.name)

    /// The provider that owns the execution session; its billing events may belong to a different provider.
    public let vendor: String?
    private let client: String?

    public init(vendor: String?, client: String?) {
        // Cursor meters Bot calls, but the native session and its transcript still belong to Grok.
        self.vendor = vendor == "Cursor" && client == "Grok Bot" ? "Grok" : vendor
        switch vendor {
        case "Codex":
            switch client {
            case "CLI · exec": self.client = "CLI"
            case "Codex": self.client = nil
            default: self.client = client
            }
        case "Claude":
            // Builds before entrypoint detection, and synced peers still on them, carry the plain product name.
            self.client = client == ClaudeEntrypoint.defaultLabel ? nil : client
        case "Grok":
            // Existing Grok sessions came from the CLI before another client had to be distinguished.
            self.client = client ?? "Grok CLI"
        default:
            self.client = client
        }
    }

    /// The execution agent whose live-status switch and artwork this session uses. Grok's clients remain separate
    /// agents even when Cursor supplies Bot billing events. Unknown client names stay as written.
    public var agentVendor: String? {
        if vendor == "Grok" { return client }
        return vendor
    }

    public var name: String {
        switch (vendor, client) {
        case ("Codex", "Desktop"): return VendorCatalog.name("Codex") + " Desktop"
        case ("Codex", "CLI"): return VendorCatalog.name("Codex") + " CLI"
        case ("Codex", "IDE"): return VendorCatalog.name("Codex") + " IDE extension"
        case ("Claude", nil): return ClaudeEntrypoint.defaultLabel
        default: return client ?? vendor.map(VendorCatalog.name) ?? L10n.text("未知来源", "Unknown source")
        }
    }

    /// Vendor implied by an agent id when no descriptor exists for it: a Claude session whose model never answered
    /// ("claude-model:Unknown"), or a synced session for a model this Mac has not seen.
    public static func vendor(impliedBy agentId: String) -> String? {
        let id = agentId.lowercased()
        if id.hasPrefix("claude") { return "Claude" }
        if id.hasPrefix("codex") { return "Codex" }
        if id.hasPrefix("deepseek") { return "DeepSeek" }
        if id.hasPrefix("chatgpt") { return "ChatGPT" }
        if id.hasPrefix("antigravity") { return "Antigravity" }
        if id.hasPrefix("cursor") { return "Cursor" }
        if id.hasPrefix("grok") { return "Grok" }
        for source in AdditionalSource.allCases where id.hasPrefix(source.rawValue + "-model:") { return source.vendor }
        for source in OpenAgentSource.allCases where id.hasPrefix(source.rawValue + "-model:") { return source.name }
        return nil
    }
}
