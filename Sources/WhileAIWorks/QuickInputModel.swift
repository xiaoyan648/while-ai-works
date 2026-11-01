import AppKit
import Combine

struct QuickInputProject: Equatable, Identifiable, Codable {
    let path: String
    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

enum QuickInputTarget: Equatable {
    case agent(WorkSource)
    case session(String)
}

enum QuickInputPickerKind: Equatable { case target, project }

struct QuickInputRow: Identifiable, Equatable {
    enum Kind: Equatable { case agent(WorkSource), session(AgentDockSession), project(QuickInputProject), browse }
    enum Tone: Equatable { case plain, working, attention }
    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    var trailing = ""
    var tone = Tone.plain
    var enabled = true
    var section: String? = nil
    var source: WorkSource? {
        switch kind {
        case .agent(let source): return source
        case .session(let session): return session.source
        case .project, .browse: return nil
        }
    }
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

/// Official deep links only fill the client's composer. The user still presses send there.
enum QuickInputHandoff {
    static let promptLimit = 5000
    static func supports(_ source: WorkSource) -> Bool { source == .codex || source == .claude }
    static func destination(_ source: WorkSource) -> String { source == .claude ? "终端" : source.clientName }
    static func url(source: WorkSource, path: String, prompt: String?) -> URL? {
        var fields: [(String, String)]
        let base: String
        switch source {
        case .codex: base = "codex://new"; fields = [("path", path)]; if let prompt { fields.append(("prompt", prompt)) }
        case .claude: base = "claude-cli://open"; fields = [("cwd", path)]; if let prompt { fields.append(("q", prompt)) }
        default: return nil
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let query = fields.compactMap { name, value in value.addingPercentEncoding(withAllowedCharacters: allowed).map { name + "=" + $0 } }
        return URL(string: base + "?" + query.joined(separator: "&"))
    }
    static func missingHandler(_ source: WorkSource) -> String {
        source == .claude ? "还不能打开 Claude Code。在终端运行一次 claude 并发送一条消息后再试。" : "没有找到 Codex 桌面端。"
    }
}

enum QuickInputCatalog {
    static func path(of session: AgentDockSession) -> String? {
        session.workingDirectory ?? session.project.flatMap { $0.hasPrefix("/") ? $0 : nil }
    }
    static func isWaiting(_ session: AgentDockSession) -> Bool { session.event == .approval || session.event == .input }

    static func projects(sessions: [AgentDockSession], recents: [String], exists: (String) -> Bool) -> [QuickInputProject] {
        var seen = Set<String>()
        return (recents + sessions.compactMap(path)).filter { seen.insert($0).inserted && exists($0) }.map { QuickInputProject(path: $0) }
    }

    static func targetRows(data: AgentDockData, sources: [WorkSource], quota: (WorkSource) -> AgentDockQuota?, query: String) -> [QuickInputRow] {
        func matches(_ fields: String...) -> Bool {
            query.isEmpty || fields.contains { $0.localizedCaseInsensitiveContains(query) }
        }
        let agents = sources.filter { matches($0.clientName, $0.rawValue) }.map { source -> QuickInputRow in
            let supported = QuickInputHandoff.supports(source)
            let reading = quota(source).flatMap { $0.stale ? nil : $0.remaining }
            return QuickInputRow(id: "agent:" + source.rawValue, kind: .agent(source), title: source.clientName,
                subtitle: supported ? "打开\(QuickInputHandoff.destination(source))并填好内容" : "暂时不能接收任务",
                trailing: reading.map { "额度 \(Int($0.rounded()))%" } ?? "", enabled: supported)
        }
        let candidates = data.sessions.filter { $0.parentSessionID == nil && sources.contains($0.source) && matches($0.title, $0.source.clientName, $0.project ?? "") }
        let sessions = candidates.prefix(query.isEmpty ? 6 : 12).map { session -> QuickInputRow in
            let waiting = isWaiting(session)
            let where_ = [session.source.clientName, path(of: session).map { QuickInputProject(path: $0).name } ?? session.project].compactMap { $0 }.joined(separator: " · ")
            return QuickInputRow(id: "session:" + session.dockIdentity, kind: .session(session), title: session.title,
                subtitle: where_ + (session.canSend ? "" : " · 只能回原客户端"),
                trailing: waiting ? "等你处理" : session.running ? "运行中" : session.canSend ? "空闲" : "",
                tone: waiting ? .attention : session.running ? .working : .plain, enabled: session.canSend && !waiting)
        }
        var rows = agents
        if !rows.isEmpty { rows[0].section = "开新任务" }
        var tail = Array(sessions)
        if !tail.isEmpty { tail[0].section = "继续会话" }
        return rows + tail
    }

    static func projectRows(projects: [QuickInputProject], memory: QuickInputMemory, query: String) -> [QuickInputRow] {
        let names = Dictionary(grouping: projects, by: \.name)
        var rows = projects.filter { query.isEmpty || $0.path.localizedCaseInsensitiveContains(query) }.prefix(8).map { project -> QuickInputRow in
            let agent = memory.projectAgents[project.path].flatMap(WorkSource.init(rawValue:))
            return QuickInputRow(id: "project:" + project.path, kind: .project(project), title: project.name,
                subtitle: (names[project.name]?.count ?? 0) > 1 || query.isEmpty ? (project.path as NSString).abbreviatingWithTildeInPath : "",
                trailing: agent.map { "上次用 " + $0.clientName } ?? "")
        }
        if query.isEmpty { rows.append(QuickInputRow(id: "browse", kind: .browse, title: "选择其他目录…", subtitle: "")) }
        return rows
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

struct QuickInputQueuedMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    let sessionID: String
    let source: String
    let title: String
    let text: String
    var idleReadings = 0
}

struct QuickInputReceipt: Identifiable, Equatable {
    enum Tone: Equatable { case progress, success, handedOff, warning, failure }
    enum Action: Equatable { case open(AgentDockSession), restore(String), cancelQueue(UUID) }
    let id = UUID()
    let title: String
    let body: String
    let tone: Tone
    var actions: [Action] = []
    var lingers: Bool { tone == .warning || tone == .failure || !actions.filter { if case .cancelQueue = $0 { return true }; return false }.isEmpty }
    var pending: Bool { tone == .progress }
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
}

/// The draft, who receives it and what pressing Enter does. WAW delivers and watches;
/// the conversation itself stays in the agent's own client.
final class QuickInputModel: ObservableObject {
    static let messageLimit = 16_384
    let state: AppState
    private let environment: QuickInputEnvironment
    @Published private(set) var draft = ""
    @Published private(set) var draftRevision = 0
    @Published private(set) var target: QuickInputTarget?
    @Published private(set) var project: QuickInputProject?
    @Published private(set) var pickerKind: QuickInputPickerKind?
    @Published private(set) var pickerQuery = ""
    @Published private(set) var pickerNote: String?
    @Published private(set) var selection = 0
    @Published private(set) var notice: String?
    @Published private(set) var warning: String?
    @Published private(set) var receipt: QuickInputReceipt?
    @Published private(set) var memory: QuickInputMemory
    @Published private(set) var queue: [QuickInputQueuedMessage] = []
    private var pickerToken: NSRange?
    private var agentPicked = false
    private var subscriptions: Set<AnyCancellable> = []
    var onDismiss: () -> Void = {}
    /// Called once with the outgoing text; the panel flies it to the dock, then calls `finish`.
    var onDispatch: (WorkSource, String, @escaping () -> Void) -> Void = { _, _, finish in finish() }

    init(state: AppState, environment: QuickInputEnvironment = QuickInputEnvironment()) {
        self.state = state; self.environment = environment
        let defaults = state.quickInputDefaults
        memory = defaults.data(forKey: "quickInput.memory").flatMap { try? JSONDecoder().decode(QuickInputMemory.self, from: $0) } ?? QuickInputMemory()
        // A message left waiting when the app quit may be stale by now. It returns as a draft, never sends by itself.
        if let saved = defaults.data(forKey: "quickInput.queue"), let queued = try? JSONDecoder().decode([QuickInputQueuedMessage].self, from: saved), !queued.isEmpty {
            draft = queued.map(\.text).joined(separator: "\n\n")
            defaults.removeObject(forKey: "quickInput.queue")
        }
        state.$agentDashboard.sink { [weak self] data in self?.advanceQueue(data) }.store(in: &subscriptions)
    }

    var pickerVisible: Bool { pickerKind != nil && (!rows.isEmpty || pickerToken == nil) }
    var selectedSources: [WorkSource] { WorkSource.dockOrder.filter { state.selectedSources.contains($0) } }
    var targetSession: AgentDockSession? {
        guard case .session(let identity) = target else { return nil }
        return state.agentDashboard.sessions.first { $0.dockIdentity == identity }
    }
    var targetAgent: WorkSource? {
        if case .agent(let source) = target { return source }
        return targetSession?.source
    }
    var projects: [QuickInputProject] {
        QuickInputCatalog.projects(sessions: state.agentDashboard.sessions, recents: memory.recents, exists: environment.directoryExists)
    }
    var rows: [QuickInputRow] {
        switch pickerKind {
        case .target: return QuickInputCatalog.targetRows(data: state.agentDashboard, sources: selectedSources, quota: state.dockQuota(for:), query: pickerQuery)
        case .project: return QuickInputCatalog.projectRows(projects: projects, memory: memory, query: pickerQuery)
        case nil: return []
        }
    }
    /// What Enter does right now, written on the button.
    var primaryVerb: String {
        if pickerVisible { return "选择" }
        if let session = targetSession { return session.running ? "插入当前步" : "继续" }
        guard case .agent(let source) = target, project != nil else { return "下一步" }
        return "带到 " + QuickInputHandoff.destination(source)
    }
    var secondaryVerb: String? { !pickerVisible && targetSession?.running == true ? "排队" : nil }
    var hint: String? {
        if notice != nil { return notice }
        if target == nil && project == nil { return "只选这一次，之后每个项目记住上次的选择。" }
        if targetSession?.running == true { return "要打断它，回到原会话操作。" }
        return nil
    }

    func prepareForSummon() {
        notice = nil; closePicker()
        if case .session = target, targetSession == nil { target = nil }
        if target == nil {
            if project == nil, let last = memory.lastProject, environment.directoryExists(last) { project = QuickInputProject(path: last) }
            applyRememberedAgent()
        }
    }
    private func applyRememberedAgent() {
        let remembered = project.flatMap { memory.projectAgents[$0.path] } ?? memory.lastAgent
        guard let source = remembered.flatMap(WorkSource.init(rawValue:)), state.selectedSources.contains(source), QuickInputHandoff.supports(source) else { return }
        target = .agent(source)
    }

    func textChanged(_ text: String, cursor: Int) {
        draft = text; notice = nil
        syncToken(cursor: cursor)
    }
    func cursorMoved(_ cursor: Int) { syncToken(cursor: cursor) }
    private func syncToken(cursor: Int) {
        if let match = QuickInputToken.match(in: draft, cursor: cursor) {
            let kind: QuickInputPickerKind = match.trigger == "@" ? .target : .project
            if pickerKind != kind || pickerQuery != match.query || pickerToken != match.range { selection = 0 }
            pickerKind = kind; pickerQuery = match.query; pickerToken = match.range; pickerNote = nil
        } else if pickerToken != nil { closePicker() }
    }

    func togglePicker(_ kind: QuickInputPickerKind) {
        if pickerKind == kind { closePicker() } else { openPicker(kind, note: nil) }
    }
    private func openPicker(_ kind: QuickInputPickerKind, note: String?) {
        pickerKind = kind; pickerQuery = ""; pickerToken = nil; pickerNote = note; selection = 0
    }
    func closePicker() { pickerKind = nil; pickerQuery = ""; pickerToken = nil; pickerNote = nil; selection = 0 }
    func moveSelection(_ delta: Int) {
        let count = rows.count
        guard count > 0 else { return }
        selection = min(count - 1, max(0, selection + delta))
    }
    func pickSelected() {
        let current = rows
        guard current.indices.contains(selection) else { closePicker(); return }
        pick(current[selection])
    }
    func pick(_ row: QuickInputRow) {
        switch row.kind {
        case .agent(let source):
            guard row.enabled else { pickerNote = source.clientName + " 暂时不能接收任务，换一个吧。"; return }
            removeToken(); target = .agent(source); agentPicked = true
            closePicker()
            if project == nil { openPicker(.project, note: "还差项目，内容不会丢。") }
        case .session(let session):
            guard row.enabled else {
                pickerNote = QuickInputCatalog.isWaiting(session) ? "它在等你回应，先在猫条处理。" : "这个会话只能回原客户端继续。"
                return
            }
            removeToken(); target = .session(session.dockIdentity); warning = nil
            closePicker()
        case .project(let chosen):
            removeToken(); setProject(chosen); closePicker()
        case .browse:
            guard let path = environment.chooseDirectory() else { return }
            setProject(QuickInputProject(path: path)); closePicker()
        }
    }
    private func setProject(_ chosen: QuickInputProject) {
        project = chosen
        if !agentPicked, case .session = target { return }
        if !agentPicked { applyRememberedAgent() }
    }
    private func removeToken() {
        guard let token = pickerToken, token.location + token.length <= (draft as NSString).length else { return }
        setDraft((draft as NSString).replacingCharacters(in: token, with: ""))
        pickerToken = nil
    }
    private func setDraft(_ text: String) { draft = text; draftRevision += 1 }
    func clearSessionTarget() { target = nil; applyRememberedAgent() }

    func submit(alternate: Bool = false) {
        if pickerVisible { pickSelected(); return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let target else { openPicker(.target, note: "先选谁来做，内容不会丢。"); return }
        switch target {
        case .agent(let source):
            guard !alternate else { return }
            guard let project else { openPicker(.project, note: "还差项目，内容不会丢。"); return }
            handOff(text, to: source, in: project)
        case .session:
            guard let session = targetSession else {
                self.target = nil; notice = "这个会话已不在列表里，换一个吧。"; return
            }
            guard session.canSend, !QuickInputCatalog.isWaiting(session) else { notice = "它在等你回应，先在猫条处理。"; return }
            guard text.utf8.count <= Self.messageLimit else { notice = "内容太长，请缩短一些。"; return }
            if alternate {
                guard session.running else { return }
                enqueue(text, for: session)
            } else { send(text, to: session) }
        }
    }

    private func handOff(_ text: String, to source: WorkSource, in project: QuickInputProject) {
        let fits = text.count <= QuickInputHandoff.promptLimit
        guard let url = QuickInputHandoff.url(source: source, path: project.path, prompt: fits ? text : nil) else { notice = "这个地址打不开，换个项目试试。"; return }
        guard environment.canOpen(url) else { notice = QuickInputHandoff.missingHandler(source); return }
        if !fits { environment.copy(text) }
        guard environment.open(url) else { notice = "没能打开\(QuickInputHandoff.destination(source))，内容还在。"; return }
        remember(agent: source, project: project.path)
        finishComposing()
        onDismiss()
        let place = QuickInputHandoff.destination(source)
        receipt = QuickInputReceipt(title: "已带到\(place)，等你发送",
            body: fits ? "发送之前不会开始。" : "内容较长，已复制到剪贴板。粘贴后发送。", tone: .handedOff)
    }

    private func send(_ text: String, to session: AgentDockSession) {
        if let path = QuickInputCatalog.path(of: session) { remember(agent: session.source, project: path) }
        finishComposing()
        onDismiss()
        onDispatch(session.source, text) { [weak self] in
            guard let self else { return }
            self.receipt = QuickInputReceipt(title: "正在发送…", body: "等待对方确认收到。", tone: .progress)
            self.state.quickInputPulse.source = session.source
            self.state.quickInputPulse.landings += 1
            Task { @MainActor [weak self] in
                guard let self else { return }
                let outcome = await self.state.sendAgentMessage(session, text)
                self.report(outcome, text: text, session: session)
            }
        }
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
                                        actions: [.open(session), .restore(text)])
            target = .session(session.dockIdentity)
        case .unavailable, .failed:
            state.quickInputPulse.source = session.source
            state.quickInputPulse.rejections += 1
            let detail: String
            if case .failed(let message) = outcome { detail = message } else { detail = "原会话当前不接收消息。" }
            receipt = QuickInputReceipt(title: "没送到", body: detail + "内容还在。", tone: .failure, actions: [.open(session), .restore(text)])
            target = .session(session.dockIdentity)
        }
    }

    private func enqueue(_ text: String, for session: AgentDockSession) {
        if let path = QuickInputCatalog.path(of: session) { remember(agent: session.source, project: path) }
        let message = QuickInputQueuedMessage(sessionID: session.dockIdentity, source: session.source.rawValue, title: session.title, text: text)
        finishComposing()
        onDismiss()
        onDispatch(session.source, text) { [weak self] in
            guard let self else { return }
            self.queue.append(message); self.queueChanged()
            self.state.quickInputPulse.source = session.source
            self.state.quickInputPulse.landings += 1
            self.receipt = QuickInputReceipt(title: "已排队，这一轮结束后发送", body: session.title, tone: .success, actions: [.cancelQueue(message.id)])
        }
    }

    /// Two idle readings in a row, so a quiet moment between steps does not count as the end of a turn.
    private func advanceQueue(_ data: AgentDockData) {
        guard !queue.isEmpty else { return }
        var delivering = Set<String>()
        for index in queue.indices.reversed() {
            let identity = queue[index].sessionID
            guard let session = data.sessions.first(where: { $0.dockIdentity == identity }) else {
                let message = queue.remove(at: index)
                restore(message.text)
                receipt = QuickInputReceipt(title: "没送到", body: message.title + " 已不在列表里。内容回到了草稿。", tone: .failure, actions: [])
                continue
            }
            queue[index].idleReadings = session.running || QuickInputCatalog.isWaiting(session) ? 0 : queue[index].idleReadings + 1
        }
        for message in queue where message.idleReadings >= 2 && !delivering.contains(message.sessionID) {
            guard let session = data.sessions.first(where: { $0.dockIdentity == message.sessionID }) else { continue }
            delivering.insert(message.sessionID)
            queue.removeAll { $0.id == message.id }
            queue.indices.filter { queue[$0].sessionID == message.sessionID }.forEach { queue[$0].idleReadings = 0 }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let outcome = await self.state.sendAgentMessage(session, message.text)
                if outcome == .accepted || outcome == .steered {
                    self.state.quickInputPulse.source = session.source
                    self.state.quickInputPulse.landings += 1
                    self.receipt = QuickInputReceipt(title: "排队的内容已发出", body: session.title + " 开始新一轮。", tone: .success, actions: [.open(session)])
                } else {
                    self.report(outcome, text: message.text, session: session)
                }
            }
        }
        queueChanged()
    }
    private func queueChanged() {
        state.quickInputQueued = Dictionary(grouping: queue, by: \.source).reduce(into: [:]) { counts, group in
            if let source = WorkSource(rawValue: group.key) { counts[source] = group.value.count }
        }
        let defaults = state.quickInputDefaults
        if queue.isEmpty { defaults.removeObject(forKey: "quickInput.queue") }
        else if let data = try? JSONEncoder().encode(queue) { defaults.set(data, forKey: "quickInput.queue") }
    }

    func perform(_ action: QuickInputReceipt.Action) {
        switch action {
        case .open(let session): state.openAgentSession(session); receipt = nil
        case .restore(let text): restore(text); receipt = nil; state.quickInputSummon.send()
        case .cancelQueue(let id):
            guard let message = queue.first(where: { $0.id == id }) else { receipt = nil; return }
            queue.removeAll { $0.id == id }; queueChanged()
            restore(message.text); target = .session(message.sessionID)
            receipt = nil; state.quickInputSummon.send()
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
