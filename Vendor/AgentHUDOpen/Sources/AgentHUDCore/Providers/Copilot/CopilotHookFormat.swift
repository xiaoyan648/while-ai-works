import AgentHUDSupport
import Foundation

/// Handler in `hooks.agentStop` of the version-1 user hook file `~/.copilot/hooks/agent-hud.json`; only `bash` commands
/// ending in ` --completion-hook copilot` are Agent HUD's.
enum CopilotHookFormat: CompletionHookFormat {
    static func configuration(home: URL) -> URL { home.appendingPathComponent(".copilot/hooks/agent-hud.json") }

    /// The payload names no turn, so the callback time identifies it.
    static func completion(_ payload: ProviderJSON, now: Date) -> CompletionHookEvent? {
        guard payload["stopReason"].stringValue == "end_turn", let session = payload["sessionId"].stringValue else { return nil }
        return .init(session: session, turn: "stop-\(RecordCoding.milliseconds(now))", workspace: payload["cwd"].stringValue)
    }

    private static func owns(_ handler: ProviderJSON) -> Bool { CompletionHooks.ownsCommand(handler["bash"].stringValue, source: .copilot) }

    static func commands(in configuration: [String: ProviderJSON]) -> [String] {
        (configuration["hooks"]?["agentStop"].arrayValue ?? []).filter(owns).compactMap { $0["bash"].stringValue }
    }

    static func updating(_ configuration: [String: ProviderJSON], command: String?) throws -> [String: ProviderJSON] {
        guard command != nil || !commands(in: configuration).isEmpty else { return configuration }
        var object = configuration
        guard object["version"] == nil || object["version"] == .integer(1),
              object["hooks"] == nil || object["hooks"]?.objectValue != nil else { throw ProviderFailure.format }
        var hooks = object["hooks"]?.objectValue ?? [:]
        guard hooks["agentStop"] == nil || hooks["agentStop"]?.arrayValue != nil else { throw ProviderFailure.format }
        var placed = false
        var handlers = ClaudeStyleHooks.setting(command, in: hooks["agentStop"]?.arrayValue ?? [], key: "bash",
                                                owns: { CompletionHooks.ownsCommand($0, source: .copilot) }, placed: &placed)
        if let command, !placed { handlers.append(.object(["type": .string("command"), "bash": .string(command), "timeoutSec": .integer(5)])) }
        hooks["agentStop"] = handlers.isEmpty ? nil : .array(handlers)
        object["hooks"] = .object(hooks); object["version"] = .integer(1)
        return object
    }
}
