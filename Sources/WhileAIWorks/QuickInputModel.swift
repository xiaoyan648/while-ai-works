import AppKit
import AgentHUDCore
import Combine

struct QuickInputProject: Equatable, Identifiable, Codable {
    let path: String
    var id: String { path }
    var name: String { isAll ? "全部会话" : URL(fileURLWithPath: path).lastPathComponent }
    /// Every session, including those with no directory or one that no longer exists.
    static let all = QuickInputProject(path: "")
    var isAll: Bool { path.isEmpty }
}

enum QuickInputTarget: Equatable {
    case agent(WorkSource)
    case session(String)
}

enum QuickInputPickerKind: Equatable { case agent, place }
enum QuickInputPlacePane: Equatable { case workspaces, sessions }

struct QuickInputRow: Identifiable, Equatable {
    enum Tone: Equatable { case plain, working, attention }
    let id: String
    let source: WorkSource
    let title: String
    let subtitle: String
    var trailing = ""
    var tone = Tone.plain
    var enabled = true
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

/// What each client can do. The panel offers only what is declared here, and a new client
/// needs an entry rather than a new interaction.
struct QuickInputCapabilities: Equatable {
    /// Start a session that begins working on the text at once.
    var start = false
    /// Open the client with the text filled in, leaving the send to the user.
    var prefill = false
    static func of(_ source: WorkSource) -> QuickInputCapabilities {
        switch source {
        case .codex, .claude: return .init(start: true, prefill: true)
        case .hermes: return .init(start: true)
        case .dsh, .qoder, .workbuddy: return .init()
        }
    }
}

/// Official deep links only fill the client's composer. The user still presses send there.
enum QuickInputHandoff {
    static let promptLimit = 5000
    /// Claude's desktop app takes a new Code session when it is installed; the link for it comes from
    /// the app's own handler rather than its documentation, so the terminal link stays as the fallback.
    static let claudeDesktopProbe = URL(string: "claude://code/new")!
    static func destination(_ source: WorkSource, claudeDesktop: Bool) -> String {
        source == .claude ? (claudeDesktop ? "Claude" : "终端") : source.clientName
    }
    static func url(source: WorkSource, path: String, prompt: String?, claudeDesktop: Bool = false) -> URL? {
        var fields: [(String, String)]
        let base: String
        switch source {
        case .codex: base = "codex://new"; fields = [("path", path)]; if let prompt { fields.append(("prompt", prompt)) }
        case .claude where claudeDesktop: base = "claude://code/new"; fields = [("folder", path), ("source", "while-ai-works")]; if let prompt { fields.append(("q", prompt)) }
        case .claude: base = "claude-cli://open"; fields = [("cwd", path)]; if let prompt { fields.append(("q", prompt)) }
        default: return nil
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let query = fields.compactMap { name, value in value.addingPercentEncoding(withAllowedCharacters: allowed).map { name + "=" + $0 } }
        return URL(string: base + "?" + query.joined(separator: "&"))
    }
    static func missingHandler(_ source: WorkSource) -> String {
        source == .claude ? "还不能打开 Claude Code。在终端运行一次 claude 并发送一条消息后再试。" : "没有找到 \(source.clientName) 桌面端。"
    }
}

/// A new session runs in a real terminal the user can take over: its interactive mode is what
/// keeps approvals and hooks working, and the process does not belong to WAW, so quitting or
/// updating WAW leaves the task running. The prompt travels through a private file, so neither
/// the shell nor the terminal ever parses it.
enum QuickInputStart {
    struct Request: Equatable {
        let source: WorkSource
        let directory: String
        let prompt: String
    }
    static func arguments(source: WorkSource, executable: String, directory: String) -> [String]? {
        switch source {
        case .claude: return [quote(executable), "--", "\"$prompt\""]
        case .codex: return [quote(executable), "-C", quote(directory), "--", "\"$prompt\""]
        case .hermes: return [quote(executable), "chat", "--in", quote(directory), "--query=\"$prompt\""]
        default: return nil
        }
    }
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func script(source: WorkSource, executable: String, directory: String, promptFile: String, searchPath: String) -> String? {
        guard let command = arguments(source: source, executable: executable, directory: directory) else { return nil }
        return """
        #!/bin/zsh -f
        export PATH=\(quote(searchPath))
        cd -- \(quote(directory)) || exit 1
        prompt="$(cat -- \(quote(promptFile)))"
        rm -f -- \(quote(promptFile)) "$0"
        \(command.joined(separator: " "))
        code=$?
        if [ $code -ne 0 ]; then print; print "启动失败（退出码 $code）。可以关闭这个窗口。"; read -k1 -s; fi

        """
    }
    static func executable(for source: WorkSource, searchPath: String) -> String? {
        if source == .codex { return CodexLocator.find(path: searchPath)?.path }
        let name = source == .claude ? "claude" : source == .hermes ? "hermes" : nil
        guard let name else { return nil }
        return searchPath.split(separator: ":").map { String($0) + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Starts the script with whatever opens scripts on this Mac, which is what the user's default
/// terminal means there, then gives the front back to whatever the user was doing.
enum QuickInputLauncher {
    static func launch(_ request: QuickInputStart.Request) -> String? {
        let search = ProcessInfo.processInfo.environment["PATH"] ?? ""
        guard let executable = QuickInputStart.executable(for: request.source, searchPath: search) else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WhileAIWorks-QuickInput", isDirectory: true)
        let id = UUID().uuidString
        let promptFile = folder.appendingPathComponent(id + ".txt"), scriptFile = folder.appendingPathComponent(id + ".command")
        guard let script = QuickInputStart.script(source: request.source, executable: executable, directory: request.directory, promptFile: promptFile.path, searchPath: search) else { return nil }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard manager.createFile(atPath: promptFile.path, contents: Data(request.prompt.utf8), attributes: [.posixPermissions: 0o600]),
                  manager.createFile(atPath: scriptFile.path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o700]) else { return nil }
        } catch { return nil }
        let workspace = NSWorkspace.shared
        func discard() { try? manager.removeItem(at: promptFile); try? manager.removeItem(at: scriptFile) }
        guard let handler = workspace.urlForApplication(toOpen: scriptFile), let terminal = Bundle(url: handler)?.bundleIdentifier else { discard(); return nil }
        let previous = workspace.frontmostApplication
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", scriptFile.path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { discard(); return nil }
        returnFront(to: previous, from: terminal, deadline: Date().addingTimeInterval(2))
        return terminal
    }
    private static func returnFront(to previous: NSRunningApplication?, from terminal: String, deadline: Date) {
        guard let previous, previous.bundleIdentifier != terminal else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == terminal { previous.activate() }
            else if Date() < deadline { returnFront(to: previous, from: terminal, deadline: deadline) }
        }
    }
}

enum QuickInputCatalog {
    static func path(of session: AgentDockSession) -> String? {
        session.workingDirectory ?? session.project.flatMap { $0.hasPrefix("/") ? $0 : nil }
    }
    static func isWaiting(_ session: AgentDockSession) -> Bool { session.event == .approval || session.event == .input }
    /// Whether a message can go straight in. Anything else opens in its client instead.
    static func takesMessages(_ session: AgentDockSession) -> Bool { session.canSend && !isWaiting(session) }

    /// Workspaces in the dock's order, so the busiest come first; recently used ones follow.
    static func projects(sessions: [AgentDockSession], recents: [String], exists: (String) -> Bool) -> [QuickInputProject] {
        var seen = Set<String>()
        return (sessions.compactMap(path) + recents).filter { seen.insert($0).inserted && exists($0) }.map { QuickInputProject(path: $0) }
    }

    static func agentRows(sources: [WorkSource], quota: (WorkSource) -> AgentDockQuota?, query: String) -> [QuickInputRow] {
        sources.filter { query.isEmpty || $0.clientName.localizedCaseInsensitiveContains(query) || $0.rawValue.localizedCaseInsensitiveContains(query) }.map { source in
            let capable = QuickInputCapabilities.of(source).start
            let reading = quota(source).flatMap { $0.stale ? nil : $0.remaining }
            return QuickInputRow(id: "agent:" + source.rawValue, source: source, title: source.clientName,
                subtitle: capable ? "在后台终端开工，进度看猫条" : "暂时不能接收任务",
                trailing: reading.map { "额度 \(Int($0.rounded()))%" } ?? "", tone: (reading ?? 100) <= 15 ? .attention : .plain, enabled: capable)
        }
    }

    private static func matches(_ session: AgentDockSession, _ query: String) -> Bool {
        session.title.localizedCaseInsensitiveContains(query) || session.source.clientName.localizedCaseInsensitiveContains(query)
    }
    /// Without a search, everything under "all" first. With one, workspaces named by it come first,
    /// then "all" for the sessions it found, then the workspaces those sessions live in.
    static func workspaces(projects: [QuickInputProject], sessions: [AgentDockSession], query: String) -> [QuickInputProject] {
        guard !query.isEmpty else { return [.all] + projects.prefix(30) }
        let roots = sessions.filter { $0.parentSessionID == nil }
        let named = projects.filter { $0.path.localizedCaseInsensitiveContains(query) }
        let holding = projects.filter { project in !named.contains(project) && roots.contains { path(of: $0) == project.path && matches($0, query) } }
        return named + (roots.contains { matches($0, query) } ? [.all] : []) + holding
    }
    /// In the order they were given, which is the dock's. A workspace named by the search shows
    /// everything in it; otherwise only the sessions the search found.
    static func sessions(in project: QuickInputProject?, of sessions: [AgentDockSession], query: String) -> [AgentDockSession] {
        guard let project else { return [] }
        let roots = sessions.filter { $0.parentSessionID == nil }
        let inside = project.isAll ? roots : roots.filter { path(of: $0) == project.path }
        let found = query.isEmpty || (!project.isAll && project.path.localizedCaseInsensitiveContains(query)) ? inside : inside.filter { matches($0, query) }
        return Array(found.prefix(40))
    }
    static func sessionRow(_ session: AgentDockSession) -> QuickInputRow {
        let waiting = isWaiting(session)
        return QuickInputRow(id: "session:" + session.dockIdentity, source: session.source, title: session.title, subtitle: "",
            trailing: waiting ? "等你处理" : session.running ? "运行中" : !session.canSend ? "仅打开" : "空闲",
            tone: waiting ? .attention : session.running ? .working : .plain)
    }
}

struct QuickInputMemory: Codable, Equatable {
    var lastAgent: String?
    var lastProject: String?
    var projectAgents: [String: String] = [:]
    var recents: [String] = []
    mutating func remember(agent: WorkSource, project: String) {
        lastAgent = agent.rawValue; lastProject = project
        projectAgents[project] = agent.rawValue
        recents.removeAll { $0 == project }
        recents.insert(project, at: 0)
        if recents.count > 12 { recents.removeLast(recents.count - 12) }
    }
}

struct QuickInputReceipt: Identifiable, Equatable {
    enum Tone: Equatable { case progress, success, handedOff, warning, failure }
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
    var canOpen: (URL) -> Bool = { NSWorkspace.shared.urlForApplication(toOpen: $0) != nil }
    var copy: (String) -> Void = { NSPasteboard.general.clearContents(); NSPasteboard.general.setString($0, forType: .string) }
    var directoryExists: (String) -> Bool = { path in
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
    var chooseDirectory: () -> String? = { nil }
    /// Returns the terminal's bundle ID, or nil when nothing could be started.
    var start: (QuickInputStart.Request) -> String? = QuickInputLauncher.launch
    var activate: (String) -> Void = { bundle in NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.activate() }
    var startTimeout: TimeInterval = 25
    /// Checks supply their own chooser; the real one needs the panel to hand focus back to.
    var usesSystemChooser = true
}

/// The draft, who receives it and what pressing Enter does. WAW delivers and watches;
/// the conversation itself stays in the agent's own client.
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
    private var pickerToken: NSRange?
    private var agentPicked = false
    private var pendingStart: PendingStart?
    private var subscriptions: Set<AnyCancellable> = []
    var onDismiss: () -> Void = {}
    /// Called once with the outgoing text; the panel flies it to the dock, then calls `finish`.
    var onDispatch: (WorkSource, String, @escaping () -> Void) -> Void = { _, _, finish in finish() }

    private struct PendingStart {
        let id = UUID()
        let source: WorkSource
        let path: String
        let known: Set<String>
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
    var targetAgent: WorkSource? {
        if case .agent(let source) = target { return source }
        return targetSession?.source
    }
    var projects: [QuickInputProject] {
        QuickInputCatalog.projects(sessions: dockSessions, recents: memory.recents, exists: environment.directoryExists)
    }
    var rows: [QuickInputRow] {
        pickerKind == .agent ? QuickInputCatalog.agentRows(sources: selectedSources, quota: state.dockQuota(for:), query: pickerQuery) : []
    }
    var workspaces: [QuickInputProject] {
        QuickInputCatalog.workspaces(projects: projects, sessions: dockSessions, query: pickerQuery)
    }
    var focusedWorkspace: QuickInputProject? {
        let list = workspaces
        return list.isEmpty ? nil : list[min(workspaceIndex, list.count - 1)]
    }
    var focusedSessions: [AgentDockSession] {
        QuickInputCatalog.sessions(in: focusedWorkspace, of: dockSessions, query: pickerQuery)
    }
    func sessionCount(in project: QuickInputProject) -> Int {
        QuickInputCatalog.sessions(in: project, of: dockSessions, query: "").count
    }
    /// A search that only found a session title lands on that session, so Enter cannot start a new one by accident.
    var placePane: QuickInputPlacePane {
        if let chosenPane { return chosenPane }
        if !pickerQuery.isEmpty, let focus = focusedWorkspace, !focus.path.localizedCaseInsensitiveContains(pickerQuery), !focusedSessions.isEmpty { return .sessions }
        return .workspaces
    }
    /// What Enter does right now, written on the button.
    var primaryVerb: String {
        if pickerVisible {
            guard pickerKind == .place else { return "选择" }
            if selectedPlaceSession != nil { return "继续这个会话" }
            return focusedWorkspace?.isAll == true ? "选会话" : "在这里开新会话"
        }
        if let session = targetSession {
            guard QuickInputCatalog.takesMessages(session) else { return "打开会话" }
            return session.running ? "插入当前步" : "发送"
        }
        return targetAgent != nil && project != nil ? "发送" : "下一步"
    }
    /// The session under the cursor in the right column, if any.
    private var selectedPlaceSession: AgentDockSession? {
        guard pickerKind == .place, placePane == .sessions, sessionIndex > 0 else { return nil }
        let sessions = focusedSessions
        return sessions.indices.contains(sessionIndex - 1) ? sessions[sessionIndex - 1] : nil
    }
    /// The agent a workspace would start with, as `pick(workspace:)` decides it.
    private func agent(for workspace: QuickInputProject) -> WorkSource? {
        if agentPicked { return targetAgent }
        return memory.projectAgents[workspace.path].flatMap(WorkSource.init(rawValue:)) ?? targetAgent
    }
    private func openVerb(_ source: WorkSource?) -> String? {
        guard let source, QuickInputCapabilities.of(source).prefill else { return nil }
        return "在 " + destination(source) + " 打开"
    }
    var secondaryVerb: String? {
        if pickerVisible {
            if pickerKind == .agent {
                let current = rows
                guard project != nil, current.indices.contains(selection), current[selection].enabled else { return nil }
                return openVerb(current[selection].source)
            }
            if selectedPlaceSession != nil { return "打开会话" }
            guard let focus = focusedWorkspace, !focus.isAll else { return nil }
            return openVerb(agent(for: focus))
        }
        if let session = targetSession { return QuickInputCatalog.takesMessages(session) ? "打开会话" : nil }
        return project == nil ? nil : openVerb(targetAgent)
    }
    var hint: String? {
        if notice != nil { return notice }
        if target == nil && project == nil { return "只选这一次，之后每个工作区记住上次的选择。" }
        if let session = targetSession, !QuickInputCatalog.takesMessages(session) {
            return QuickInputCatalog.isWaiting(session) ? "它在等你回应，内容会替你复制好。" : "这个会话只能在客户端里继续，内容会替你复制好。"
        }
        return nil
    }

    // MARK: Editing

    func prepareForSummon() {
        notice = nil; closePicker()
        if case .session = target, targetSession == nil { target = nil }
        if target == nil {
            if project == nil, let last = memory.lastProject, environment.directoryExists(last) { project = QuickInputProject(path: last) }
            applyRememberedAgent()
        }
    }
    private var hasClaudeDesktop: Bool { environment.canOpen(QuickInputHandoff.claudeDesktopProbe) }
    private func destination(_ source: WorkSource) -> String { QuickInputHandoff.destination(source, claudeDesktop: source == .claude && hasClaudeDesktop) }
    private func applyRememberedAgent() {
        let remembered = project.flatMap { memory.projectAgents[$0.path] } ?? memory.lastAgent
        guard let source = remembered.flatMap(WorkSource.init(rawValue:)), state.selectedSources.contains(source), QuickInputCapabilities.of(source).start else { return }
        target = .agent(source)
    }
    func textChanged(_ text: String, cursor: Int) {
        draft = text; notice = nil
        syncToken(cursor: cursor)
    }
    func cursorMoved(_ cursor: Int) { syncToken(cursor: cursor) }
    private func syncToken(cursor: Int) {
        if let match = QuickInputToken.match(in: draft, cursor: cursor) {
            let kind: QuickInputPickerKind = match.trigger == "@" ? .agent : .place
            if pickerKind != kind || pickerQuery != match.query { selection = 0; workspaceIndex = 0; sessionIndex = 1; chosenPane = nil }
            pickerKind = kind; pickerQuery = match.query; pickerToken = match.range; pickerNote = nil
        } else if pickerToken != nil { closePicker() }
    }

    // MARK: Pickers

    func togglePicker(_ kind: QuickInputPickerKind) {
        if pickerKind == kind { closePicker() } else { openPicker(kind, note: nil) }
    }
    private func openPicker(_ kind: QuickInputPickerKind, note: String?) {
        pickerKind = kind; pickerQuery = ""; pickerToken = nil; pickerNote = note; selection = 0; sessionIndex = 1; chosenPane = nil
        workspaceIndex = project.flatMap { current in workspaces.firstIndex(of: current) } ?? 0
    }
    func closePicker() { pickerKind = nil; pickerQuery = ""; pickerToken = nil; pickerNote = nil; selection = 0; chosenPane = nil }
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
            let sessions = focusedSessions
            if placePane == .sessions, sessionIndex > 0, sessions.indices.contains(sessionIndex - 1) { pick(session: sessions[sessionIndex - 1]) }
            else if let focus = focusedWorkspace { pick(workspace: focus) }
            else { closePicker() }
        case nil: break
        }
    }
    func pick(_ row: QuickInputRow) {
        guard row.enabled else { pickerNote = row.title + " 暂时不能接收任务，换一个吧。"; return }
        removeToken(); target = .agent(row.source); agentPicked = true; warning = nil
        closePicker()
        if project == nil { openPicker(.place, note: "还差工作区，内容不会丢。") }
    }
    func pick(workspace: QuickInputProject) {
        guard !workspace.isAll else { enterSessions(); return }
        removeToken()
        project = workspace
        if case .session = target { target = nil }
        if !agentPicked { applyRememberedAgent() }
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
        guard let token = pickerToken, token.location + token.length <= (draft as NSString).length else { return }
        setDraft((draft as NSString).replacingCharacters(in: token, with: ""))
        pickerToken = nil
    }
    private func setDraft(_ text: String) { draft = text; draftRevision += 1 }
    func clearSessionTarget() {
        if let source = targetSession?.source, QuickInputCapabilities.of(source).start { target = .agent(source) }
        else { target = nil; applyRememberedAgent() }
    }

    // MARK: Enter

    /// Enter sends and ⌘Enter opens the client. Queueing and interrupting happen there, where the session can be seen.
    /// With nothing typed, ⌘Enter is a plain jump. From an open list it goes straight to what is selected.
    func submit(openClient: Bool = false) {
        if pickerVisible {
            let session = openClient ? selectedPlaceSession : nil
            if let session { removeToken(); closePicker(); open(session, text: draft.trimmingCharacters(in: .whitespacesAndNewlines)); return }
            pickSelected()
            guard openClient, !pickerVisible else { return }
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .session = target {
            guard let session = targetSession else { target = nil; notice = "这个会话已不在列表里，换一个吧。"; return }
            if openClient || !QuickInputCatalog.takesMessages(session) { open(session, text: text); return }
            guard !text.isEmpty else { return }
            guard text.utf8.count <= Self.messageLimit else { notice = "内容太长，请缩短一些。"; return }
            send(text, to: session)
            return
        }
        guard openClient || !text.isEmpty else { return }
        guard case .agent(let source) = target else { openPicker(.agent, note: "先选谁来做，内容不会丢。"); return }
        guard let project else { openPicker(.place, note: "还差工作区，内容不会丢。"); return }
        if openClient {
            if QuickInputCapabilities.of(source).prefill { handOff(text, to: source, in: project) }
        } else { start(text, source: source, in: project) }
    }

    private func start(_ text: String, source: WorkSource, in project: QuickInputProject) {
        let known = Set(state.agentDashboard.sessions.map(\.dockIdentity))
        guard let terminal = environment.start(.init(source: source, directory: project.path, prompt: text)) else {
            notice = QuickInputCapabilities.of(source).prefill ? "没能启动 \(source.clientName)。确认它已安装，或按 ⌘↵ 用客户端打开。" : "没能启动 \(source.clientName)。确认它已安装。"
            return
        }
        remember(agent: source, project: project.path)
        let pending = PendingStart(source: source, path: project.path, known: known, terminal: terminal)
        pendingStart = pending
        finishComposing()
        onDismiss()
        onDispatch(source, text) { [weak self] in
            guard let self else { return }
            self.pulse(source)
            guard self.pendingStart?.id == pending.id else { return }
            self.receipt = QuickInputReceipt(title: "正在启动 \(source.clientName)…", body: project.name + " · 在后台终端开工。", tone: .progress)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + environment.startTimeout) { [weak self] in
            guard let self, self.pendingStart?.id == pending.id else { return }
            self.pendingStart = nil
            self.receipt = QuickInputReceipt(title: "还没看到 \(source.clientName) 开始工作", body: "它可能在终端里等你确认，比如是否信任这个目录。", tone: .warning,
                                             actions: [.activate(terminal), .dismiss])
        }
    }
    /// A session appearing for that client in that directory is the proof it started.
    private func watchStart(_ data: AgentDockData) {
        guard let pending = pendingStart else { return }
        guard let session = data.sessions.first(where: { $0.source == pending.source && !pending.known.contains($0.dockIdentity) && QuickInputCatalog.path(of: $0) == pending.path }) else { return }
        pendingStart = nil
        receipt = QuickInputReceipt(title: "交给 \(pending.source.clientName) 了", body: session.title, tone: .success)
    }

    private func handOff(_ text: String, to source: WorkSource, in project: QuickInputProject) {
        let fits = text.count <= QuickInputHandoff.promptLimit
        let desktop = source == .claude && hasClaudeDesktop
        guard let url = QuickInputHandoff.url(source: source, path: project.path, prompt: fits && !text.isEmpty ? text : nil, claudeDesktop: desktop) else { notice = "这个地址打不开，换个工作区试试。"; return }
        guard environment.canOpen(url) else { notice = QuickInputHandoff.missingHandler(source); return }
        if !fits { environment.copy(text) }
        guard environment.open(url) else { notice = "没能打开\(destination(source))，内容还在。"; return }
        remember(agent: source, project: project.path)
        finishComposing()
        onDismiss()
        guard !text.isEmpty else { return }
        receipt = QuickInputReceipt(title: "已带到\(destination(source))，等你发送",
            body: fits ? "发送之前不会开始。" : "内容较长，已复制到剪贴板。粘贴后发送。", tone: .handedOff)
    }

    private func open(_ session: AgentDockSession, text: String) {
        if let path = QuickInputCatalog.path(of: session), QuickInputCapabilities.of(session.source).start { remember(agent: session.source, project: path) }
        // Opening a session with no route copies its resume command, which would replace the text.
        let reachable = session.navigationURL != nil || session.localSessionLock != nil || session.localBridgeRoot != nil
        if reachable { state.openAgentSession(session) }
        if !text.isEmpty { environment.copy(text) }
        finishComposing()
        onDismiss()
        if !reachable {
            receipt = QuickInputReceipt(title: "这个会话没有跳转入口", body: text.isEmpty ? "请回到它所在的窗口。" : "内容已复制，请到它所在的窗口粘贴。", tone: .handedOff)
        } else if !text.isEmpty {
            receipt = QuickInputReceipt(title: "已打开会话，内容已复制", body: "粘贴后发送。要不要排队、打断，都在客户端里决定。", tone: .handedOff)
        }
    }

    private func send(_ text: String, to session: AgentDockSession) {
        if let path = QuickInputCatalog.path(of: session) { remember(agent: session.source, project: path) }
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
    private func remember(agent: WorkSource, project path: String) {
        memory.remember(agent: agent, project: path)
        if let data = try? JSONEncoder().encode(memory) { state.quickInputDefaults.set(data, forKey: "quickInput.memory") }
    }
    private func finishComposing() {
        setDraft(""); notice = nil; warning = nil; closePicker(); agentPicked = false
        project = memory.lastProject.map(QuickInputProject.init(path:))
        target = nil
        applyRememberedAgent()
    }
}
