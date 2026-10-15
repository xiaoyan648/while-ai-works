import AgentHUDSupport
import Foundation

/// A client saying it needs the user. Claude Code's notification hook is installed for the types that mean exactly
/// that; which kind of attention it is still comes from the transcript, never from the wording of a message, and the
/// transcript is also what says the request has been answered.
public enum AttentionHooks {
    public enum Source: String, CaseIterable, Sendable {
        case claude
        var event: String { "Notification" }
        /// The notification types worth waking for. Claude Code filters on the type itself, so nothing here depends on
        /// the wording of a message, and a sign-in or quota notice never looks like a request for the user.
        var matcher: String { "permission_prompt|agent_needs_input" }
        /// Claude Code's settings, in the directory `CLAUDE_CONFIG_DIR` moves.
        func configuration(home: URL) -> URL { ClaudeSubscription.directory(home: home).appendingPathComponent("settings.json") }

        /// Whether the client is here at all. A machine without it keeps its home untouched.
        func isInstalled(home: URL = FileManager.default.homeDirectoryForCurrentUser, fileManager: FileManager = .default) -> Bool {
            switch self {
            case .claude:
                // The engine where its installers put it for this home; this process's PATH says nothing about the home.
                return ClaudeEngineLocator.find(home: home, fileManager: fileManager, path: "") != nil
                    || fileManager.fileExists(atPath: ClaudeSubscription.directory(home: home).appendingPathComponent("projects").path)
            }
        }
    }

    /// The last thing a client asked for in one session.
    public struct Event: Codable, Equatable, Sendable {
        public let sessionID: String
        /// What the client said it is waiting for; shown as the session's last message while it waits.
        public let message: String?
        public let at: Date

        public init(sessionID: String, message: String?, at: Date) {
            self.sessionID = sessionID; self.message = message; self.at = at
        }

        var approval: SessionPhase.Approval { SessionPhase.Approval(at: at, message: message) }
    }

    public static var directory: URL { AppSupport.directory.appendingPathComponent("attention") }
    /// A request nobody answered is forgotten after this long.
    static let retention: TimeInterval = 86400
    static let messageLength = 2048

    static func event(_ payload: ProviderJSON, now: Date) -> Event? {
        guard let session = payload["session_id"].stringValue, !session.isEmpty else { return nil }
        let message = payload["message"].stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Event(sessionID: session, message: message.flatMap { $0.isEmpty ? nil : String($0.prefix(messageLength)) }, at: now)
    }

    /// One file per session: only the latest request matters, and answering it is seen in the transcript, not here.
    public static func record(source: Source, data: Data, now: Date = Date(), directory: URL = directory) throws {
        guard data.count <= HookInbox.payloadLimit else { throw ProviderFailure.limit }
        guard let event = event(try ProviderJSON.read(data), now: now) else { return }
        let inbox = HookInbox(directory: directory, source: source.rawValue)
        let name = RecordCoding.hash([event.sessionID])
        try inbox.write(event, name: name, replacing: true)
        // Requests age by when they were made, which is inside them; a file's own timestamps say nothing about that.
        for file in try inbox.files() where file.lastPathComponent != name + ".json" {
            let stored = (try? HookInbox.data(of: file)).flatMap { try? JSONDecoder().decode(Event.self, from: $0) }
            if stored.map({ $0.at <= now.addingTimeInterval(-retention) }) ?? true { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// The requests still worth showing, by session.
    public static func read(source: Source, now: Date = Date(), directory: URL = directory) -> [String: Event] {
        guard let files = try? HookInbox(directory: directory, source: source.rawValue).files() else { return [:] }
        var result: [String: Event] = [:]
        for file in files {
            guard let data = try? HookInbox.data(of: file), let event = try? JSONDecoder().decode(Event.self, from: data),
                  event.at > now.addingTimeInterval(-retention), event.at <= now.addingTimeInterval(60) else { continue }
            if let existing = result[event.sessionID], existing.at >= event.at { continue }
            result[event.sessionID] = event
        }
        return result
    }

    // MARK: Installation

    /// What follows the executable in Agent HUD's handler of the notification hook.
    static func arguments(_ source: Source) -> String { "--attention-hook " + source.rawValue }

    static func installer(_ source: Source, home: URL) -> HookInstaller {
        HookInstaller(configuration: source.configuration(home: home), arguments: arguments(source))
    }

    static func configuration(_ source: Source, home: URL) throws -> [String: ProviderJSON] {
        try installer(source, home: home).read()
    }

    static func ownsCommand(_ command: String?, source: Source) -> Bool { HookCommand.runs(command, arguments: arguments(source)) }

    public static func isActive(_ source: Source, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard let object = try? configuration(source, home: home) else { return false }
        return !commands(in: object, source: source).isEmpty
    }

    static func commands(in configuration: [String: ProviderJSON], source: Source) -> [String] {
        ClaudeStyleHooks.commands(in: configuration, event: source.event) { ownsCommand($0, source: source) }
    }

    /// Points every Agent HUD handler of the notification hook at `executable`, whichever copy wrote it
    /// (`HookCommand`), or with `enabled` false takes them all out, leaving every other hook in the file alone. An
    /// unrecognized layout throws rather than being rewritten.
    public static func configure(_ source: Source, enabled: Bool, executable: URL,
                                 home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        try installer(source, home: home).configure(enabled: enabled, executable: executable, updating: {
            try updating($0, source: source, command: $1)
        }, willWrite: {
            // The inbox exists from the moment the hook does, so its changes can be watched before the first request.
            try? HookInbox(directory: directory, source: source.rawValue).create()
        })
    }

    /// The configuration with Agent HUD's handlers taken out, or with `command` when it is given: in the first handler
    /// already there, or in a group of its own.
    static func updating(_ configuration: [String: ProviderJSON], source: Source, command: String?) throws -> [String: ProviderJSON] {
        try ClaudeStyleHooks.updating(configuration, event: source.event, owns: { ownsCommand($0, source: source) }, command: command) { command in
            .object(["matcher": .string(source.matcher),
                     "hooks": .array([.object(["type": .string("command"), "command": .string(command), "timeout": .integer(5)])])])
        }
    }
}
