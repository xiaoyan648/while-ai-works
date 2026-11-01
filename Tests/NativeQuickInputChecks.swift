import AppKit
import AgentHUDCore
import Carbon
import SwiftUI
import WhileCore

/// Like `precondition`, but says which check failed even in optimized builds.
private func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "unexpected state", line: UInt = #line) {
    guard condition() else {
        fputs("NativeQuickInputChecks line \(line): \(message())\n", stderr)
        exit(1)
    }
}

private func session(_ id: String, source: WorkSource = .codex, title: String = "修复充值边界", cwd: String? = "/repo/cineflow", running: Bool = false,
                     event: AgentSessionEvent = .recent, sendable: Bool = true, reachable: Bool = true) -> AgentDockSession {
    let uuid = UUID(uuidString: id) ?? UUID()
    let identifier = uuid.uuidString.lowercased()
    let url = sendable ? "codex://threads/" + identifier : reachable ? "claude://claude.ai/epitaxy/" + identifier : nil
    return AgentDockSession(id: identifier, source: source, title: title, project: cwd.map { URL(fileURLWithPath: $0).lastPathComponent }, status: running ? "工作中" : "最近会话",
                            running: running, tokensIn: 0, tokensOut: 0, cacheRead: 0, reply: nil, observedAt: Date(),
                            navigationURL: url.flatMap(URL.init(string:)), resumeCommand: nil,
                            event: event, workingDirectory: cwd)
}

private func spin(_ seconds: TimeInterval = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
private func eventually(_ condition: () -> Bool, _ message: String, line: UInt = #line) {
    for _ in 0..<200 { if condition() { return }; spin(0.02) }
    check(false, message, line: line)
}

@main enum NativeQuickInputChecks {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let arguments = ProcessInfo.processInfo.arguments
        tokens()
        links()
        startScripts()
        catalog()
        newSessions()
        placePicker()
        sending()
        openingSessions()
        jumping()
        try keyboard()
        dockHandover()
        if arguments.contains("--real") { MainActor.assumeIsolated { realData(arguments) } }
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count { snapshots(URL(fileURLWithPath: arguments[index + 1], isDirectory: true)) }
        print("Quick input checks passed")
    }

    private static func makeState() -> AppState {
        let suite = "WhileAIWorks.QuickInputChecks." + UUID().uuidString
        let state = AppState(defaults: UserDefaults(suiteName: suite)!)
        state.soundEnabled = false; state.selectedSources = [.codex, .claude, .hermes, .dsh]
        return state
    }
    private static func environment(opened: ((URL) -> Void)? = nil, handler: Bool = true, copied: ((String) -> Void)? = nil,
                                    started: ((QuickInputStart.Request) -> Void)? = nil, startable: Bool = true, timeout: TimeInterval = 25) -> QuickInputEnvironment {
        var value = QuickInputEnvironment(open: { opened?($0); return true }, canOpen: { _ in handler }, copy: { copied?($0) }, directoryExists: { _ in true }, chooseDirectory: { nil },
                                          start: { started?($0); return startable ? "com.mitchellh.ghostty" : nil }, activate: { _ in }, startTimeout: timeout)
        value.usesSystemChooser = false
        return value
    }

    static func tokens() {
        func match(_ text: String) -> QuickInputToken.Match? { QuickInputToken.match(in: text, cursor: (text as NSString).length) }
        check(match("@")?.trigger == "@" && match("@cod")?.query == "cod")
        check(match("看一下 #cine")?.trigger == "#" && match("看一下 #cine")?.query == "cine")
        check(match("检查一下@cod")?.query == "cod", "Chinese has no spaces, so a token may follow it directly")
        check(match("me@example.com") == nil && match("issue#12") == nil, "addresses and references are plain text")
        check(match("@codex 检查") == nil && match("普通文本") == nil)
        check(match("@cod")?.range == NSRange(location: 0, length: 4))
        check(QuickInputToken.match(in: "@codex 检查", cursor: 3)?.query == "co", "the token is read up to the cursor")
    }

    static func links() {
        let codex = QuickInputHandoff.url(source: .codex, path: "/repo/云 流", prompt: "a+b & c=d\n第二行")!.absoluteString
        check(codex.hasPrefix("codex://new?path=%2Frepo%2F"))
        check(codex.contains("prompt=a%2Bb%20%26%20c%3Dd%0A"), "plus and ampersand must survive: \(codex)")
        let claude = QuickInputHandoff.url(source: .claude, path: "/repo/x", prompt: "看一下")!.absoluteString
        check(claude.hasPrefix("claude-cli://open?cwd=%2Frepo%2Fx&q=%E7%9C%8B"))
        check(QuickInputHandoff.url(source: .claude, path: "/repo/x", prompt: nil)!.absoluteString == "claude-cli://open?cwd=%2Frepo%2Fx")
        check(QuickInputHandoff.url(source: .dsh, path: "/repo", prompt: "x") == nil)
        let desktop = QuickInputHandoff.url(source: .claude, path: "/repo/x", prompt: "看一下", claudeDesktop: true)!.absoluteString
        check(desktop.hasPrefix("claude://code/new?folder=%2Frepo%2Fx&source=while-ai-works&q=%E7%9C%8B"), desktop)
        check(QuickInputHandoff.destination(.claude, claudeDesktop: true) == "Claude" && QuickInputHandoff.destination(.claude, claudeDesktop: false) == "终端")
        check(QuickInputCapabilities.of(.codex).start && QuickInputCapabilities.of(.claude).prefill)
        check(QuickInputCapabilities.of(.hermes).start && !QuickInputCapabilities.of(.hermes).prefill && !QuickInputCapabilities.of(.dsh).start)
    }

    /// Runs the generated script for real against a stand-in client: hostile text must arrive byte for byte.
    static func startScripts() {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent("WAWQuickInputChecks-" + UUID().uuidString)
        try! manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: folder) }
        let workspace = folder.appendingPathComponent("it's a repo", isDirectory: true)
        try! manager.createDirectory(at: workspace, withIntermediateDirectories: true)
        let output = folder.appendingPathComponent("out.txt")
        let client = folder.appendingPathComponent("fake client")
        try! "#!/bin/sh\npwd > '\(output.path)'\nfor a in \"$@\"; do printf '[%s]\\n' \"$a\" >> '\(output.path)'; done\n".write(to: client, atomically: true, encoding: .utf8)
        try! manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: client.path)
        let prompt = "看一下 \"引号\" 'x' $(touch /tmp/waw-should-not-exist) `date` \\ -flag\n第二行 $HOME"
        for (source, expected) in [(WorkSource.claude, ["[--]"]), (.codex, ["[-C]", "[" + workspace.path + "]", "[--]"]), (.hermes, ["[chat]", "[--in]", "[" + workspace.path + "]"])] {
            try? manager.removeItem(at: output)
            let promptFile = folder.appendingPathComponent("p.txt"), scriptFile = folder.appendingPathComponent("s.command")
            try! prompt.write(to: promptFile, atomically: true, encoding: .utf8)
            let script = QuickInputStart.script(source: source, executable: client.path, directory: workspace.path, promptFile: promptFile.path, searchPath: "/usr/bin:/bin")!
            try! script.write(to: scriptFile, atomically: true, encoding: .utf8)
            try! manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptFile.path)
            let process = Process(); process.executableURL = scriptFile
            try! process.run(); process.waitUntilExit()
            check(process.terminationStatus == 0, "\(source) script failed")
            let lines = try! String(contentsOf: output, encoding: .utf8)
            check(lines.hasPrefix(manager.fileExists(atPath: "/private" + workspace.path) ? "/private" + workspace.path : workspace.path) || lines.contains(workspace.lastPathComponent), "runs in the workspace: \(lines)")
            for part in expected { check(lines.contains(part), "\(source) misses \(part): \(lines)") }
            let delivered = source == .hermes ? "[--query=" + prompt + "]" : "[" + prompt + "]"
            check(lines.contains(delivered), "\(source) mangled the prompt: \(lines)")
            check(!manager.fileExists(atPath: promptFile.path) && !manager.fileExists(atPath: scriptFile.path), "the private files are removed")
        }
        check(!manager.fileExists(atPath: "/tmp/waw-should-not-exist"), "the prompt is never executed")
        check(QuickInputStart.script(source: .dsh, executable: "x", directory: "/", promptFile: "p", searchPath: "") == nil)
    }

    static func catalog() {
        let rows = QuickInputCatalog.agentRows(sources: [.codex, .dsh], quota: { _ in nil }, query: "")
        check(rows.first { $0.source == .dsh }?.enabled == false, "unsupported agents stay visible but disabled")
        let low = AgentDockQuota(id: "c", source: .codex, title: "每周", remaining: 0, resetAt: nil, observedAt: Date(), stale: false, window: .weekly)
        check(QuickInputCatalog.agentRows(sources: [.codex], quota: { _ in low }, query: "").first?.tone == .attention, "almost no quota is flagged")
        check(QuickInputCatalog.agentRows(sources: [.codex, .claude], quota: { _ in nil }, query: "claude").first?.source == .claude)

        let sessions = [session("00000000-0000-4000-8000-000000000001", cwd: "/repo/cineflow", running: true),
                        session("00000000-0000-4000-8000-000000000002", title: "等待", cwd: "/repo/waw", event: .approval),
                        session("00000000-0000-4000-8000-000000000003", source: .claude, title: "终端会话", cwd: "/repo/waw", sendable: false),
                        session("00000000-0000-4000-8000-000000000004", title: "订阅校验", cwd: "/repo/waw")]
        let projects = QuickInputCatalog.projects(sessions: sessions, recents: ["/repo/old", "/repo/waw"], exists: { $0 != "/repo/old" })
        check(projects.map(\.path) == ["/repo/cineflow", "/repo/waw"], "dock order, then recents; unique and only existing directories")
        check(QuickInputCatalog.projects(sessions: [session("x", cwd: "/a/app"), session("y", cwd: "/b/app")], recents: [], exists: { _ in true }).count == 2, "worktrees with one name stay apart")
        let waw = QuickInputProject(path: "/repo/waw")
        let inWaw = QuickInputCatalog.sessions(in: waw, of: sessions, query: "")
        check(inWaw.map(\.title) == ["等待", "终端会话", "订阅校验"], "the order given, which is the dock's: \(inWaw.map(\.title))")
        check(QuickInputCatalog.sessionRow(inWaw[0]).tone == .attention && QuickInputCatalog.sessionRow(inWaw[1]).trailing == "仅打开")
        check(QuickInputCatalog.workspaces(projects: projects, sessions: sessions, query: "").first == .all, "all sessions come first")
        check(QuickInputCatalog.workspaces(projects: projects, sessions: sessions, query: "订阅") == [.all, QuickInputProject(path: "/repo/waw")], "a session title finds all, then its workspace")
        check(QuickInputCatalog.workspaces(projects: projects, sessions: sessions, query: "waw").first?.name == "waw", "a workspace name comes first")
        let homeless = sessions + [session("00000000-0000-4000-8000-000000000005", title: "无处可归", cwd: nil)]
        check(QuickInputCatalog.sessions(in: .all, of: homeless, query: "").count == 5 && QuickInputCatalog.sessions(in: .all, of: homeless, query: "无处").count == 1, "a session with no workspace is still reachable")
        check(QuickInputCatalog.sessions(in: .all, of: homeless, query: "claude").map(\.title) == ["终端会话"], "searching a client name works too")
        check(QuickInputCatalog.sessions(in: waw, of: sessions, query: "订阅").map(\.title) == ["订阅校验"])
        check(QuickInputCatalog.sessions(in: waw, of: sessions, query: "waw").count == 3, "a workspace name shows everything in it")
    }

    static func newSessions() {
        let state = makeState()
        var opened: [URL] = [], started: [QuickInputStart.Request] = [], dismissed = 0, flown: [WorkSource] = []
        let model = QuickInputModel(state: state, environment: environment(opened: { opened.append($0) }, started: { started.append($0) }))
        model.onDismiss = { dismissed += 1 }
        model.onDispatch = { source, _, finish in flown.append(source); finish() }
        var data = AgentDockData()
        let existing = session("00000000-0000-4000-8000-000000000001", running: true)
        data.sessions = [existing]
        state.agentDashboard = data
        model.prepareForSummon()
        check(model.target == nil && model.project == nil && model.primaryVerb == "下一步", "nothing is chosen for a first-time user")

        // Enter walks through what is missing and never loses the text or sends to a guess.
        model.textChanged("检查一下", cursor: 4)
        model.submit()
        check(model.pickerKind == .agent && model.pickerNote != nil && model.draft == "检查一下" && started.isEmpty)
        model.pick(model.rows.first { $0.source == .dsh }!)
        check(model.target == nil && model.pickerNote?.contains("暂时不能") == true, "a disabled agent is explained, not chosen")
        model.pick(model.rows.first { $0.source == .codex }!)
        check(model.target == .agent(.codex) && model.pickerKind == .place)
        model.pick(workspace: QuickInputProject(path: "/repo/cineflow"))
        check(model.project?.path == "/repo/cineflow" && model.pickerKind == nil && started.isEmpty)
        check(model.primaryVerb == "发送" && model.secondaryVerb == "在 Codex 打开")

        // Enter starts the session and leaves at once; the receipt only claims what it has seen.
        model.submit()
        check(started == [.init(source: .codex, directory: "/repo/cineflow", prompt: "检查一下")] && opened.isEmpty)
        check(dismissed == 1 && flown == [.codex] && model.draft.isEmpty)
        check(model.receipt?.title.contains("正在启动") == true && model.receipt?.lingers == true)
        check(state.quickInputPulse.landings == 1 && state.quickInputPulse.source == .codex)
        var after = data
        after.sessions.append(session("00000000-0000-4000-8000-000000000009", title: "别的目录", cwd: "/repo/other"))
        state.agentDashboard = after
        check(model.receipt?.title.contains("正在启动") == true, "a new session elsewhere proves nothing")
        after.sessions.append(session("00000000-0000-4000-8000-000000000010", title: "检查一下", cwd: "/repo/cineflow"))
        state.agentDashboard = after
        check(model.receipt?.title == "交给 Codex 了" && model.receipt?.body == "检查一下" && model.receipt?.lingers == false)

        // The next task starts from what was remembered, still in plain view.
        model.prepareForSummon()
        check(model.target == .agent(.codex) && model.project?.path == "/repo/cineflow")
        let reborn = QuickInputModel(state: state, environment: environment())
        reborn.prepareForSummon()
        check(reborn.target == .agent(.codex) && reborn.project?.path == "/repo/cineflow", "the choice survives a restart")

        // ⌘Enter fills the client instead, and says that nothing has started.
        model.textChanged("带过去", cursor: 3)
        model.submit(openClient: true)
        check(opened.count == 1 && opened[0].absoluteString.hasPrefix("codex://new?path=%2Frepo%2Fcineflow&prompt=") && started.count == 1)
        check(model.receipt?.tone == .handedOff && model.receipt?.title.contains("等你发送") == true, "a handoff is never reported as delivered")

        // A client without a prefill route offers only Enter.
        model.textChanged("x", cursor: 1)
        model.togglePicker(.agent)
        model.pick(model.rows.first { $0.source == .hermes }!)
        check(model.primaryVerb == "发送" && model.secondaryVerb == nil)
        model.submit(openClient: true)
        check(opened.count == 1 && started.count == 1 && model.draft == "x", "⌘Enter does nothing where it is not offered")
        model.textChanged("", cursor: 0)

        // Claude goes to its desktop app when there is one, and to the terminal link otherwise.
        var claudeOpened: [URL] = []
        var withDesktop = environment(opened: { claudeOpened.append($0) })
        withDesktop.canOpen = { _ in true }
        let toDesktop = QuickInputModel(state: state, environment: withDesktop)
        toDesktop.prepareForSummon()
        toDesktop.togglePicker(.agent)
        toDesktop.pick(toDesktop.rows.first { $0.source == .claude }!)
        check(toDesktop.secondaryVerb == "在 Claude 打开")
        toDesktop.textChanged("看看", cursor: 2)
        toDesktop.submit(openClient: true)
        check(claudeOpened.last?.scheme == "claude" && toDesktop.receipt?.title == "已带到Claude，等你发送")
        var noDesktop = environment(opened: { claudeOpened.append($0) })
        noDesktop.canOpen = { $0.scheme != "claude" }
        let toTerminal = QuickInputModel(state: state, environment: noDesktop)
        toTerminal.prepareForSummon()
        toTerminal.togglePicker(.agent)
        toTerminal.pick(toTerminal.rows.first { $0.source == .claude }!)
        check(toTerminal.secondaryVerb == "在 终端 打开")
        toTerminal.textChanged("看看", cursor: 2)
        toTerminal.submit(openClient: true)
        check(claudeOpened.last?.scheme == "claude-cli")

        // A typed token picks an agent and leaves the sentence clean; `@` inside plain text stays.
        model.textChanged("看一下 @", cursor: 5)
        check(model.pickerVisible && model.pickerKind == .agent)
        model.textChanged("看一下 @cla", cursor: 8)
        check(model.rows.first?.source == .claude)
        model.pickSelected()
        check(model.draft == "看一下 " && model.target == .agent(.claude) && model.draftRevision > 0)
        model.textChanged("升级 @types/node", cursor: 14)
        check(!model.pickerVisible, "no match closes the list so Enter can send the literal text")
        model.textChanged("", cursor: 0)

        // Long text goes through the clipboard, since links are capped.
        var copied = ""
        let long = QuickInputModel(state: state, environment: environment(opened: { opened.append($0) }, copied: { copied = $0 }))
        long.prepareForSummon()
        let text = String(repeating: "长", count: QuickInputHandoff.promptLimit + 1)
        long.textChanged(text, cursor: (text as NSString).length)
        long.submit(openClient: true)
        check(copied == text && opened.last?.absoluteString.contains("q=") == false && long.receipt?.body.contains("已复制") == true)

        // Failing to start or to open keeps everything in place.
        var stuck = false
        let cannotStart = QuickInputModel(state: state, environment: environment(startable: false))
        cannotStart.onDismiss = { stuck = true }
        cannotStart.prepareForSummon()
        cannotStart.textChanged("x", cursor: 1)
        cannotStart.submit()
        check(cannotStart.notice != nil && cannotStart.draft == "x" && !stuck)
        let missing = QuickInputModel(state: state, environment: environment(handler: false))
        missing.onDismiss = { stuck = true }
        missing.prepareForSummon()
        missing.textChanged("x", cursor: 1)
        missing.submit(openClient: true)
        check(missing.notice != nil && missing.draft == "x" && !stuck)

        // A start that never shows up says so and points at the terminal, instead of waiting forever.
        let silent = QuickInputModel(state: state, environment: environment(timeout: 0.05))
        silent.prepareForSummon()
        silent.textChanged("x", cursor: 1)
        silent.submit()
        eventually({ silent.receipt?.tone == .warning }, "a silent start is reported")
        check(silent.receipt?.actions.contains(.activate("com.mitchellh.ghostty")) == true)
    }

    static func placePicker() {
        let state = makeState()
        var data = AgentDockData()
        let running = session("00000000-0000-4000-8000-000000000001", title: "修复充值边界", cwd: "/repo/cineflow", running: true, event: .working)
        let idle = session("00000000-0000-4000-8000-000000000002", title: "有效期排查", cwd: "/repo/cineflow")
        let other = session("00000000-0000-4000-8000-000000000003", title: "订阅校验", cwd: "/repo/waw")
        data.sessions = [running, idle, other]
        state.agentDashboard = data
        let model = QuickInputModel(state: state, environment: environment())
        model.prepareForSummon()
        model.togglePicker(.agent)
        model.pick(model.rows.first { $0.source == .codex }!)
        check(model.pickerKind == .place && model.workspaces.map(\.name) == ["全部会话", "cineflow", "waw"] && model.placePane == .workspaces)
        check(model.focusedWorkspace == .all && model.focusedSessions.count == 3 && model.primaryVerb == "选会话" && model.secondaryVerb == nil, "all sessions show first when no workspace is chosen yet")
        model.pickSelected()
        check(model.placePane == .sessions && model.sessionIndex == 1 && model.pickerKind == .place, "Enter on all moves into the sessions")
        model.moveSelection(-1)
        check(model.sessionIndex == 1, "all has no new-session row to land on")
        model.leaveSessions()
        model.moveSelection(1)
        check(model.focusedWorkspace?.name == "cineflow")
        check(model.focusedSessions.map(\.title) == ["修复充值边界", "有效期排查"], "the sessions on the right belong to the focused workspace")
        check(model.primaryVerb == "在这里开新会话")

        model.moveSelection(1)
        check(model.focusedWorkspace?.name == "waw" && model.focusedSessions.map(\.title) == ["订阅校验"], "moving through workspaces changes the right side")
        model.moveSelection(5)
        check(model.focusedWorkspace?.name == "waw", "it stops at the end")
        model.moveSelection(-1)
        model.enterSessions()
        check(model.focusedWorkspace?.name == "cineflow" && model.placePane == .sessions && model.sessionIndex == 1 && model.primaryVerb == "继续这个会话")
        model.moveSelection(1)
        check(model.sessionIndex == 2)
        model.moveSelection(-2)
        check(model.sessionIndex == 0 && model.primaryVerb == "在这里开新会话", "the first row on the right is a new session")
        model.leaveSessions()
        check(model.placePane == .workspaces)
        model.pickSelected()
        check(model.project?.name == "cineflow" && model.target == .agent(.codex) && model.pickerKind == nil, "a workspace means a new session there")
        check(model.primaryVerb == "发送")

        // Picking a session settles the agent and the workspace together.
        model.togglePicker(.place)
        check(model.focusedWorkspace?.name == "cineflow", "the list opens on the current workspace")
        model.moveSelection(1)
        model.enterSessions()
        model.pickSelected()
        check(model.target == .session(other.dockIdentity) && model.project?.name == "waw" && model.pickerKind == nil)
        model.clearSessionTarget()
        check(model.target == .agent(.codex) && model.project?.name == "waw", "stepping back keeps the agent and workspace")

        // Search: a name match stays on the workspace, a title match lands on the session.
        model.textChanged("继续 #cine", cursor: 8)
        check(model.pickerKind == .place && model.placePane == .workspaces && model.focusedWorkspace?.name == "cineflow" && model.focusedSessions.count == 2)
        model.textChanged("继续 #有效", cursor: 6)
        check(model.placePane == .sessions && model.focusedSessions.map(\.title) == ["有效期排查"] && model.primaryVerb == "继续这个会话", "Enter must not start a new session here")
        model.submit()
        check(model.target == .session(idle.dockIdentity) && model.draft == "继续 ", "the token leaves the text")
        model.textChanged("x #不存在", cursor: 6)
        check(!model.pickerVisible, "no match closes the list so Enter can send the literal text")
        model.textChanged("", cursor: 0)

        // A pointer focuses a workspace, and the keyboard carries on from there.
        model.togglePicker(.place)
        model.focusWorkspace(at: 2)
        check(model.focusedWorkspace?.name == "waw")
        model.focusWorkspace(at: 9)
        check(model.focusedWorkspace?.name == "waw", "an index out of range changes nothing")
        check(model.sessionCount(in: QuickInputProject(path: "/repo/cineflow")) == 2 && model.sessionCount(in: .all) == 3)
        model.closePicker()

        // A pending request makes a session wait, even when its own record has not caught up.
        model.pick(session: running)
        check(model.primaryVerb == "插入当前步")
        state.agentInteractions = [.init(request: PermissionRequest(id: "r", source: .codex, sessionID: running.id, toolName: "Bash", summary: "ls", detail: nil, cwd: "/repo/cineflow", at: Date()))]
        check(model.primaryVerb == "打开会话" && model.targetSession?.event == .approval, "a request is never talked over: \(model.primaryVerb)")
    }

    static func sending() {
        let state = makeState()
        var data = AgentDockData()
        let running = session("00000000-0000-4000-8000-000000000001", running: true)
        let idle = session("00000000-0000-4000-8000-000000000002", title: "订阅校验", running: false)
        data.sessions = [running, idle]
        state.agentDashboard = data
        var outcome = AgentMessageOutcome.steered
        var sent: [(String, String)] = []
        state.sendAgentMessage = { session, text in sent.append((session.id, text)); return outcome }
        let model = QuickInputModel(state: state, environment: environment())
        model.prepareForSummon()

        model.pick(session: running)
        check(model.primaryVerb == "插入当前步" && model.secondaryVerb == "打开会话", "the button says what happens")
        model.textChanged("补充", cursor: 2)
        model.submit()
        eventually({ sent.count == 1 && model.receipt?.title == "已插入当前这一步" }, "steering reports what happened")
        check(state.quickInputPulse.source == .codex && state.quickInputPulse.landings == 1)
        check(model.draft.isEmpty && model.target == .agent(.codex), "the next message starts as a new session for the same agent")

        // An uncertain result keeps the text, warns, and never resends.
        model.pick(session: idle)
        check(model.primaryVerb == "发送" && model.secondaryVerb == "打开会话")
        outcome = .uncertain
        model.textChanged("继续", cursor: 2)
        model.submit()
        eventually({ model.receipt?.tone == .warning }, "uncertain reaches a receipt")
        check(sent.count == 2 && model.warning != nil && model.receipt?.lingers == true)
        check(model.receipt?.actions.contains(.restore("继续")) == true && model.receipt?.actions.contains(.dismiss) == true)
        model.perform(.restore("继续"))
        check(model.draft == "继续" && model.receipt == nil && model.target == .session(idle.dockIdentity))

        // A refused message comes back too, and the dock shakes rather than bumps.
        outcome = .unavailable
        model.submit()
        eventually({ model.receipt?.tone == .failure }, "failure reaches a receipt")
        check(state.quickInputPulse.rejections == 1 && model.receipt?.lingers == true)
        model.perform(.dismiss)
        check(model.receipt == nil, "every lingering receipt can be closed")
    }

    /// ⌘Enter as a router: nothing typed, or straight from an open list.
    static func jumping() {
        let state = makeState()
        var opened: [AgentDockSession] = [], links: [URL] = [], copied: [String] = []
        state.openAgentSession = { opened.append($0) }
        var data = AgentDockData()
        let idle = session("00000000-0000-4000-8000-000000000001", title: "充值有效期排查", cwd: "/repo/cineflow")
        data.sessions = [idle, session("00000000-0000-4000-8000-000000000002", title: "订阅校验", cwd: "/repo/waw")]
        state.agentDashboard = data
        var dismissed = 0
        let model = QuickInputModel(state: state, environment: environment(opened: { links.append($0) }, copied: { copied.append($0) }))
        model.onDismiss = { dismissed += 1 }
        model.prepareForSummon()

        // Nothing typed, no list: an empty client at the workspace. Nothing to report afterwards.
        model.submit(openClient: true)
        check(model.pickerKind == .agent && links.isEmpty, "it still needs to know who")
        model.pick(model.rows.first { $0.source == .codex }!)
        model.pick(workspace: QuickInputProject(path: "/repo/cineflow"))
        model.submit(openClient: true)
        check(links.last?.absoluteString == "codex://new?path=%2Frepo%2Fcineflow" && dismissed == 1 && model.receipt == nil, "an empty jump: \(links)")
        model.submit()
        check(links.count == 1, "Enter with nothing typed does nothing")

        // Typing `#关键词` and ⌘Enter goes straight to the session, and the token never reaches the clipboard.
        model.textChanged("#有效", cursor: 3)
        check(model.pickerVisible && model.secondaryVerb == "打开会话")
        model.submit(openClient: true)
        check(opened.map(\.id) == [idle.id] && copied.isEmpty && model.draft.isEmpty && !model.pickerVisible)

        // With text it carries the text along.
        model.textChanged("带上这句 #订阅", cursor: 8)
        model.submit(openClient: true)
        check(opened.count == 2 && copied == ["带上这句"], "copied \(copied)")

        // A workspace selected in the list opens a new client there.
        model.togglePicker(.place)
        model.focusWorkspace(at: model.workspaces.firstIndex(of: QuickInputProject(path: "/repo/waw"))!)
        check(model.secondaryVerb == "在 Codex 打开")
        model.submit(openClient: true)
        check(links.last?.absoluteString == "codex://new?path=%2Frepo%2Fwaw" && !model.pickerVisible)

        // All sessions has nowhere to open; ⌘Enter moves into the list like Enter does.
        model.togglePicker(.place)
        model.focusWorkspace(at: 0)
        model.submit(openClient: true)
        check(model.placePane == .sessions && model.pickerVisible)
        model.submit(openClient: true)
        check(opened.count == 3)
    }

    static func openingSessions() {
        let state = makeState()
        var opened: [AgentDockSession] = [], copied: [String] = [], sent = 0
        state.openAgentSession = { opened.append($0) }
        state.sendAgentMessage = { _, _ in sent += 1; return .accepted }
        var data = AgentDockData()
        let running = session("00000000-0000-4000-8000-000000000001", running: true)
        let claude = session("00000000-0000-4000-8000-000000000002", source: .claude, title: "终端会话", sendable: false)
        let lost = session("00000000-0000-4000-8000-000000000003", source: .claude, title: "找不到窗口", sendable: false, reachable: false)
        let waiting = session("00000000-0000-4000-8000-000000000004", title: "等审批", event: .approval)
        data.sessions = [running, claude, lost, waiting]
        state.agentDashboard = data
        let model = QuickInputModel(state: state, environment: environment(copied: { copied.append($0) }))
        model.prepareForSummon()

        // ⌘Enter opens even a session that could take the message; queueing is the client's business.
        model.pick(session: running)
        model.textChanged("补一句", cursor: 3)
        model.submit(openClient: true)
        check(opened.map(\.id) == [running.id] && copied == ["补一句"] && sent == 0)
        check(model.receipt?.title == "已打开会话，内容已复制" && model.draft.isEmpty)

        // With nothing typed it is simply a jump, and the clipboard is left alone.
        model.pick(session: running)
        model.submit(openClient: true)
        check(opened.count == 2 && copied.count == 1)

        // A session that cannot take messages opens on Enter, and the button says so.
        model.pick(session: claude)
        check(model.primaryVerb == "打开会话" && model.secondaryVerb == nil && model.hint?.contains("只能在客户端") == true)
        model.textChanged("转过去", cursor: 3)
        model.submit()
        check(opened.count == 3 && copied.last == "转过去" && sent == 0)

        // Waiting on the user: never inject, take them there.
        model.pick(session: waiting)
        check(model.primaryVerb == "打开会话" && model.hint?.contains("等你回应") == true)
        model.textChanged("先别", cursor: 2)
        model.submit()
        check(opened.count == 4 && sent == 0)

        // With no route, the resume command must not overwrite what was copied.
        model.pick(session: lost)
        model.textChanged("留着", cursor: 2)
        model.submit()
        check(opened.count == 4 && copied.last == "留着" && model.receipt?.title == "这个会话没有跳转入口")

        // A session that disappears is explained, and nothing is lost.
        model.pick(session: running)
        model.textChanged("还在", cursor: 2)
        state.agentDashboard = AgentDockData()
        model.submit()
        check(model.notice?.contains("不在列表") == true && model.draft == "还在" && model.target == nil)
    }

    private static func key(_ code: Int, _ characters: String, _ flags: NSEvent.ModifierFlags = [], to window: NSWindow) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                           context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code)) else { return }
        window.firstResponder?.keyDown(with: event)
        spin()
    }
    private static func textView(in view: NSView?) -> QuickInputTextView? {
        guard let view else { return nil }
        if let text = view as? QuickInputTextView { return text }
        for child in view.subviews { if let found = textView(in: child) { return found } }
        return nil
    }

    /// Real panel, real text view, keys delivered in process. The composing case is what
    /// makes Chinese input safe: Return must commit the candidate, not send.
    static func keyboard() throws {
        let state = makeState()
        var data = AgentDockData()
        data.sessions = [session("00000000-0000-4000-8000-000000000001", cwd: "/repo/cineflow"), session("00000000-0000-4000-8000-000000000002", title: "另一个", cwd: "/repo/cineflow")]
        state.agentDashboard = data
        var started: [QuickInputStart.Request] = [], opened: [URL] = []
        let controller = QuickInputController(state: state, environment: environment(opened: { opened.append($0) }, started: { started.append($0) }), tileCenter: { _ in nil }, dockFrame: { nil })
        state.quickInputSummon.send()
        eventually({ controller.isShown }, "the summon signal shows the panel")
        spin(0.3)
        let panel = controller.panel
        check(panel.styleMask.contains(.nonactivatingPanel) && panel.canBecomeKey && !panel.canBecomeMain)
        eventually({ textView(in: panel.contentView) != nil }, "the editor exists")
        let text = textView(in: panel.contentView)!
        panel.makeKey(); panel.makeFirstResponder(text); spin(0.1)
        check(panel.firstResponder === text, "typing goes straight to the editor")
        check(panel.frame.width == 640 && panel.frame.height >= 60, "panel size: \(panel.frame.size)")
        let compact = panel.frame

        text.setMarkedText("jian", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        check(text.hasMarkedText())
        controller.model.textChanged(text.string, cursor: text.selectedRange().location)
        key(36, "\r", to: panel)
        check(started.isEmpty && controller.isShown, "Return while composing never sends")
        text.unmarkText(); text.string = ""; controller.model.textChanged("", cursor: 0)

        text.insertText("第一行", replacementRange: text.selectedRange())
        check(controller.model.draft == "第一行")
        key(36, "\r", [.shift], to: panel)
        check(text.string == "第一行\n" && controller.model.draft == "第一行\n" && started.isEmpty, "Shift-Return is a newline, got \(text.string.debugDescription)")
        text.insertText("第二行", replacementRange: text.selectedRange())
        spin(0.4)
        check(panel.frame.height > compact.height + 10, "the panel grows with its text: \(panel.frame.height) from \(compact.height)")
        check(abs(panel.frame.maxY - compact.maxY) < 1, "the top edge stays put")

        key(36, "\r", to: panel)
        check(controller.model.pickerKind == .agent && controller.isShown && started.isEmpty, "Return opens what is missing")
        spin(0.35)
        check(panel.frame.height > 150, "the list opens inside the same panel: \(panel.frame.height)")
        check(abs(panel.frame.maxY - compact.maxY) < 1, "opening the list keeps the top edge")
        key(53, "\u{1b}", to: panel)
        check(controller.model.pickerKind == nil && controller.isShown, "Escape closes the list first")
        key(48, "\t", to: panel)
        check(controller.model.pickerKind == .agent, "Tab opens who")
        key(125, "", to: panel)
        check(controller.model.selection == 1)
        key(126, "", to: panel)
        check(controller.model.selection == 0)
        key(36, "\r", to: panel)
        check(controller.model.target == .agent(.codex) && controller.model.pickerKind == .place, "then where")
        spin(0.35)
        check(panel.frame.height > 280, "both columns fit: \(panel.frame.height)")
        key(124, "", to: panel)
        check(controller.model.placePane == .sessions && controller.model.sessionIndex == 1, "right arrow enters the sessions")
        key(123, "", to: panel)
        check(controller.model.placePane == .workspaces, "left arrow returns")
        key(48, "\t", to: panel)
        check(controller.model.placePane == .sessions, "Tab moves across too")
        key(48, "\t", to: panel)
        check(controller.model.focusedWorkspace == .all, "nothing chosen yet, so the list starts on all sessions")
        key(125, "", to: panel)
        key(36, "\r", to: panel)
        check(controller.model.project?.name == "cineflow" && controller.model.pickerKind == nil)
        spin(0.35)
        check(panel.frame.height < 200, "the panel closes back up: \(panel.frame.height)")

        key(53, "\u{1b}", to: panel)
        spin(0.3)
        check(!controller.isShown && controller.model.draft == "第一行\n第二行", "Escape hides the panel and keeps the draft")
        state.quickInputSummon.send()
        eventually({ controller.isShown }, "it comes back")
        spin(0.2)
        check(textView(in: panel.contentView)?.string == "第一行\n第二行", "the draft is still in the editor")

        // ⌘Return and Return take their own paths with the real keys.
        panel.makeKey(); panel.makeFirstResponder(text); spin(0.05)
        key(36, "\r", [.command], to: panel)
        check(opened.count == 1 && started.isEmpty, "⌘Return opens the client")
        spin(0.3)
        state.quickInputSummon.send()
        eventually({ controller.isShown }, "it comes back")
        spin(0.2)
        panel.makeKey(); panel.makeFirstResponder(text); spin(0.05)
        text.insertText("开工", replacementRange: text.selectedRange())
        key(36, "\r", to: panel)
        check(started.count == 1 && started[0].prompt == "开工" && started[0].directory == "/repo/cineflow", "Return starts it")
        spin(0.3)
        check(!controller.isShown && !panel.isVisible, "the panel leaves at once")

        // Registering the shortcut used by play controls reports it instead of failing silently.
        let hotKeys = InteractionShortcut(state: state)
        spin(0.1)
        check(state.quickInputShortcutError == nil, "\(state.quickInputShortcutError ?? "")")
        state.shortcutModifiers = 1; state.shortcutKey = 40
        state.quickInputShortcut = .controlOptionK
        spin(0.1)
        check(state.quickInputShortcutError != nil || state.shortcutError != nil, "a clash is reported")
        state.quickInputShortcut = .optionSpace
        state.quickInputEnabled = false
        spin(0.1)
        check(state.quickInputShortcutError == nil, "turning it off clears the error")
        withExtendedLifetime(hotKeys) {}
        withExtendedLifetime(controller) {}
    }

    private static func dock(_ state: AppState) -> DesktopDockController {
        let bundle = Bundle(path: "dist/While AI Works.app")!
        state.desktopEnabled = false; state.desktopPetEnabled = true; state.desktopPetPresentation = .dock
        return DesktopDockController(state: state, mascot: MascotController(bundle: bundle), cardMascot: MascotController(bundle: bundle))
    }
    private static func compose(_ windows: [NSWindow], to url: URL) {
        let ids = windows.map { CGWindowID($0.windowNumber) }
        let list = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }.withUnsafeBufferPointer { CFArrayCreate(nil, unsafeBitCast($0.baseAddress, to: UnsafeMutablePointer<UnsafeRawPointer?>?.self), ids.count, nil) }!
        guard let image = CGImage(windowListFromArrayScreenBounds: .null, windowArray: list, imageOption: [.boundsIgnoreFraming, .bestResolution]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        print("snapshot: \(url.path)")
    }

    /// The panel against the real dock: the note must land on the right tile, the tile
    /// must react, and the receipt must sit beside the dock on whichever edge it is on.
    static func dockHandover() {
        let state = makeState()
        var data = AgentDockData()
        let running = session("00000000-0000-4000-8000-000000000001", running: true)
        data.sessions = [running]
        state.agentDashboard = data
        state.sendAgentMessage = { _, _ in .steered }
        let dockController = dock(state)
        dockController.refresh(); spin(0.5)
        guard let center = dockController.tileCenter(for: .codex), let frame = dockController.visibleDockFrame else { check(false, "the dock is on screen"); return }
        check(frame.contains(center), "the tile is inside the dock")
        check(dockController.tileCenter(for: .workbuddy) == nil, "an unwatched source has no tile")
        let controller = QuickInputController(state: state, environment: environment(), tileCenter: { dockController.tileCenter(for: $0) }, dockFrame: { dockController.visibleDockFrame })
        controller.show(); spin(0.3)
        controller.model.pick(session: running)
        textView(in: controller.panel.contentView)?.insertText("补充", replacementRange: NSRange(location: 0, length: 0))
        let landings = state.quickInputPulse.landings
        controller.model.submit()
        spin(0.2)
        check(state.quickInputPulse.landings == landings, "the tile reacts when the note arrives, not when it leaves")
        eventually({ state.quickInputPulse.landings == landings + 1 }, "the flight finishes")
        check(state.quickInputPulse.source == .codex)
        eventually({ controller.model.receipt?.title == "已插入当前这一步" }, "the receipt reports the result")
        spin(0.4)
        let receipt = controller.receiptPanel.frame
        check(controller.receiptPanel.isVisible && controller.receiptPanel.alphaValue > 0.9, "the receipt shows")
        check(receipt.height > 40, "the receipt has its size: \(receipt)")
        check(receipt.maxX <= frame.minX && receipt.maxX >= frame.minX - 40, "the receipt sits beside a right-edge dock: \(receipt) \(frame)")
        check(!controller.isShown && !controller.panel.isVisible, "the panel has left")
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--snapshot"), index + 1 < ProcessInfo.processInfo.arguments.count {
            compose([controller.receiptPanel], to: URL(fileURLWithPath: ProcessInfo.processInfo.arguments[index + 1]).appendingPathComponent("quick-input-receipt.png"))
        }
        controller.model.dismissReceipt(); spin(0.3)
        withExtendedLifetime(controller) {}
        withExtendedLifetime(dockController) {}
    }

    /// This Mac's own sessions through the app's own pipeline. Reads only: nothing is sent.
    /// Quit the installed app first, as the two would share its local sockets.
    @MainActor static func realData(_ arguments: [String]) {
        let state = makeState()
        let hub = AgentHubDataController(state: state)
        let begin = Date()
        while state.agentDashboard.updatedAt == nil && Date().timeIntervalSince(begin) < 90 { spin(0.2) }
        spin(5)
        let data = state.agentDashboard
        print("real sessions \(data.sessions.count), quotas \(data.quotas.count)")
        let roots = data.sessions.filter { $0.parentSessionID == nil }
        print("real roots \(roots.count), no directory \(roots.filter { QuickInputCatalog.path(of: $0) == nil }.count), directory gone \(roots.filter { QuickInputCatalog.path(of: $0).map { !FileManager.default.fileExists(atPath: $0) } ?? false }.count)")
        let controller = QuickInputController(state: state, environment: environment(), tileCenter: { _ in nil }, dockFrame: { nil })
        let model = controller.model
        controller.show(); spin(0.3)
        model.togglePicker(.place); spin(0.5)
        print("dock order:", model.dockSessions.filter { $0.parentSessionID == nil }.prefix(5).map { String($0.title.prefix(10)) + "/" + "\($0.event)" })
        for project in model.workspaces.prefix(6) {
            print("workspace", project.name, model.sessionCount(in: project))
        }
        for session in model.focusedSessions.prefix(6) {
            let row = QuickInputCatalog.sessionRow(session)
            print("session", String(session.title.prefix(24)), "|", row.trailing, "| takes", QuickInputCatalog.takesMessages(session))
        }
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            compose([controller.panel], to: URL(fileURLWithPath: arguments[index + 1]).appendingPathComponent("quick-input-real-place.png"))
        }
        controller.dismiss(); spin(0.3)
        hub.stop()
        withExtendedLifetime(hub) {}
        withExtendedLifetime(controller) {}
    }

    /// Windows are captured over a bright backdrop window so the layout has something to sit on.
    static func snapshots(_ directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [true, false] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            let state = makeState()
            state.desktopCompanionAppearance = dark ? .dark : .light
            var data = AgentDockData()
            data.quotas = [AgentDockQuota(id: "c", source: .codex, title: "每周", remaining: 64, resetAt: nil, observedAt: Date(), stale: false, window: .weekly),
                           AgentDockQuota(id: "l", source: .claude, title: "会话", remaining: 8, resetAt: nil, observedAt: Date(), stale: false, window: .session)]
            let running = session("00000000-0000-4000-8000-000000000001", running: true)
            data.sessions = [running, session("00000000-0000-4000-8000-000000000005", title: "充值有效期排查"),
                             session("00000000-0000-4000-8000-000000000006", source: .claude, title: "分镜批量重做", sendable: false),
                             session("00000000-0000-4000-8000-000000000002", title: "订阅校验重试", cwd: "/repo/while-ai-works"),
                             session("00000000-0000-4000-8000-000000000003", source: .claude, title: "修复会话跳转入口", cwd: "/repo/while-ai-works", event: .approval, sendable: false)]
            state.agentDashboard = data
            let controller = QuickInputController(state: state, environment: environment(), tileCenter: { _ in nil }, dockFrame: { nil })
            let name = dark ? "dark" : "light"
            let backdrop = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 620), styleMask: [.borderless], backing: .buffered, defer: false)
            backdrop.isReleasedWhenClosed = false
            backdrop.level = .floating
            backdrop.contentView = NSHostingView(rootView: SnapshotBackdrop(dark: dark))
            backdrop.orderFrontRegardless()
            func capture(_ label: String, _ window: NSWindow) {
                backdrop.setFrame(NSRect(x: window.frame.midX - 450, y: window.frame.maxY - 520, width: 900, height: 620), display: true)
                spin(0.5)
                compose([window, backdrop], to: directory.appendingPathComponent("quick-input-\(name)-\(label).png"))
            }
            controller.show(); spin(0.4)
            let model = controller.model
            let editor = textView(in: controller.panel.contentView)
            editor?.insertText("检查一下充值有效期的处理，重点看边界情况", replacementRange: editor?.selectedRange() ?? NSRange())
            capture("first", controller.panel)
            model.togglePicker(.agent)
            capture("agent", controller.panel)
            model.pick(model.rows.first { $0.source == .codex }!)
            capture("place", controller.panel)
            model.enterSessions()
            capture("place-sessions", controller.panel)
            model.leaveSessions()
            model.pick(workspace: model.workspaces[0])
            capture("new", controller.panel)
            model.pick(session: running)
            editor?.string = ""
            editor?.insertText("顺便把退款路径也看一下", replacementRange: NSRange(location: 0, length: 0))
            capture("running", controller.panel)
            controller.dismiss(); spin(0.3)
            backdrop.orderOut(nil)
            withExtendedLifetime(controller) {}
        }
    }
}

private struct SnapshotBackdrop: View {
    let dark: Bool
    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: dark ? [Color(red: 0.07, green: 0.14, blue: 0.23), Color(red: 0.09, green: 0.23, blue: 0.27), Color(red: 0.17, green: 0.15, blue: 0.28)] : [Color(red: 0.75, green: 0.84, blue: 0.93), Color(red: 0.75, green: 0.89, blue: 0.85), Color(red: 0.85, green: 0.81, blue: 0.94)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 14) {
                Text("充值规则评审").font(.system(size: 26, weight: .semibold))
                Text("本次调整年卡和礼品卡的有效期计算方式。购买后立即生效，到期前七天提醒，到期后保留余额三十天。").font(.system(size: 15))
                Rectangle().fill(Color.blue).frame(height: 36)
                Text("待确认：退款发生在有效期内时，赠送部分如何折算，需要产品和财务一起确认。").font(.system(size: 15)).background(Color.yellow.opacity(0.6))
                Text("边界情况：跨时区购买、连续购买叠加、到期当天退款。这几项还没有明确结论，需要在上线前补齐用例。").font(.system(size: 15))
                Rectangle().fill(Color.orange).frame(height: 36)
            }
            .foregroundStyle(dark ? Color.white : Color.black)
            .padding(26).frame(width: 520).background(dark ? Color(white: 0.16) : Color.white)
        }
        .frame(width: 900, height: 620)
    }
}
