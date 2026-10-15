import Foundation

/// A timed scenario for the demo, so a recording shows the same events at the same moments in every take: sessions
/// start and end, a client asks for permission, a reply arrives, a window fills up, the panel opens. Each step changes
/// what the demo's own sources report, and the HUD reacts the way it does to real ones.
public struct DemoScript: Codable, Equatable, Sendable {
    public struct Step: Equatable, Sendable {
        /// Seconds from the start of the script.
        public var at: TimeInterval
        public var action: Action

        public init(at: TimeInterval, _ action: Action) {
            self.at = at
            self.action = action
        }
    }

    public enum Action: Equatable, Sendable {
        /// A demo session starts running: `s1` to `s9` (`DemoData.plans`).
        case work(session: String)
        /// It stops with nothing to say.
        case rest(session: String)
        /// Its turn ends with a reply, which raises the reply reminder.
        case reply(session: String, message: String?)
        /// One of the demo's permission requests arrives: `demo-tests`, `demo-edit`, `demo-build`, `demo-ticket`, `demo-read`.
        case ask(request: String)
        /// The client takes it back, as when it was answered in the client's own window.
        case answer(request: String)
        /// A window's reading changes to this percentage used. Crossing a threshold raises the quota alert. `agent` is
        /// the window's key (`claude-session`, `claude-weekly`, `claude-weekly-fable`, `codex`, `codex:spark:primary`) or
        /// the id of another vendor's row (`cursor`).
        case quota(agent: String, used: Double)
        /// The usage panel opens or closes, as hovering does.
        case panel(open: Bool)
    }

    /// The sessions already running when the script starts.
    public var running: [String]
    /// Readings that differ from the demo's own at the start, as percentages used by window key.
    public var used: [String: Double]
    public var steps: [Step]
    /// Seconds after the last step before the script starts over. Without it the script plays once.
    public var repeatAfter: TimeInterval?

    public init(running: [String] = [], used: [String: Double] = [:], steps: [Step], repeatAfter: TimeInterval? = nil) {
        self.running = running
        self.used = used
        self.steps = steps.sorted { $0.at < $1.at }
        self.repeatAfter = repeatAfter
    }

    /// Seconds from the start to the last step.
    public var length: TimeInterval { steps.last?.at ?? 0 }

    private enum CodingKeys: String, CodingKey { case running, used, steps, repeatAfter }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(running: try c.decodeIfPresent([String].self, forKey: .running) ?? [],
                  used: try c.decodeIfPresent([String: Double].self, forKey: .used) ?? [:],
                  steps: try c.decode([Step].self, forKey: .steps),
                  repeatAfter: try c.decodeIfPresent(TimeInterval.self, forKey: .repeatAfter))
    }

    // MARK: Finding one

    public enum LoadError: Error, Equatable {
        case unknown(String)
    }

    /// The scripts the app carries, by name.
    public static let builtIn: [String: DemoScript] = ["showcase": showcase]

    /// A built-in script by name, or the JSON file at this path.
    public static func load(_ nameOrPath: String) throws -> DemoScript {
        if let script = builtIn[nameOrPath] { return script }
        let url = URL(fileURLWithPath: (nameOrPath as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else { throw LoadError.unknown(nameOrPath) }
        return try JSONDecoder().decode(DemoScript.self, from: Data(contentsOf: url))
    }

    /// Three quarters of a minute that show each kind of event once: two agents start work, Claude asks to run the
    /// tests and is answered, Claude replies, Claude's session window crosses nine tenths, the panel opens and closes,
    /// Codex replies; then it starts over. The window that crosses is one the demo's forecast does not already warn
    /// about, or the crossing would raise nothing.
    public static let showcase = DemoScript(
        steps: [
            Step(at: 2, .work(session: "s1")),
            Step(at: 4.5, .work(session: "s2")),
            Step(at: 8, .ask(request: "demo-tests")),
            Step(at: 14, .answer(request: "demo-tests")),
            Step(at: 17, .reply(session: "s1", message: nil)),
            Step(at: 24, .quota(agent: "claude-session", used: 91)),
            Step(at: 31, .panel(open: true)),
            Step(at: 36, .panel(open: false)),
            Step(at: 39, .reply(session: "s2", message: L10n.text(
                "沙盒收据的校验已经补上，生产环境的购买流程没有变化。",
                "Sandbox receipts are validated now; purchases in production go through as before."))),
        ],
        repeatAfter: 6
    )
}

extension DemoScript.Step: Codable {
    private enum CodingKeys: String, CodingKey { case at, action = "do", session, request, agent, used, open, message }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try c.decode(TimeInterval.self, forKey: .at)
        let name = try c.decode(String.self, forKey: .action)
        switch name {
        case "work": action = .work(session: try c.decode(String.self, forKey: .session))
        case "rest": action = .rest(session: try c.decode(String.self, forKey: .session))
        case "reply":
            action = .reply(session: try c.decode(String.self, forKey: .session),
                            message: try c.decodeIfPresent(String.self, forKey: .message))
        case "ask": action = .ask(request: try c.decode(String.self, forKey: .request))
        case "answer": action = .answer(request: try c.decode(String.self, forKey: .request))
        case "quota":
            action = .quota(agent: try c.decode(String.self, forKey: .agent), used: try c.decode(Double.self, forKey: .used))
        case "panel": action = .panel(open: try c.decode(Bool.self, forKey: .open))
        default:
            throw DecodingError.dataCorruptedError(forKey: .action, in: c, debugDescription: "Unknown step: \(name)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(at, forKey: .at)
        switch action {
        case .work(let session):
            try c.encode("work", forKey: .action); try c.encode(session, forKey: .session)
        case .rest(let session):
            try c.encode("rest", forKey: .action); try c.encode(session, forKey: .session)
        case .reply(let session, let message):
            try c.encode("reply", forKey: .action); try c.encode(session, forKey: .session)
            try c.encodeIfPresent(message, forKey: .message)
        case .ask(let request):
            try c.encode("ask", forKey: .action); try c.encode(request, forKey: .request)
        case .answer(let request):
            try c.encode("answer", forKey: .action); try c.encode(request, forKey: .request)
        case .quota(let agent, let used):
            try c.encode("quota", forKey: .action); try c.encode(agent, forKey: .agent); try c.encode(used, forKey: .used)
        case .panel(let open):
            try c.encode("panel", forKey: .action); try c.encode(open, forKey: .open)
        }
    }
}
