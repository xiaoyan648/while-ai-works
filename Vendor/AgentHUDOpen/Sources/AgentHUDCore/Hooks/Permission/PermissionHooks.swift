import AgentHUDSupport
import Foundation

/// The hook a client runs when it is about to ask its user whether a tool may run.
///
/// The notification hook only says a session needs its user; this one is answered. The client waits on the hook's own
/// output and acts on what it says, so a request can be approved from the HUD instead of the terminal. Saying nothing
/// is always available and always safe: the client then behaves exactly as it would with no hook installed.
public enum PermissionHooks {
    /// Clients whose approvals the HUD can answer. Hook clients read Claude Code's allow/deny answer; Antigravity
    /// approvals travel through its native local service, and DeepSeek Harness's questions through its web host's
    /// event stream. Codex CLI and Desktop share one hooks file, WorkBuddy runs CodeBuddy Code's engine, and ZCode's
    /// desktop app and terminal share one engine and configuration file.
    /// Only Claude Code and the Qoder builds apply a permission-rule update sent back.
    public enum Source: String, CaseIterable, Sendable {
        case claude
        case codex
        case qoder
        case qoderCN
        case qoderWork
        case codebuddy
        case workbuddy
        case zcode
        case qwen
        case antigravity
        case deepseek

        public var vendor: String {
            switch self {
            case .claude: return "Claude"
            case .codex: return "Codex"
            case .qoder: return "Qoder"
            case .qoderCN: return "Qoder CN"
            case .qoderWork: return "QoderWork"
            case .codebuddy: return "CodeBuddy"
            case .workbuddy: return "WorkBuddy"
            case .zcode: return "ZCode"
            case .qwen: return "Qwen"
            case .antigravity: return "Antigravity"
            case .deepseek: return "DeepSeek"
            }
        }

        /// Native-service approvals and Harness's questions do not install or run a permission hook.
        public var usesHook: Bool {
            switch self {
            case .antigravity, .deepseek: return false
            default: return true
            }
        }

        var event: String { "PermissionRequest" }
        /// The id this client's sessions carry in reports, so a request stands beside its session everywhere. The providers
        /// that read CodeBuddy, WorkBuddy, ZCode, Qwen Code, Antigravity and DeepSeek prefix their ids with the client;
        /// Claude Code and Codex keep the client's own, and the Qoder builds report no sessions.
        func sessionID(_ raw: String) -> String {
            switch self {
            case .codebuddy, .workbuddy, .zcode, .qwen, .antigravity, .deepseek: return "\(rawValue):\(raw)"
            case .claude, .codex, .qoder, .qoderCN, .qoderWork: return raw
            }
        }
        /// A rule is echoed back only where the client both offers one and applies it. CodeBuddy Code offers
        /// suggestions but never applies one sent back, ZCode applies a rule but never offers one, and Codex and
        /// Qwen Code do neither.
        var supportsPermissionUpdates: Bool {
            switch self {
            case .claude, .qoder, .qoderCN, .qoderWork: return true
            case .codex, .codebuddy, .workbuddy, .zcode, .qwen, .antigravity, .deepseek: return false
            }
        }
        /// Matched against the tool name; empty is every tool. ZCode rejects an empty matcher and runs a group without
        /// one for every tool.
        var matcher: String? { self == .zcode ? nil : "" }
        /// Claude Code's layout keeps the event lists at `hooks.<Event>`; ZCode nests them at `hooks.events.<Event>`.
        var nestsEvents: Bool { self == .zcode }
        /// Calls that ask the user something other than permission. ZCode routes its question and its plan approval
        /// through this event; a question's answers travel back inside its own input, keyed by the question, the same
        /// way Claude Code reads them, while an answer to a plan approves it unread, so the plan stays in ZCode's own
        /// dialog. Qwen Code ignores an allow for both. Claude Code takes a question's answers back through this event and
        /// shows its own plan dialog while the hook waits; its forks are not known to do either. The HUD leaves these to
        /// the client's own dialog. DeepSeek Harness never passes this event: its questions arrive on its web host.
        var unanswerableTools: Set<String> {
            switch self {
            case .zcode: return ["ExitPlanMode"]
            case .qwen: return ["ask_user_question", "exit_plan_mode"]
            case .qoder, .qoderCN, .qoderWork, .codebuddy, .workbuddy: return ["AskUserQuestion", "ExitPlanMode"]
            case .claude, .codex, .antigravity, .deepseek: return []
            }
        }
        /// Whether the client writes Claude Code's session record, where a call answered in the client's own dialog
        /// shows as that call's result.
        var recordsCalls: Bool { self == .claude }
        /// How long the client waits for an answer: only the ceiling behind the HUD's own wait
        /// (`PermissionRequests.holdTime`), for a HUD that stopped answering. A client that cancels the hook first
        /// closes the connection, which takes the request off the HUD.
        /// Qwen Code reads a value of 1000 or more as milliseconds on every version, so its day is written that way.
        var timeout: Int { self == .qwen ? 86_400_000 : 86_400 }

        var directory: String {
            switch self {
            case .claude: return ".claude"
            case .codex: return ".codex"
            case .qoder: return ".qoder"
            case .qoderCN: return ".qoder-cn"
            case .qoderWork: return ".qoderwork"
            case .codebuddy: return ".codebuddy"
            case .workbuddy: return ".workbuddy"
            case .zcode: return ".zcode/cli"
            case .qwen: return ".qwen"
            case .antigravity: return ".gemini"
            case .deepseek: return ".dsh"
            }
        }

        func home(_ base: URL) -> URL {
            if case .codex = self { return CodexLocator.dataDirectory(home: base) }
            if case .codebuddy = self { return CodeBuddySessions.home(base) }
            if case .qwen = self { return QwenSessions.home(base) }
            if case .antigravity = self { return AntigravitySessions.home(base) }
            if case .deepseek = self { return DeepSeekLocator.dataDirectory(environment: ProcessInfo.processInfo.environment, home: base) }
            // Claude Code's configuration directory moves with CLAUDE_CONFIG_DIR; the forks have no such variable.
            if case .claude = self { return ClaudeSubscription.directory(home: base) }
            return base.appendingPathComponent(directory, isDirectory: true)
        }

        /// The client's settings file, in the directory its environment variable moves. Native sources keep this
        /// location for client identity; permission hook setup never reads or writes it.
        public func configuration(home base: URL) -> URL {
            let name: String
            switch self {
            case .codex: name = "hooks.json"
            case .zcode: name = "config.json"
            case .antigravity: name = "config/hooks.json"
            case .deepseek: name = "settings.yaml"
            default: name = "settings.json"
            }
            return home(base).appendingPathComponent(name)
        }

        /// Whether the client is here at all. A machine without it keeps its home untouched.
        public func isInstalled(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                fileManager: FileManager = .default) -> Bool {
            switch self {
            case .claude:
                // The engine where its installers put it for this home; this process's PATH says nothing about the home.
                return ClaudeEngineLocator.find(home: home, fileManager: fileManager, path: "") != nil
                    || fileManager.fileExists(atPath: self.home(home).appendingPathComponent("projects").path)
            case .codex, .qoder, .qoderCN, .qoderWork, .zcode, .qwen:
                return fileManager.fileExists(atPath: self.home(home).path)
            // The session folder is what the usage provider reads; a settings folder alone can be the IDE extension's.
            case .codebuddy, .workbuddy:
                return fileManager.fileExists(atPath: self.home(home).appendingPathComponent("projects").path)
            case .antigravity:
                return AntigravitySessions.roots(home: home, environment: ProcessInfo.processInfo.environment)
                    .contains { fileManager.fileExists(atPath: $0.path) }
            case .deepseek:
                return DeepSeekLocator.isInstalled(directory: self.home(home))
            }
        }
    }

    // MARK: Installation

    /// What follows the executable in Agent HUD's handler of the permission hook.
    static func arguments(_ source: Source) -> String { "--permission-hook " + source.rawValue }

    static func installer(_ source: Source, home: URL) -> HookInstaller {
        HookInstaller(configuration: source.configuration(home: home), arguments: arguments(source))
    }

    static func configuration(_ source: Source, home: URL) throws -> [String: ProviderJSON] {
        guard source.usesHook else { return [:] }
        return try installer(source, home: home).read()
    }

    static func ownsCommand(_ command: String?, source: Source) -> Bool {
        source.usesHook && HookCommand.runs(command, arguments: arguments(source))
    }

    public static func isActive(_ source: Source, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard source.usesHook, let object = try? configuration(source, home: home) else { return false }
        return !commands(in: object, source: source).isEmpty
    }

    static func commands(in configuration: [String: ProviderJSON], source: Source) -> [String] {
        guard source.usesHook else { return [] }
        let hooks = ProviderJSON.object(configuration)["hooks"]
        let events = source.nestsEvents ? hooks["events"] : hooks
        return (events[source.event].arrayValue ?? []).flatMap { $0["hooks"].arrayValue ?? [] }
            .compactMap { $0["command"].stringValue }.filter { ownsCommand($0, source: source) }
    }

    /// Points every Agent HUD handler of the permission hook at `executable`, whichever copy wrote it
    /// (`HookCommand`), or with `enabled` false takes them all out, leaving every other hook in the file alone. An
    /// unrecognized layout throws rather than being rewritten.
    public static func configure(_ source: Source, enabled: Bool, executable: URL,
                                 home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        guard source.usesHook else { return }
        try installer(source, home: home).configure(enabled: enabled, executable: executable) {
            try updating($0, source: source, command: $1)
        }
    }

    /// The configuration with Agent HUD's handlers taken out, or with `command` when it is given: in the first handler
    /// already there, or in a group of its own.
    static func updating(_ configuration: [String: ProviderJSON], source: Source, command: String?) throws -> [String: ProviderJSON] {
        guard source.usesHook else { return configuration }
        var object = configuration
        guard object["hooks"] == nil || object["hooks"]?.objectValue != nil else { throw ProviderFailure.format }
        var hooks = object["hooks"]?.objectValue ?? [:]
        if source.nestsEvents {
            // ZCode drops its whole configuration over a malformed hooks section, so only its known shapes are edited.
            guard hooks["events"] == nil || hooks["events"]?.objectValue != nil,
                  hooks["enabled"] == nil || hooks["enabled"]?.boolValue != nil else { throw ProviderFailure.format }
        }
        var events = source.nestsEvents ? hooks["events"]?.objectValue ?? [:] : hooks
        guard events[source.event] == nil || events[source.event]?.arrayValue != nil else { throw ProviderFailure.format }
        // A handler already there takes the new command and keeps the matcher, timeout and anything else the user set.
        let groups = ClaudeStyleHooks.setting(command, in: events[source.event]?.arrayValue ?? [],
                                              owns: { ownsCommand($0, source: source) }) { command in
            var group: [String: ProviderJSON] = ["hooks": .array([.object(["type": .string("command"), "command": .string(command),
                                                                           "timeout": .integer(Int64(source.timeout))])])]
            if let matcher = source.matcher { group["matcher"] = .string(matcher) }
            return .object(group)
        }
        events[source.event] = groups.isEmpty ? nil : .array(groups)
        if source.nestsEvents {
            hooks["events"] = events.isEmpty ? nil : .object(events)
            // ZCode runs no hook at all until this is set. A user who switched hooks off keeps them off.
            if command != nil, hooks["enabled"] == nil { hooks["enabled"] = .bool(true) }
        } else {
            hooks = events
        }
        object["hooks"] = hooks.isEmpty && configuration["hooks"] == nil ? nil : .object(hooks)
        return object
    }
}
