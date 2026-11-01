import AppKit
import AgentHUDCore
import Combine
import UniformTypeIdentifiers

struct QuickInputProject: Equatable, Identifiable, Codable {
    let path: String
    var id: String { path }
    var name: String { isAll ? "全部会话" : URL(fileURLWithPath: path).lastPathComponent }
    /// Every session, including those with no directory or one that no longer exists.
    static let all = QuickInputProject(path: "")
    var isAll: Bool { path.isEmpty }
}

/// Who can start a new session. A desktop app and its command line are separate things to the
/// user and can do different things, so they are separate here: what a client can do never
/// changes behind its name. Apps open with the text filled in; only terminals can start work on it.
enum QuickInputClient: String, CaseIterable, Identifiable {
    case codexApp, codexCLI, claudeApp, claudeCode, hermes
    var id: String { rawValue }
    var source: WorkSource {
        switch self {
        case .codexApp, .codexCLI: return .codex
        case .claudeApp, .claudeCode: return .claude
        case .hermes: return .hermes
        }
    }
    var title: String {
        switch self {
        case .codexApp: return "Codex"
        case .codexCLI: return "Codex CLI"
        case .claudeApp: return "Claude"
        case .claudeCode: return "Claude Code"
        case .hermes: return "Hermes"
        }
    }
    var runsInTerminal: Bool { self != .codexApp && self != .claudeApp }
    /// The app's link for a new session; it only fills the composer. Claude's comes from the
    /// app's own handler rather than its documentation.
    func appLink(path: String, prompt: String?) -> URL? {
        var fields: [(String, String)]
        let base: String
        switch self {
        case .codexApp: base = "codex://new"; fields = [("path", path)]; if let prompt { fields.append(("prompt", prompt)) }
        case .claudeApp: base = "claude://code/new"; fields = [("folder", path), ("source", "while-ai-works")]; if let prompt { fields.append(("q", prompt)) }
        default: return nil
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let query = fields.compactMap { name, value in value.addingPercentEncoding(withAllowedCharacters: allowed).map { name + "=" + $0 } }
        return URL(string: base + "?" + query.joined(separator: "&"))
    }
    static let promptLimit = 5000
    /// An existing Codex desktop thread opens with the text in its composer. The app reads
    /// `prompt` on thread links too, though its documentation only lists it for new ones.
    static func threadLink(_ session: AgentDockSession, prompt: String) -> URL? {
        guard session.navigationURL?.scheme == "codex", let base = session.navigationURL?.absoluteString, !base.contains("?") else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return prompt.addingPercentEncoding(withAllowedCharacters: allowed).flatMap { URL(string: base + "?prompt=" + $0) }
    }
}

enum QuickInputTarget: Equatable {
    case client(QuickInputClient)
    case session(String)
}

enum QuickInputPickerKind: Equatable { case agent, place }
enum QuickInputPlacePane: Equatable { case workspaces, sessions }

struct QuickInputRow: Identifiable, Equatable {
    enum Tone: Equatable { case plain, working, attention }
    let id: String
    let client: QuickInputClient
    let subtitle: String
    var trailing = ""
    var tone = Tone.plain
    var title: String { client.title }
}

/// `@` and `#` only count at a word start, so mail addresses and `issue#12` stay plain text.
enum QuickInputToken {
    struct Match: Equatable {
        let trigger: Character
        let query: String
        let range: NSRange
    }
    static func match(in text: String, cursor: Int) -> Match? {
        let characters = text as NSString
        guard cursor >= 0, cursor <= characters.length else { return nil }
        var start = cursor
        while start > 0 {
            let unit = characters.character(at: start - 1)
            guard let scalar = Unicode.Scalar(unit), !CharacterSet.whitespacesAndNewlines.contains(scalar) else { return nil }
            if scalar == "@" || scalar == "#" {
                if start > 1, let before = Unicode.Scalar(characters.character(at: start - 2)),
                   before.isASCII, CharacterSet.alphanumerics.contains(before) { return nil }
                let range = NSRange(location: start - 1, length: cursor - start + 1)
                return Match(trigger: Character(scalar), query: characters.substring(with: NSRange(location: start, length: cursor - start)), range: range)
            }
            start -= 1
        }
        return nil
    }
}

/// Anything that runs in a terminal runs interactively in a real one the user can take over:
/// that keeps approvals and hooks working, and the process does not belong to WAW, so quitting
/// or updating WAW leaves it running. A prompt travels through a private file, so neither the
/// shell nor the terminal ever parses it.
enum QuickInputRun {
    enum Command: Equatable {
        /// A new session, working on the prompt at once when there is one.
        case new(QuickInputClient)
        /// An earlier session continuing with the prompt.
        case resume(QuickInputClient, id: String)
        /// The command a session recorded for returning to it.
        case recorded(String)
    }
    struct Request: Equatable {
        let command: Command
        let directory: String
        var prompt: String? = nil
        /// Sending leaves the user where they are; going takes them there.
        var background = false
    }
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func line(_ command: Command, executable: String?, directory: String, hasPrompt: Bool) -> String? {
        let prompt = "\"$prompt\""
        switch command {
        case .recorded(let line): return line
        case .new(let client):
            guard let executable else { return nil }
            let exe = quote(executable)
            switch client {
            case .claudeCode: return hasPrompt ? "\(exe) -- \(prompt)" : exe
            case .codexCLI: return "\(exe) -C \(quote(directory))" + (hasPrompt ? " -- \(prompt)" : "")
            case .hermes: return "\(exe) chat --in \(quote(directory))" + (hasPrompt ? " --query=\(prompt)" : "")
            default: return nil
            }
        case .resume(let client, let id):
            guard let executable else { return nil }
            let exe = quote(executable)
            switch client {
            case .claudeCode: return "\(exe) --resume \(quote(id))" + (hasPrompt ? " -- \(prompt)" : "")
            case .codexCLI: return "\(exe) resume -C \(quote(directory)) \(quote(id))" + (hasPrompt ? " -- \(prompt)" : "")
            default: return nil
            }
        }
    }
    static func script(_ request: Request, executable: String?, promptFile: String?, searchPath: String) -> String? {
        guard let line = line(request.command, executable: executable, directory: request.directory, hasPrompt: promptFile != nil) else { return nil }
        let read = promptFile.map { "prompt=\"$(cat -- \(quote($0)))\"\nrm -f -- \(quote($0))\n" } ?? ""
        return """
        #!/bin/zsh -f
        export PATH=\(quote(searchPath))
        cd -- \(quote(request.directory)) || exit 1
        \(read)rm -f -- "$0"
        \(line)
        code=$?
        if [ $code -ne 0 ]; then print; print "启动失败（退出码 $code）。可以关闭这个窗口。"; read -k1 -s; fi

        """
    }
    static func executable(for client: QuickInputClient, searchPath: String) -> String? {
        switch client {
        case .codexCLI: return CodexLocator.find(path: searchPath)?.path
        case .claudeCode: return search("claude", in: searchPath)
        case .hermes: return search("hermes", in: searchPath)
        case .codexApp, .claudeApp: return nil
        }
    }
    private static func search(_ name: String, in path: String) -> String? {
        path.split(separator: ":").map { String($0) + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Runs the script with whatever opens scripts on this Mac, which is what the user's default
/// terminal means there. The one exception is how to start Otty, nothing else about it.
enum QuickInputLauncher {
    /// `open` is the only way macOS offers, and terminals run what it hands them. Otty shows the
    /// script instead, and has its own command for running one.
    static func command(terminal: String, application: URL, script: String, directory: String) -> (executable: URL, arguments: [String]) {
        if terminal == "io.appmakes.otty" {
            return (application.appendingPathComponent("Contents/MacOS/otty-cli"), ["open", directory, "--command", QuickInputRun.quote(script), "--quiet"])
        }
        return (URL(fileURLWithPath: "/usr/bin/open"), [script])
    }
    /// A script that never ran still holds its prompt. Anything this old was not going to.
    private static func removeStale(in folder: URL, now: Date = Date()) {
        let manager = FileManager.default
        for file in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) > 3600 { try? manager.removeItem(at: file) }
        }
    }
    static func launch(_ request: QuickInputRun.Request) -> String? {
        let search = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var executable: String?
        switch request.command {
        case .new(let client), .resume(let client, _): executable = QuickInputRun.executable(for: client, searchPath: search)
        case .recorded: executable = nil
        }
        if case .recorded = request.command {} else if executable == nil { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WhileAIWorks-QuickInput", isDirectory: true)
        let id = UUID().uuidString
        let promptFile = folder.appendingPathComponent(id + ".txt"), scriptFile = folder.appendingPathComponent(id + ".command")
        guard let script = QuickInputRun.script(request, executable: executable, promptFile: request.prompt == nil ? nil : promptFile.path, searchPath: search) else { return nil }
        let manager = FileManager.default
        removeStale(in: folder)
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if let prompt = request.prompt, !manager.createFile(atPath: promptFile.path, contents: Data(prompt.utf8), attributes: [.posixPermissions: 0o600]) { return nil }
            guard manager.createFile(atPath: scriptFile.path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o700]) else { return nil }
        } catch { return nil }
        let workspace = NSWorkspace.shared
        func discard() { try? manager.removeItem(at: promptFile); try? manager.removeItem(at: scriptFile) }
        guard let handler = workspace.urlForApplication(toOpen: scriptFile), let terminal = Bundle(url: handler)?.bundleIdentifier else { discard(); return nil }
        let previous = workspace.frontmostApplication
        let launch = command(terminal: terminal, application: handler, script: scriptFile.path, directory: request.directory)
        let process = Process()
        process.executableURL = launch.executable
        process.arguments = launch.arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { discard(); return nil }
        if request.background {
            returnFront(to: previous, from: terminal, script: scriptFile.path, deadline: Date().addingTimeInterval(8))
        } else {
            // Not every way of starting one brings the terminal forward.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                NSRunningApplication.runningApplications(withBundleIdentifier: terminal).first?.activate()
            }
        }
        return terminal
    }
    /// Terminals may need the front to run a script at all, and how long differs, so the script
    /// says when: the first thing it does is delete itself. Only then does the front go back.
    private static func returnFront(to previous: NSRunningApplication?, from terminal: String, script: String, deadline: Date) {
        guard let previous, previous.bundleIdentifier != terminal else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard !FileManager.default.fileExists(atPath: script) || Date() >= deadline else {
                returnFront(to: previous, from: terminal, script: script, deadline: deadline)
                return
            }
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == terminal { previous.activate() }
        }
    }
}

/// Whether a client's command line can do any work. Someone who only uses Claude's desktop app
/// has a `claude` that starts, takes the prompt and answers "Not logged in" in a window behind them.
enum QuickInputReadiness {
    static func claudeLoggedIn(status: Data) -> Bool? {
        (try? JSONSerialization.jsonObject(with: status) as? [String: Any])?["loggedIn"] as? Bool
    }
    static func claudeCode() -> Bool? {
        guard let executable = QuickInputRun.executable(for: .claudeCode, searchPath: ProcessInfo.processInfo.environment["PATH"] ?? "") else { return nil }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["auth", "status"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let status = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return claudeLoggedIn(status: status)
    }
}

/// Which sessions a live process still holds, asked of the agents rather than the terminal, so it
/// holds in any terminal: Claude Code registers its process, and Codex keeps its log open.
enum QuickInputLiveness {
    static func claudeSessions(in folder: URL, isAlive: (pid_t) -> Bool = { kill($0, 0) == 0 }) -> [String: pid_t] {
        var found: [String: pid_t] = [:]
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = entry["sessionId"] as? String, let pid = (entry["pid"] as? NSNumber)?.int32Value, isAlive(pid) else { continue }
            found[id] = pid
        }
        return found
    }
    /// `lsof -Fpn` lists a `p<pid>` line followed by that process's `n<path>` lines.
    static func codexSessions(lsof output: String) -> [String: pid_t] {
        var found: [String: pid_t] = [:], pid: pid_t = 0
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") { pid = pid_t(line.dropFirst()) ?? 0; continue }
            guard line.hasPrefix("n"), line.contains("/rollout-"), line.hasSuffix(".jsonl"), line.count > 42 else { continue }
            let id = String(line.dropLast(6).suffix(36)).lowercased()
            if UUID(uuidString: id) != nil { found[id] = pid }
        }
        return found
    }
    static func current() -> [String: pid_t] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var found = claudeSessions(in: home.appendingPathComponent(".claude/sessions", isDirectory: true))
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-c", "codex", "-Fpn"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        if (try? process.run()) != nil {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            found.merge(codexSessions(lsof: String(decoding: data, as: UTF8.self))) { current, _ in current }
        }
        return found
    }
    /// Climbs from a process to the app it runs inside, which is its terminal, whichever that is.
    /// Terminals that host sessions in a background service break the chain; the default terminal
    /// is then the best guess at where it is.
    static func bringOwnerForward(of pid: pid_t) -> Bool {
        var current = pid
        for _ in 0..<16 where current > 1 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular { return app.activate() }
            var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
            var query = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&query, 4, &info, &size, nil, 0) == 0, size > 0 else { break }
            current = info.kp_eproc.e_ppid
        }
        guard let type = UTType(filenameExtension: "command"), let handler = NSWorkspace.shared.urlForApplication(toOpen: type),
              let bundle = Bundle(url: handler)?.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.activate() ?? false
    }
}

enum QuickInputCatalog {
    static func path(of session: AgentDockSession) -> String? {
        session.workingDirectory ?? session.project.flatMap { $0.hasPrefix("/") ? $0 : nil }
    }
    static func isWaiting(_ session: AgentDockSession) -> Bool { session.event == .approval || session.event == .input }
    /// The client a session belongs to, from how it can be reached.
    static func client(of session: AgentDockSession) -> QuickInputClient? {
        let inApp = session.navigationURL?.scheme == "codex" || session.navigationURL?.scheme == "claude"
        switch session.source {
        case .codex: return inApp ? .codexApp : .codexCLI
        case .claude: return inApp ? .claudeApp : .claudeCode
        case .hermes: return .hermes
        default: return nil
        }
    }
    /// A session Enter can take you to: it records a route, it is alive somewhere, or it can be resumed.
    static func canOpen(_ session: AgentDockSession) -> Bool {
        session.navigationURL != nil || session.localSessionLock != nil || session.localBridgeRoot != nil
            || session.running || isWaiting(session) || session.resumeCommand != nil
    }
    /// A session a message can go straight into: a running or idle Codex desktop thread, or an ended
    /// command-line session that can be resumed with it. A session waiting on the user takes nothing,
    /// and one a process still holds is not resumed, even while idle: two processes would share it.
    static func canSend(_ session: AgentDockSession, claudeCodeWorks: Bool, live: Set<String> = []) -> Bool {
        guard !isWaiting(session) else { return false }
        if session.canSend { return true }
        guard !session.running, session.navigationURL == nil, !live.contains(session.id),
              session.resumeCommand != nil, UUID(uuidString: session.id) != nil, path(of: session) != nil else { return false }
        switch client(of: session) {
        case .codexCLI: return true
        case .claudeCode: return claudeCodeWorks
        default: return false
        }
    }

    /// Workspaces in the dock's order, so the busiest come first; recently used ones follow.
    static func projects(sessions: [AgentDockSession], recents: [String], exists: (String) -> Bool) -> [QuickInputProject] {
        var seen = Set<String>()
        return (sessions.compactMap(path) + recents).filter { seen.insert($0).inserted && exists($0) }.map { QuickInputProject(path: $0) }
    }

    static func clientRows(clients: [QuickInputClient], claudeCodeWorks: Bool, quota: (WorkSource) -> AgentDockQuota?, query: String) -> [QuickInputRow] {
        clients.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }.map { client in
            let reading = quota(client.source).flatMap { $0.stale ? nil : $0.remaining }
            let subtitle = client == .claudeCode && !claudeCodeWorks ? "命令行未登录，发不了" : client.runsInTerminal ? "终端" : "桌面端"
            return QuickInputRow(id: "client:" + client.rawValue, client: client, subtitle: subtitle,
                trailing: reading.map { "额度 \(Int($0.rounded()))%" } ?? "", tone: (reading ?? 100) <= 15 ? .attention : .plain)
        }
    }

    private static func matches(_ session: AgentDockSession, _ query: String) -> Bool {
        session.title.localizedCaseInsensitiveContains(query) || session.source.clientName.localizedCaseInsensitiveContains(query)
    }
    /// Without a search, everything under "all" first. With one, workspaces named by it come first,
    /// then "all" for the sessions it found, then the workspaces holding such a session for their client.
    static func workspaces(projects: [QuickInputProject], sessions: [AgentDockSession], query: String, client: (QuickInputProject) -> QuickInputClient? = { _ in nil }) -> [QuickInputProject] {
        guard !query.isEmpty else { return [.all] + projects.prefix(30) }
        let roots = sessions.filter { $0.parentSessionID == nil && canOpen($0) }
        let named = projects.filter { $0.path.localizedCaseInsensitiveContains(query) }
        let holding = projects.filter { project in
            !named.contains(project) && !self.sessions(in: project, of: roots, query: query, client: client(project)).isEmpty
        }
        return named + (roots.contains { matches($0, query) } ? [.all] : []) + holding
    }
    /// In the order they were given, which is the dock's. A workspace lists only its client's sessions;
    /// "all" is the one place that crosses clients. A workspace named by the search shows everything of
    /// that client in it; otherwise only what the search found. Nothing Enter cannot reach is listed.
    static func sessions(in project: QuickInputProject?, of sessions: [AgentDockSession], query: String, client: QuickInputClient? = nil) -> [AgentDockSession] {
        guard let project else { return [] }
        let roots = sessions.filter { $0.parentSessionID == nil && canOpen($0) }
        let inside = project.isAll ? roots : roots.filter { path(of: $0) == project.path && (client == nil || self.client(of: $0) == client) }
        let found = query.isEmpty || (!project.isAll && project.path.localizedCaseInsensitiveContains(query)) ? inside : inside.filter { matches($0, query) }
        return Array(found.prefix(40))
    }
    /// The state of the session, which is all a row needs to say. What the keys do is on the keys.
    static func status(_ session: AgentDockSession) -> (text: String, tone: QuickInputRow.Tone) {
        if isWaiting(session) { return ("等你处理", .attention) }
        if session.running { return ("运行中", .working) }
        return ("空闲", .plain)
    }
}

struct QuickInputMemory: Codable, Equatable {
    var lastClient: String?
    var lastProject: String?
    var projectClients: [String: String] = [:]
    var recents: [String] = []
    mutating func remember(client: QuickInputClient, project: String) {
        lastClient = client.rawValue; lastProject = project
        projectClients[project] = client.rawValue
        recents.removeAll { $0 == project }
        recents.insert(project, at: 0)
        if recents.count > 12 { recents.removeLast(recents.count - 12) }
    }
}

struct QuickInputReceipt: Identifiable, Equatable {
    enum Tone: Equatable { case progress, success, note, warning, failure }
    enum Action: Equatable { case open(AgentDockSession), restore(String), activate(String), dismiss }
    let id = UUID()
    let title: String
    let body: String
    let tone: Tone
    var actions: [Action] = []
    /// Results the user has to deal with stay until they do; everything else fades on its own.
    var lingers: Bool { tone == .warning || tone == .failure || tone == .progress }
    static func == (lhs: QuickInputReceipt, rhs: QuickInputReceipt) -> Bool { lhs.id == rhs.id }
}

/// Everything that touches the world outside the panel, replaceable in checks.
struct QuickInputEnvironment {
    var open: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    var isAvailable: (QuickInputClient) -> Bool = { client in
        if client.runsInTerminal { return QuickInputRun.executable(for: client, searchPath: ProcessInfo.processInfo.environment["PATH"] ?? "") != nil }
        return client.appLink(path: "/", prompt: nil).flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) } != nil
    }
    var copy: (String) -> Void = { NSPasteboard.general.clearContents(); NSPasteboard.general.setString($0, forType: .string) }
    var directoryExists: (String) -> Bool = { path in
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
    var chooseDirectory: () -> String? = { nil }
    /// Returns the terminal's bundle ID, or nil when nothing could be started.
    var run: (QuickInputRun.Request) -> String? = QuickInputLauncher.launch
    var activate: (String) -> Void = { bundle in NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.activate() }
    var startTimeout: TimeInterval = 25
    /// False when Claude Code's command line is known not to work; nil when it cannot be told.
    var claudeCodeReadiness: () -> Bool? = QuickInputReadiness.claudeCode
    /// Sessions a live process still holds, with that process.
    var liveSessions: () -> [String: pid_t] = QuickInputLiveness.current
    var bringOwnerForward: (pid_t) -> Bool = QuickInputLiveness.bringOwnerForward(of:)
    /// Checks supply their own chooser; the real one needs the panel to hand focus back to.
    var usesSystemChooser = true
}

/// One rule for the keys: Enter hands the text over the quickest way there is, sending it and
/// leaving you where you are if that is possible, carrying it there if not. ⌘Enter is for following
/// it there. WAW delivers and watches; the conversation stays in the agent's own client.
final class QuickInputModel: ObservableObject {
    static let messageLimit = 16_384
    let state: AppState
    private var environment: QuickInputEnvironment
    @Published private(set) var draft = ""
    @Published private(set) var draftRevision = 0
    @Published private(set) var target: QuickInputTarget?
    @Published private(set) var project: QuickInputProject?
    @Published private(set) var pickerKind: QuickInputPickerKind?
    @Published private(set) var pickerQuery = ""
    @Published private(set) var pickerNote: String?
    @Published private(set) var selection = 0
    @Published private(set) var workspaceIndex = 0
    @Published private(set) var sessionIndex = 1
    @Published private var chosenPane: QuickInputPlacePane?
    @Published private(set) var notice: String?
    @Published private(set) var warning: String?
    @Published private(set) var receipt: QuickInputReceipt?
    @Published private(set) var memory: QuickInputMemory
    @Published private var claudeCodeWorks = true
    @Published private var live: [String: pid_t] = [:]
    @Published private var available: Set<QuickInputClient> = []
    private var pickerToken: NSRange?
    /// The trigger was put there to make a list searchable, so it leaves with the list. Whether a
    /// space went in front of it, so that goes too.
    private var tokenInserted = false
    private var tokenSpaced = false
    private var clientPicked = false
    private var pendingStart: PendingStart?
    private var subscriptions: Set<AnyCancellable> = []
    var onDismiss: () -> Void = {}
    /// Called once with the outgoing text; the panel flies it to the dock, then calls `finish`.
    var onDispatch: (WorkSource, String, @escaping () -> Void) -> Void = { _, _, finish in finish() }

    private struct PendingStart {
        let id = UUID()
        let client: QuickInputClient
        let path: String
        let known: Set<String>
        let resuming: String?
        let terminal: String
    }

    init(state: AppState, environment: QuickInputEnvironment = QuickInputEnvironment()) {
        self.state = state; self.environment = environment
        memory = state.quickInputDefaults.data(forKey: "quickInput.memory").flatMap { try? JSONDecoder().decode(QuickInputMemory.self, from: $0) } ?? QuickInputMemory()
        state.$agentDashboard.sink { [weak self] data in self?.watchStart(data) }.store(in: &subscriptions)
    }
    func setDirectoryChooser(_ choose: @escaping () -> String?) { environment.chooseDirectory = choose }

    // MARK: What is on show

    var pickerVisible: Bool {
        switch pickerKind {
        case .agent: return !rows.isEmpty || pickerToken == nil
        case .place: return !workspaces.isEmpty || pickerToken == nil
        case nil: return false
        }
    }
    var selectedSources: [WorkSource] { WorkSource.dockOrder.filter { state.selectedSources.contains($0) } }
    /// The clients on offer: watched, and actually on this Mac.
    var clients: [QuickInputClient] {
        QuickInputClient.allCases.filter { state.selectedSources.contains($0.source) && available.contains($0) }
    }
    /// The dock's rows, in the dock's order. A pending request counts as waiting even when
    /// the session's own record has not caught up.
    var dockSessions: [AgentDockSession] {
        state.sessionRows(for: selectedSources).map { row in
            var session = row.session
            session.event = row.event
            return session
        }
    }
    var targetSession: AgentDockSession? {
        guard case .session(let identity) = target else { return nil }
        return dockSessions.first { $0.dockIdentity == identity }
    }
    var targetClient: QuickInputClient? {
        if case .client(let client) = target { return client }
        return targetSession.flatMap(QuickInputCatalog.client(of:))
    }
    var projects: [QuickInputProject] {
        QuickInputCatalog.projects(sessions: dockSessions, recents: memory.recents, exists: environment.directoryExists)
    }
    var rows: [QuickInputRow] {
        guard pickerKind == .agent else { return [] }
        return QuickInputCatalog.clientRows(clients: clients, claudeCodeWorks: claudeCodeWorks, quota: state.dockQuota(for:), query: pickerQuery)
    }
    var workspaces: [QuickInputProject] {
        QuickInputCatalog.workspaces(projects: projects, sessions: dockSessions, query: pickerQuery, client: client(for:))
    }
    var focusedWorkspace: QuickInputProject? {
        let list = workspaces
        return list.isEmpty ? nil : list[min(workspaceIndex, list.count - 1)]
    }
    var focusedSessions: [AgentDockSession] {
        QuickInputCatalog.sessions(in: focusedWorkspace, of: dockSessions, query: pickerQuery, client: focusedWorkspace.flatMap(client(for:)))
    }
    func sessionCount(in project: QuickInputProject) -> Int {
        QuickInputCatalog.sessions(in: project, of: dockSessions, query: "", client: client(for: project)).count
    }
    /// A search that only found a session title lands on that session, so Enter cannot start a new one by accident.
    var placePane: QuickInputPlacePane {
        if let chosenPane { return chosenPane }
        if !pickerQuery.isEmpty, let focus = focusedWorkspace, !focus.path.localizedCaseInsensitiveContains(pickerQuery), !focusedSessions.isEmpty { return .sessions }
        return .workspaces
    }
    private var selectedPlaceSession: AgentDockSession? {
        guard pickerKind == .place, placePane == .sessions, sessionIndex > 0 else { return nil }
        let sessions = focusedSessions
        return sessions.indices.contains(sessionIndex - 1) ? sessions[sessionIndex - 1] : nil
    }
    /// The client a workspace would start with, as `pick(workspace:)` decides it.
    func client(for workspace: QuickInputProject) -> QuickInputClient? {
        if clientPicked { return targetClient }
        return remembered(for: workspace) ?? targetClient
    }
    private func remembered(for workspace: QuickInputProject?) -> QuickInputClient? {
        let saved = workspace.flatMap { memory.projectClients[$0.path] } ?? memory.lastClient
        return saved.flatMap(QuickInputClient.init(rawValue:)).flatMap { clients.contains($0) ? $0 : nil }
    }
    private func canSendNew(_ client: QuickInputClient?) -> Bool {
        guard let client, client.runsInTerminal else { return false }
        return client != .claudeCode || claudeCodeWorks
    }
    private var hasText: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func sendable(_ session: AgentDockSession) -> Bool {
        QuickInputCatalog.canSend(session, claudeCodeWorks: claudeCodeWorks, live: Set(live.keys))
    }
    /// Whether Enter sends right now: there is something to send and somewhere that takes it.
    var canSendNow: Bool {
        guard !pickerVisible, hasText else { return false }
        if let session = targetSession { return sendable(session) }
        return project != nil && canSendNew(targetClient)
    }
    /// What Enter does, written on the button. Without a way to send it carries the text there;
    /// with nothing to hand over it simply opens.
    var primaryVerb: String {
        if pickerVisible { return pickerKind == .place && placePane == .workspaces && focusedWorkspace?.isAll == true ? "选会话" : "选中" }
        if targetSession == nil, targetClient == nil || project == nil { return "下一步" }
        if canSendNow { return "发送" }
        return hasText ? "带过去" : "打开"
    }
    /// ⌘Enter follows the text there. It is only offered where it differs from Enter, or from a
    /// list, where Enter only chooses.
    var secondaryVerb: String? {
        if pickerVisible {
            if pickerKind == .agent { return project != nil && !rows.isEmpty ? "打开" : nil }
            if selectedPlaceSession != nil { return "打开" }
            guard let focus = focusedWorkspace, !focus.isAll else { return nil }
            return client(for: focus) == nil ? nil : "打开"
        }
        return canSendNow ? "打开" : nil
    }
    var hint: String? {
        if notice != nil { return notice }
        if target == nil && project == nil { return "只选这一次，之后每个工作区记住上次的选择。" }
        if targetSession == nil, targetClient == .claudeCode, !claudeCodeWorks { return "命令行未登录，发不了，只能带过去。" }
        return nil
    }

    // MARK: Editing

    func prepareForSummon() {
        notice = nil; closePicker()
        available = Set(QuickInputClient.allCases.filter(environment.isAvailable))
        let readiness = environment.claudeCodeReadiness, liveSessions = environment.liveSessions
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let works = readiness() != false, held = liveSessions()
            DispatchQueue.main.async { self?.claudeCodeWorks = works; self?.live = held }
        }
        if case .session = target, targetSession == nil { target = nil }
        if target == nil {
            if project == nil, let last = memory.lastProject, environment.directoryExists(last) { project = QuickInputProject(path: last) }
            applyRemembered()
        }
    }
    private func applyRemembered() {
        if let client = remembered(for: project) { target = .client(client) }
    }
    func textChanged(_ text: String, cursor: Int) {
        draft = text; notice = nil
        syncToken(cursor: cursor)
    }
    func cursorMoved(_ cursor: Int) {
        // The cursor left a trigger that was put there for the list: the text is untouched, so it can go.
        if tokenInserted, QuickInputToken.match(in: draft, cursor: cursor) == nil { closePicker(); return }
        syncToken(cursor: cursor)
    }
    private func syncToken(cursor: Int) {
        if let match = QuickInputToken.match(in: draft, cursor: cursor) {
            let kind: QuickInputPickerKind = match.trigger == "@" ? .agent : .place
            if pickerKind != kind || pickerQuery != match.query { selection = 0; workspaceIndex = 0; sessionIndex = 1; chosenPane = nil }
            pickerKind = kind; pickerQuery = match.query; pickerToken = match.range; pickerNote = nil
        } else if pickerToken != nil { tokenInserted = false; closePicker() }
    }

    // MARK: Pickers. Enter, Tab or a click only chooses, so choosing can never send anything.

    func togglePicker(_ kind: QuickInputPickerKind) {
        if pickerKind == kind { closePicker() } else { openPicker(kind, note: nil) }
    }
    /// However a list opens, it works the same: the trigger goes into the text, so typing searches
    /// exactly as it does after pressing `@` or `#` by hand.
    private func openPicker(_ kind: QuickInputPickerKind, note: String?) {
        closePicker()
        tokenSpaced = !draft.isEmpty && draft.last?.isWhitespace == false
        let trigger = kind == .agent ? "@" : "#"
        setDraft(draft + (tokenSpaced ? " " : "") + trigger)
        pickerToken = NSRange(location: (draft as NSString).length - 1, length: 1)
        tokenInserted = true
        pickerKind = kind; pickerQuery = ""; pickerNote = note; selection = 0; sessionIndex = 1; chosenPane = nil
        workspaceIndex = project.flatMap { current in workspaces.firstIndex(of: current) } ?? 0
    }
    func closePicker() {
        if tokenInserted { removeToken() }
        tokenInserted = false
        pickerKind = nil; pickerQuery = ""; pickerToken = nil; pickerNote = nil; selection = 0; chosenPane = nil
    }
    func moveSelection(_ delta: Int) {
        switch pickerKind {
        case .agent: selection = min(max(0, rows.count - 1), max(0, selection + delta))
        case .place:
            if placePane == .sessions {
                chosenPane = .sessions
                sessionIndex = min(focusedSessions.count, max(focusedWorkspace?.isAll == true ? 1 : 0, sessionIndex + delta))
            } else {
                chosenPane = .workspaces
                workspaceIndex = min(max(0, workspaces.count - 1), max(0, workspaceIndex + delta))
                sessionIndex = 1
            }
        case nil: break
        }
    }
    func focusWorkspace(at index: Int) {
        guard pickerKind == .place, workspaces.indices.contains(index), workspaceIndex != index || placePane != .workspaces else { return }
        workspaceIndex = index; chosenPane = .workspaces; sessionIndex = 1
    }
    func enterSessions() {
        guard pickerKind == .place, focusedWorkspace != nil else { return }
        guard focusedWorkspace?.isAll != true || !focusedSessions.isEmpty else { return }
        chosenPane = .sessions; sessionIndex = focusedSessions.isEmpty ? 0 : 1
    }
    func leaveSessions() { if pickerKind == .place { chosenPane = .workspaces } }
    func pickSelected() {
        switch pickerKind {
        case .agent:
            let current = rows
            if current.indices.contains(selection) { pick(current[selection]) } else { closePicker() }
        case .place:
            if let session = selectedPlaceSession { pick(session: session) }
            else if let focus = focusedWorkspace { pick(workspace: focus) }
            else { closePicker() }
        case nil: break
        }
    }
    func pick(_ row: QuickInputRow) {
        removeToken(); target = .client(row.client); clientPicked = true; warning = nil
        closePicker()
        if project == nil { openPicker(.place, note: "还差工作区，内容不会丢。") }
    }
    func pick(workspace: QuickInputProject) {
        guard !workspace.isAll else { enterSessions(); return }
        removeToken()
        project = workspace
        if case .session = target { target = nil }
        if !clientPicked { applyRemembered() }
        closePicker()
        if target == nil { openPicker(.agent, note: "还差谁来做，内容不会丢。") }
    }
    func pick(session: AgentDockSession) {
        removeToken(); target = .session(session.dockIdentity); warning = nil
        if let path = QuickInputCatalog.path(of: session) { project = QuickInputProject(path: path) }
        closePicker()
    }
    func browseForWorkspace() {
        guard let path = environment.chooseDirectory() else { return }
        pick(workspace: QuickInputProject(path: path))
    }
    private func removeToken() {
        guard var token = pickerToken, token.location + token.length <= (draft as NSString).length else { return }
        if tokenInserted, tokenSpaced, token.location > 0 { token = NSRange(location: token.location - 1, length: token.length + 1) }
        setDraft((draft as NSString).replacingCharacters(in: token, with: ""))
        pickerToken = nil; tokenInserted = false
    }
    private func setDraft(_ text: String) { draft = text; draftRevision += 1 }
    func clearSessionTarget() {
        if let client = targetClient, clients.contains(client) { target = .client(client) }
        else { target = nil; applyRemembered() }
    }

    // MARK: Enter and ⌘Enter

    func submit(go: Bool = false) {
        if pickerVisible {
            // Entering "all sessions" is the one step in a list that chooses nothing.
            if pickerKind == .place, placePane == .workspaces, focusedWorkspace?.isAll == true { enterSessions(); return }
            guard !go || secondaryVerb != nil else { return }
            pickSelected()
            if pickerVisible || !go { return }
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .session = target {
            guard let session = targetSession else { target = nil; notice = "这个会话已不在列表里，换一个吧。"; return }
            if !go, canSendNow { send(text, to: session) } else { open(session, text: text) }
            return
        }
        guard case .client(let client) = target else { openPicker(.agent, note: "先选谁来做，内容不会丢。"); return }
        guard let project else { openPicker(.place, note: "还差工作区，内容不会丢。"); return }
        if !go, canSendNow { start(text, client: client, in: project) } else { open(client, in: project, text: text) }
    }

    // MARK: Going there

    /// Whatever can be filled in is; whatever cannot goes on the clipboard.
    private func open(_ client: QuickInputClient, in project: QuickInputProject, text: String) {
        var copied = false
        if client.runsInTerminal {
            guard environment.run(.init(command: .new(client), directory: project.path)) != nil else { notice = "没能启动 \(client.title)。确认它已安装。"; return }
            copied = !text.isEmpty
        } else {
            let fits = text.count <= QuickInputClient.promptLimit
            guard let url = client.appLink(path: project.path, prompt: fits && !text.isEmpty ? text : nil), environment.open(url) else { notice = "没能打开 \(client.title)，内容还在。"; return }
            copied = !fits
        }
        if copied { environment.copy(text) }
        remember(client, project: project.path)
        finishComposing()
        onDismiss()
        if copied { receipt = QuickInputReceipt(title: "内容已复制", body: "粘贴后发送。", tone: .note) }
    }

    /// The order every session is tried in, so none is a dead end: its own route, the terminal its
    /// process runs in, or resuming it. Only a session running somewhere unknown has nowhere to go.
    /// Codex threads take the text directly; everywhere else it waits on the clipboard.
    private func open(_ session: AgentDockSession, text: String) {
        var arrived = false, filled = false
        if session.navigationURL != nil || session.localSessionLock != nil || session.localBridgeRoot != nil {
            if !text.isEmpty, text.count <= QuickInputClient.promptLimit, let url = QuickInputClient.threadLink(session, prompt: text), environment.open(url) { filled = true }
            else { state.openAgentSession(session) }
            arrived = true
        } else if let pid = live[session.id] {
            arrived = environment.bringOwnerForward(pid)
        } else if !session.running, let directory = QuickInputCatalog.path(of: session), environment.directoryExists(directory) {
            arrived = resume(session, directory: directory)
        }
        if !text.isEmpty, !filled { environment.copy(text) }
        finishComposing()
        onDismiss()
        if !arrived {
            receipt = QuickInputReceipt(title: "回到它所在的窗口", body: text.isEmpty ? "这个会话运行在没有跳转入口的地方。" : "这个会话运行在没有跳转入口的地方。内容已复制。", tone: .note)
        } else if !text.isEmpty, !filled {
            receipt = QuickInputReceipt(title: "内容已复制", body: "粘贴后发送。", tone: .note)
        }
    }
    private func resume(_ session: AgentDockSession, directory: String) -> Bool {
        let command: QuickInputRun.Command?
        switch QuickInputCatalog.client(of: session) {
        case .codexCLI where UUID(uuidString: session.id) != nil: command = .resume(.codexCLI, id: session.id)
        case .claudeCode where UUID(uuidString: session.id) != nil: command = .resume(.claudeCode, id: session.id)
        default: command = session.resumeCommand.map(QuickInputRun.Command.recorded)
        }
        guard let command else { return false }
        return environment.run(.init(command: command, directory: directory)) != nil
    }

    // MARK: Sending

    private func start(_ text: String, client: QuickInputClient, in project: QuickInputProject) {
        let known = Set(dockSessions.map(\.dockIdentity))
        guard let terminal = environment.run(.init(command: .new(client), directory: project.path, prompt: text, background: true)) else {
            notice = "没能启动 \(client.title)。确认它已安装。"; return
        }
        remember(client, project: project.path)
        watch(.init(client: client, path: project.path, known: known, resuming: nil, terminal: terminal), text: text, place: project.name)
    }
    private func watch(_ pending: PendingStart, text: String, place: String) {
        pendingStart = pending
        finishComposing()
        onDismiss()
        let client = pending.client
        onDispatch(client.source, text) { [weak self] in
            guard let self else { return }
            self.pulse(client.source)
            guard self.pendingStart?.id == pending.id else { return }
            self.receipt = QuickInputReceipt(title: "正在启动 \(client.title)…", body: place + " · 在后台终端开工。", tone: .progress)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + environment.startTimeout) { [weak self] in
            guard let self, self.pendingStart?.id == pending.id else { return }
            self.pendingStart = nil
            self.receipt = QuickInputReceipt(title: "还没看到 \(client.title) 开始工作", body: "它可能在终端里等你确认，比如是否信任这个目录。", tone: .warning,
                                             actions: [.activate(pending.terminal), .dismiss])
        }
    }
    /// A new session for that client in that directory, or the resumed one coming back to life, is the proof.
    private func watchStart(_ data: AgentDockData) {
        guard let pending = pendingStart else { return }
        let found = data.sessions.first { session in
            guard QuickInputCatalog.client(of: session)?.source == pending.client.source else { return false }
            if let resuming = pending.resuming { return session.dockIdentity == resuming && session.running }
            return !pending.known.contains(session.dockIdentity) && QuickInputCatalog.path(of: session) == pending.path
        }
        guard let found else { return }
        pendingStart = nil
        receipt = QuickInputReceipt(title: "交给 \(pending.client.title) 了", body: found.title, tone: .success)
    }

    private func send(_ text: String, to session: AgentDockSession) {
        guard text.utf8.count <= Self.messageLimit else { notice = "内容太长，请缩短一些。"; return }
        if !session.canSend {
            guard let client = QuickInputCatalog.client(of: session), let directory = QuickInputCatalog.path(of: session) else { return }
            guard let terminal = environment.run(.init(command: .resume(client, id: session.id), directory: directory, prompt: text, background: true)) else {
                notice = "没能启动 \(client.title)。确认它已安装。"; return
            }
            remember(client, project: directory)
            watch(.init(client: client, path: directory, known: [], resuming: session.dockIdentity, terminal: terminal), text: text, place: session.title)
            return
        }
        if let directory = QuickInputCatalog.path(of: session) { remember(.codexApp, project: directory) }
        finishComposing()
        onDismiss()
        onDispatch(session.source, text) { [weak self] in
            guard let self else { return }
            self.receipt = QuickInputReceipt(title: "正在发送…", body: "等待对方确认收到。", tone: .progress)
            self.pulse(session.source)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let outcome = await self.state.sendAgentMessage(session, text)
                self.report(outcome, text: text, session: session)
            }
        }
    }
    private func pulse(_ source: WorkSource) {
        state.quickInputPulse.source = source
        state.quickInputPulse.landings += 1
    }
    private func report(_ outcome: AgentMessageOutcome, text: String, session: AgentDockSession) {
        switch outcome {
        case .accepted:
            receipt = QuickInputReceipt(title: outcome.title, body: session.title + " 开始新一轮。", tone: .success, actions: [.open(session)])
        case .steered:
            receipt = QuickInputReceipt(title: outcome.title, body: session.title + " 已确认收到。", tone: .success, actions: [.open(session)])
        case .uncertain:
            warning = "上一条结果待确认，再发可能执行两遍。"
            receipt = QuickInputReceipt(title: "发送结果待确认", body: "可能已经送达。先看原会话，别重复发送。内容替你留着。", tone: .warning,
                                        actions: [.open(session), .restore(text), .dismiss])
            target = .session(session.dockIdentity)
        case .unavailable, .failed:
            state.quickInputPulse.source = session.source
            state.quickInputPulse.rejections += 1
            let detail: String
            if case .failed(let message) = outcome { detail = message } else { detail = "原会话当前不接收消息。" }
            receipt = QuickInputReceipt(title: "没送到", body: detail + "内容还在。", tone: .failure, actions: [.open(session), .restore(text), .dismiss])
            target = .session(session.dockIdentity)
        }
    }

    func perform(_ action: QuickInputReceipt.Action) {
        switch action {
        case .open(let session): state.openAgentSession(session); receipt = nil
        case .restore(let text): restore(text); receipt = nil; state.quickInputSummon.send()
        case .activate(let bundle): environment.activate(bundle); receipt = nil
        case .dismiss: receipt = nil
        }
    }
    func dismissReceipt() { receipt = nil }
    private func restore(_ text: String) {
        let current = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current != text else { return }
        setDraft(current.isEmpty ? text : current + "\n\n" + text)
    }
    private func remember(_ client: QuickInputClient, project path: String) {
        memory.remember(client: client, project: path)
        if let data = try? JSONEncoder().encode(memory) { state.quickInputDefaults.set(data, forKey: "quickInput.memory") }
    }
    private func finishComposing() {
        setDraft(""); notice = nil; warning = nil; closePicker(); clientPicked = false
        project = memory.lastProject.map(QuickInputProject.init(path:))
        target = nil
        applyRemembered()
    }
}
