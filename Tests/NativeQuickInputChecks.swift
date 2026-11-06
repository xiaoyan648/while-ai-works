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

private enum Kind { case codexApp, claudeApp, cli, noRoute }
private func session(_ id: String, source: WorkSource = .codex, title: String = "修复充值边界", cwd: String? = "/repo/cineflow", running: Bool = false,
                     event: AgentSessionEvent = .recent, kind: Kind = .codexApp) -> AgentDockSession {
    let identifier = (UUID(uuidString: id) ?? UUID()).uuidString.lowercased()
    let url: String?
    switch kind {
    case .codexApp: url = "codex://threads/" + identifier
    case .claudeApp: url = "claude://claude.ai/epitaxy/local_" + identifier
    case .cli, .noRoute: url = nil
    }
    let resume = kind == .cli ? (source == .claude ? "claude --resume " : "codex resume ") + identifier : nil
    return AgentDockSession(id: identifier, source: source, title: title, project: cwd.map { URL(fileURLWithPath: $0).lastPathComponent }, status: running ? "工作中" : "最近会话",
                            running: running, tokensIn: 0, tokensOut: 0, cacheRead: 0, reply: nil, observedAt: Date(),
                            navigationURL: url.flatMap(URL.init(string:)), resumeCommand: resume,
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
        scripts()
        catalog()
        newSessions()
        placePicker()
        sessions()
        localSessions()
        otherClients()
        dshOnlyOpens()
        dshNavigationResults()
        returnList()
        returnRoutes()
        try keyboard()
        returnKeyboard()
        dockHandover()
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count { snapshots(URL(fileURLWithPath: arguments[index + 1], isDirectory: true)) }
        print("Quick input checks passed")
    }

    private static func makeState() -> AppState {
        let suite = "WhileAIWorks.QuickInputChecks." + UUID().uuidString
        let state = AppState(defaults: UserDefaults(suiteName: suite)!)
        state.soundEnabled = false; state.selectedSources = [.codex, .claude, .hermes, .dsh]
        return state
    }
    private static func environment(opened: ((URL) -> Void)? = nil, copied: ((String) -> Void)? = nil, ran: ((QuickInputRun.Request) -> Void)? = nil,
                                    runs: Bool = true, timeout: TimeInterval = 25, claudeWorks: Bool? = nil) -> QuickInputEnvironment {
        var value = QuickInputEnvironment()
        value.open = { opened?($0); return true }
        value.isAvailable = { _ in true }
        value.copy = { copied?($0) }
        value.directoryExists = { _ in true }
        value.run = { ran?($0); return runs ? "io.appmakes.otty" : nil }
        value.activate = { _ in }
        value.startTimeout = timeout
        value.claudeCodeReadiness = { claudeWorks }
        value.liveSessions = { [:] }
        value.localRecords = { QuickInputLocalRecords() }
        value.bringOwnerForward = { _ in true }
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
        let codex = QuickInputClient.codexApp.appLink(path: "/repo/云 流", prompt: "a+b & c=d\n第二行")!.absoluteString
        check(codex.hasPrefix("codex://new?path=%2Frepo%2F"))
        check(codex.contains("prompt=a%2Bb%20%26%20c%3Dd%0A"), "plus and ampersand must survive: \(codex)")
        let claude = QuickInputClient.claudeApp.appLink(path: "/repo/x", prompt: "看一下")!.absoluteString
        check(claude.hasPrefix("claude://code/new?folder=%2Frepo%2Fx&source=while-ai-works&q=%E7%9C%8B"), claude)
        check(QuickInputClient.codexApp.appLink(path: "/repo", prompt: nil)!.absoluteString == "codex://new?path=%2Frepo")
        check(QuickInputClient.codexCLI.appLink(path: "/repo", prompt: "x") == nil)
        check(QuickInputClient.codexCLI.source == .codex && QuickInputClient.codexCLI.runsInTerminal && !QuickInputClient.codexApp.runsInTerminal)
        check(QuickInputClient.claudeCode.source == .claude && QuickInputClient.claudeCode.runsInTerminal && !QuickInputClient.claudeApp.runsInTerminal)
    }

    /// Runs the generated script for real against a stand-in client: hostile text must arrive byte for byte.
    static func scripts() {
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
        let promptFile = folder.appendingPathComponent("p.txt"), scriptFile = folder.appendingPathComponent("s.command")
        func run(_ command: QuickInputRun.Command, prompt text: String?) -> String {
            try? manager.removeItem(at: output)
            if let text { try! text.write(to: promptFile, atomically: true, encoding: .utf8) }
            let script = QuickInputRun.script(.init(command: command, directory: workspace.path, prompt: text), executable: client.path,
                                              promptFile: text == nil ? nil : promptFile.path, searchPath: "/usr/bin:/bin")!
            try! script.write(to: scriptFile, atomically: true, encoding: .utf8)
            try! manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptFile.path)
            let process = Process(); process.executableURL = scriptFile
            try! process.run(); process.waitUntilExit()
            check(process.terminationStatus == 0, "\(command) failed")
            check(!manager.fileExists(atPath: promptFile.path) && !manager.fileExists(atPath: scriptFile.path), "the private files are removed")
            return (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        }
        for (command, parts, wrapped) in [(QuickInputRun.Command.new(.claudeCode), ["[--]"], false),
                                          (.new(.codexCLI), ["[-C]", "[" + workspace.path + "]", "[--]"], false),
                                          (.new(.hermes), ["[chat]", "[--in]"], true),
                                          (.resume(.claudeCode, id: "abc"), ["[--resume]", "[abc]", "[--]"], false),
                                          (.resume(.codexCLI, id: "abc"), ["[resume]", "[-C]", "[abc]", "[--]"], false)] {
            let lines = run(command, prompt: prompt)
            check(lines.contains(workspace.lastPathComponent), "runs in the workspace: \(lines)")
            for part in parts { check(lines.contains(part), "\(command) misses \(part): \(lines)") }
            check(lines.contains(wrapped ? "[--query=" + prompt + "]" : "[" + prompt + "]"), "\(command) mangled the prompt: \(lines)")
        }
        check(!run(.new(.claudeCode), prompt: nil).contains("--"), "opening passes no prompt")
        check(run(.resume(.claudeCode, id: "abc"), prompt: nil).contains("[abc]"))
        check(!manager.fileExists(atPath: "/tmp/waw-should-not-exist"), "the prompt is never executed")
        check(QuickInputRun.line(.new(.codexApp), executable: "x", directory: "/", hasPrompt: false) == nil, "apps do not run in terminals")
        check(QuickInputRun.line(.recorded("hermes --resume 'a'"), executable: nil, directory: "/", hasPrompt: false) == "hermes --resume 'a'")

        let app = URL(fileURLWithPath: "/Applications/T.app")
        let otty = QuickInputLauncher.command(terminal: "io.appmakes.otty", application: app, script: "/t/it's.command", directory: "/repo")
        check(otty.executable.path.hasSuffix("MacOS/otty-cli") && otty.arguments == ["open", "/repo", "--command", "'/t/it'\\''s.command'", "--quiet"], "\(otty.arguments)")
        for terminal in ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "anything.else"] {
            let generic = QuickInputLauncher.command(terminal: terminal, application: app, script: "/t/s.command", directory: "/repo")
            check(generic.executable.path == "/usr/bin/open" && generic.arguments == ["/t/s.command"], "every other terminal takes the system's route")
        }
        check(QuickInputReadiness.claudeLoggedIn(status: Data(#"{"loggedIn":false}"#.utf8)) == false && QuickInputReadiness.claudeLoggedIn(status: Data("x".utf8)) == nil, "an unreadable answer is not a no")
        check(QuickInputClient.threadLink(session("00000000-0000-4000-8000-000000000001"), prompt: "a b&c")?.absoluteString == "codex://threads/00000000-0000-4000-8000-000000000001?prompt=a%20b%26c", "an existing thread takes the text")
        check(QuickInputClient.threadLink(session("00000000-0000-4000-8000-000000000001", source: .claude, kind: .claudeApp), prompt: "x") == nil, "Claude's thread links drop it")

        // Liveness comes from the agents, whatever terminal they run in.
        let claudeFolder = folder.appendingPathComponent("sessions", isDirectory: true)
        try! manager.createDirectory(at: claudeFolder, withIntermediateDirectories: true)
        try! #"{"pid":101,"sessionId":"alive"}"#.write(to: claudeFolder.appendingPathComponent("101.json"), atomically: true, encoding: .utf8)
        try! #"{"pid":102,"sessionId":"gone"}"#.write(to: claudeFolder.appendingPathComponent("102.json"), atomically: true, encoding: .utf8)
        try! "not json".write(to: claudeFolder.appendingPathComponent("x.json"), atomically: true, encoding: .utf8)
        check(QuickInputLiveness.claudeSessions(in: claudeFolder, isAlive: { $0 == 101 }) == ["alive": 101])
        let lsof = "p44\nfcwd\nn/Users/x\nf9\nn/Users/x/.codex/sessions/2026/11/01/rollout-2026-11-01T05-14-17-01A1969A-505B-7C83-9886-AC937E4FA471.jsonl\np45\nn/tmp/rollout-notes.jsonl\n"
        check(QuickInputLiveness.codexSessions(lsof: lsof) == ["01a1969a-505b-7c83-9886-ac937e4fa471": 44], "\(QuickInputLiveness.codexSessions(lsof: lsof))")
        check(QuickInputLiveness.codexSessions(lsof: lsof, isShared: { $0 == 44 }).isEmpty, "the shared service keeps logs open with nobody there")
    }

    static func catalog() {
        let rows = QuickInputCatalog.clientRows(clients: QuickInputClient.allCases, claudeCodeWorks: false, quota: { _ in nil }, query: "")
        check(rows.map(\.title) == ["Codex", "Codex CLI", "Claude", "Claude Code", "Hermes", "DSH"], "what opens a session")
        check(rows.first { $0.client == .dsh }?.subtitle == "只打开已有会话" && !QuickInputClient.dsh.canStartNew)
        check(rows.first { $0.client == .claudeCode }?.subtitle.contains("未登录") == true)
        let low = AgentDockQuota(id: "c", source: .codex, title: "每周", remaining: 0, resetAt: nil, observedAt: Date(), stale: false, window: .weekly)
        check(QuickInputCatalog.clientRows(clients: [.codexApp], claudeCodeWorks: true, quota: { _ in low }, query: "").first?.tone == .attention, "almost no quota is flagged")
        check(QuickInputCatalog.clientRows(clients: QuickInputClient.allCases, claudeCodeWorks: true, quota: { _ in nil }, query: "cli").map(\.client) == [.codexCLI])

        let list = [session("00000000-0000-4000-8000-000000000001", cwd: "/repo/cineflow", running: true),
                    session("00000000-0000-4000-8000-000000000002", title: "等待", cwd: "/repo/waw", event: .approval),
                    session("00000000-0000-4000-8000-000000000003", source: .claude, title: "终端会话", cwd: "/repo/waw", kind: .cli),
                    session("00000000-0000-4000-8000-000000000004", title: "订阅校验", cwd: "/repo/waw")]
        let projects = QuickInputCatalog.projects(sessions: list, recents: ["/repo/old", "/repo/waw"], exists: { $0 != "/repo/old" })
        check(projects.map(\.path) == ["/repo/cineflow", "/repo/waw"], "dock order, then recents; unique and only existing directories")
        check(QuickInputCatalog.projects(sessions: [session("x", cwd: "/a/app"), session("y", cwd: "/b/app")], recents: [], exists: { _ in true }).count == 2, "worktrees with one name stay apart")
        let waw = QuickInputProject(path: "/repo/waw")
        check(QuickInputCatalog.sessions(in: waw, of: list, query: "").map(\.title) == ["等待", "终端会话", "订阅校验"], "the order given, which is the dock's")
        check(QuickInputCatalog.status(list[0]).text == "运行中" && QuickInputCatalog.status(list[1]).tone == .attention && QuickInputCatalog.status(list[2]).text == "空闲", "a row says the state, not the capability")
        check(QuickInputCatalog.workspaces(projects: projects, sessions: list, query: "").first == .all)
        check(QuickInputCatalog.workspaces(projects: projects, sessions: list, query: "订阅") == [.all, waw], "a session title finds all, then its workspace")
        check(QuickInputCatalog.workspaces(projects: projects, sessions: list, query: "waw").first == waw, "a workspace name comes first")
        let homeless = session("00000000-0000-4000-8000-000000000005", title: "无处可归", cwd: nil)
        check(QuickInputCatalog.sessions(in: .all, of: list + [homeless], query: "无处").count == 1, "a session with no workspace is still reachable")
        // A family shares its sessions; another family's are not listed anywhere under it.
        check(QuickInputCatalog.sessions(in: waw, of: list, query: "", client: .codexApp).map(\.title) == ["等待", "订阅校验"], "no Claude under Codex")
        check(QuickInputCatalog.sessions(in: waw, of: list, query: "", client: .claudeCode).map(\.title) == ["终端会话"])
        check(QuickInputCatalog.sessions(in: waw, of: list, query: "", client: .codexCLI).map(\.title) == ["等待", "订阅校验"], "Codex and Codex CLI see the same sessions")
        check(QuickInputCatalog.sessions(in: .all, of: list, query: "", client: .codexCLI).count == 3, "all is the current family")
        check(QuickInputCatalog.sessions(in: .all, of: list, query: "").count == 4, "with no Agent chosen, every family")
        check(QuickInputCatalog.workspaces(projects: projects, sessions: list, query: "终端", client: { _ in .codexApp }).isEmpty, "another family's session is not found")
        check(QuickInputCatalog.workspaces(projects: projects, sessions: list, query: "终端", client: { _ in .claudeApp }) == [.all, waw])
        check(QuickInputCatalog.workspaces(projects: projects, sessions: list, query: "repo").isEmpty, "a workspace matches by name, not by path")
        check(QuickInputCatalog.workspaces(projects: projects, sessions: list, query: "codex").isEmpty, "a client's name is what @ is for")
        // Browsing has a limit and search does not.
        let many = (0..<60).map { session(String(format: "00000000-0000-4000-8000-0000000001%02d", $0), title: "第 \($0) 条", cwd: "/repo/waw") }
        check(QuickInputCatalog.sessions(in: .all, of: many, query: "").count == 50 && QuickInputCatalog.sessions(in: .all, of: many, query: "第").count == 60)
        check(QuickInputCatalog.counts(of: many + list, in: [.all, waw], client: { _ in .codexApp }) == ["": 63, "/repo/waw": 62], "a count is what it holds, not what fits")
        let dead = session("00000000-0000-4000-8000-000000000006", title: "去不了", cwd: "/repo/waw", kind: .noRoute)
        check(!QuickInputCatalog.canOpen(dead) && QuickInputCatalog.sessions(in: .all, of: [dead], query: "").isEmpty, "nothing Enter cannot reach is listed")

        // Who can take a message.
        let app = session("00000000-0000-4000-8000-000000000011"), appRunning = session("00000000-0000-4000-8000-000000000012", running: true)
        let appWaiting = session("00000000-0000-4000-8000-000000000013", event: .approval), claudeApp = session("00000000-0000-4000-8000-000000000014", source: .claude, kind: .claudeApp)
        let ended = session("00000000-0000-4000-8000-000000000015", kind: .cli), endedClaude = session("00000000-0000-4000-8000-000000000016", source: .claude, kind: .cli)
        let liveCLI = session("00000000-0000-4000-8000-000000000017", running: true, kind: .cli)
        check(QuickInputCatalog.canSend(app, claudeCodeWorks: true) && QuickInputCatalog.canSend(appRunning, claudeCodeWorks: true))
        check(!QuickInputCatalog.canSend(appWaiting, claudeCodeWorks: true), "a session waiting on the user is never talked over")
        check(!QuickInputCatalog.canSend(claudeApp, claudeCodeWorks: true), "Claude's app has no way in")
        check(QuickInputCatalog.canSend(ended, claudeCodeWorks: true) && QuickInputCatalog.canSend(endedClaude, claudeCodeWorks: true), "an ended terminal session resumes with the message")
        check(!QuickInputCatalog.canSend(endedClaude, claudeCodeWorks: false), "not logged in, not sendable")
        check(!QuickInputCatalog.canSend(liveCLI, claudeCodeWorks: true), "a running terminal session cannot be resumed a second time")
        check(!QuickInputCatalog.canSend(ended, claudeCodeWorks: true, live: [ended.id]), "idle but held by a process: two would share it")
        // The opener decides: a command line resumes what its app began. Only sessions that truly have no holder.
        let desktop = QuickInputSessionIndex.record(claudeApp.id, .claude, title: "桌面", directory: "/repo/waw", at: Date(), url: claudeApp.navigationURL, resume: "claude --resume " + claudeApp.id)
        check(QuickInputCatalog.canSend(desktop, via: .claudeCode, claudeCodeWorks: true) && !QuickInputCatalog.canSend(desktop, via: .claudeCode, claudeCodeWorks: false))
        check(!QuickInputCatalog.canSend(ended, via: .codexApp, claudeCodeWorks: true), "an app only fills, whatever the session could do")
        check(!QuickInputCatalog.canSend(desktop, via: .claudeCode, claudeCodeWorks: true, live: [desktop.id]))
        let old = QuickInputSessionIndex.record(app.id, .codex, title: "旧", directory: "/repo/waw", at: Date(), url: app.navigationURL, resume: "codex resume " + app.id)
        check(!old.canSend && !QuickInputCatalog.canSend(old, claudeCodeWorks: true), "an old thread has no owner to send to")
        check(QuickInputCatalog.canSend(old, via: .codexCLI, claudeCodeWorks: true), "a command line resumes it instead")
        check(QuickInputCatalog.client(of: claudeApp) == .claudeApp && QuickInputCatalog.client(of: endedClaude) == .claudeCode && QuickInputCatalog.client(of: app) == .codexApp && QuickInputCatalog.client(of: ended) == .codexCLI)
    }

    static func newSessions() {
        let state = makeState()
        var opened: [URL] = [], ran: [QuickInputRun.Request] = [], copied: [String] = [], dismissed = 0, flown: [WorkSource] = []
        let model = QuickInputModel(state: state, environment: environment(opened: { opened.append($0) }, copied: { copied.append($0) }, ran: { ran.append($0) }))
        model.onDismiss = { dismissed += 1 }
        model.onDispatch = { source, _, finish in flown.append(source); finish() }
        var data = AgentDockData()
        data.sessions = [session("00000000-0000-4000-8000-000000000001", running: true)]
        state.agentDashboard = data
        model.prepareForSummon()
        spin()
        check(model.target == nil && model.project == nil && model.primaryVerb == "下一步" && model.secondaryVerb == nil, "nothing is chosen for a first-time user")

        // Enter walks through what is missing and never loses the text or acts on a guess.
        model.textChanged("检查一下", cursor: 4)
        model.submit()
        check(model.pickerKind == .agent && model.pickerNote != nil && model.draft == "检查一下 @" && ran.isEmpty && opened.isEmpty, "the list opens as if @ had been typed: \(model.draft)")
        check(model.primaryVerb == "选中" && model.secondaryVerb == nil, "nowhere to go until there is a workspace")
        model.submit()
        check(model.target == .client(.codexApp) && model.pickerKind == .place && model.draft == "检查一下 #", "Enter in a list only chooses, and the next list follows: \(model.draft)")

        // A list that opened by itself searches like any other, and leaves nothing behind.
        model.textChanged("检查一下 #cine", cursor: 10)
        check(model.pickerVisible && model.pickerQuery == "cine" && model.focusedWorkspace?.name == "cineflow", "typing searches")
        model.pick(workspace: QuickInputProject(path: "/repo/cineflow"))
        check(model.project?.path == "/repo/cineflow" && model.pickerKind == nil && opened.isEmpty && ran.isEmpty, "choosing never acts")
        check(model.draft == "检查一下", "the trigger and its space are gone: \(model.draft.debugDescription)")
        model.togglePicker(.place)
        check(model.draft == "检查一下 #" && model.draftRevision > 0)
        model.textChanged("检查一下 #xy", cursor: 8)
        model.closePicker()
        check(model.draft == "检查一下", "Escape takes the search with it: \(model.draft.debugDescription)")
        model.togglePicker(.place)
        model.cursorMoved(2)
        check(model.draft == "检查一下" && model.pickerKind == nil, "moving away from the list closes it and leaves no stray trigger: \(model.draft.debugDescription)")
        model.togglePicker(.place)
        model.textChanged("检查一下 ", cursor: 5)
        check(model.draft == "检查一下 " && model.pickerKind == nil, "deleting the trigger by hand just closes the list")
        model.textChanged("检查一下", cursor: 4)
        model.togglePicker(.agent)
        model.togglePicker(.place)
        check(model.draft == "检查一下 #" && model.pickerKind == .place, "switching lists swaps the trigger: \(model.draft)")
        model.togglePicker(.place)
        check(model.draft == "检查一下" && model.pickerKind == nil, "closing it restores the text")

        // A desktop app cannot start work, so Enter carries the text there, filled in. One button, one action.
        check(model.primaryVerb == "带过去" && model.secondaryVerb == nil && !model.canSendNow)
        model.submit()
        check(opened.count == 1 && opened[0].absoluteString.hasPrefix("codex://new?path=%2Frepo%2Fcineflow&prompt=") && ran.isEmpty)
        check(dismissed == 1 && model.draft.isEmpty && copied.isEmpty && model.receipt == nil, "filled in, so nothing needs saying")

        // The next task starts from what was remembered, and survives a restart.
        model.prepareForSummon()
        check(model.target == .client(.codexApp) && model.project?.path == "/repo/cineflow")
        let reborn = QuickInputModel(state: state, environment: environment())
        reborn.prepareForSummon()
        check(reborn.target == .client(.codexApp) && reborn.project?.path == "/repo/cineflow", "the choice survives a restart")

        // With nothing typed there is nothing to hand over, so Enter simply opens.
        check(model.primaryVerb == "打开")
        model.submit()
        check(opened.last?.absoluteString == "codex://new?path=%2Frepo%2Fcineflow" && model.receipt == nil)

        // A command line can start work: Enter sends and stays here, and only claims what it has seen.
        model.togglePicker(.agent)
        model.pick(model.rows.first { $0.client == .codexCLI }!)
        check(model.draft.isEmpty, "an empty draft gets no stray space")
        check(model.primaryVerb == "打开" && !model.canSendNow, "nothing to send yet, so Enter opens it")
        model.textChanged("开工", cursor: 2)
        check(model.primaryVerb == "发送" && model.secondaryVerb == "打开" && model.canSendNow)
        model.submit()
        check(ran.last == .init(command: .new(.codexCLI), directory: "/repo/cineflow", prompt: "开工", background: true))
        check(flown == [.codex] && model.draft.isEmpty && model.receipt?.title.contains("正在启动") == true && state.quickInputPulse.landings == 1)
        var after = data
        after.sessions.append(session("00000000-0000-4000-8000-000000000009", title: "别的目录", cwd: "/repo/other", kind: .cli))
        state.agentDashboard = after
        check(model.receipt?.title.contains("正在启动") == true, "a new session elsewhere proves nothing")
        after.sessions.append(session("00000000-0000-4000-8000-000000000010", title: "开工", cwd: "/repo/cineflow", kind: .cli))
        state.agentDashboard = after
        check(model.receipt?.title == "交给 Codex CLI 了" && model.receipt?.body == "开工" && model.receipt?.lingers == false)

        // ⌘Enter follows it there instead: the terminal in front, the text on the clipboard.
        model.dismissReceipt()
        model.textChanged("带过去", cursor: 3)
        model.submit(go: true)
        check(ran.last == .init(command: .new(.codexCLI), directory: "/repo/cineflow") && copied.last == "带过去" && model.receipt?.title == "内容已复制")
        model.dismissReceipt()

        // In a list Enter only chooses, so picking a target can never send anything. ⌘Enter goes straight there.
        let starts = ran.count
        model.textChanged("看一下 @cla", cursor: 8)
        check(model.pickerVisible && model.rows.first?.client == .claudeApp && model.secondaryVerb == "打开")
        model.submit()
        check(model.draft == "看一下 " && model.target == .client(.claudeApp) && model.pickerKind == nil && ran.count == starts, "Enter chose and did nothing else")
        let links = opened.count
        model.textChanged("看一下 @cla", cursor: 8)
        model.submit(go: true)
        check(opened.count == links + 1 && opened.last?.scheme == "claude" && model.draft.isEmpty, "⌘Enter goes straight there with the text")
        model.textChanged("升级 @types/node", cursor: 14)
        check(!model.pickerVisible, "no match closes the list so the literal text stays")
        model.textChanged("", cursor: 0)

        // Long text goes through the clipboard, since links are capped.
        let long = QuickInputModel(state: state, environment: environment(opened: { opened.append($0) }, copied: { copied.append($0) }))
        long.prepareForSummon()
        long.togglePicker(.agent)
        long.pick(long.rows.first { $0.client == .codexApp }!)
        let text = String(repeating: "长", count: QuickInputClient.promptLimit + 1)
        long.textChanged(text, cursor: (text as NSString).length)
        long.submit()
        check(copied.last == text && opened.last?.absoluteString.contains("prompt=") == false && long.receipt?.title == "内容已复制")

        // A client that is not on this Mac is simply not offered.
        var partial = environment()
        partial.isAvailable = { $0 == .claudeApp }
        let few = QuickInputModel(state: state, environment: partial)
        few.prepareForSummon()
        few.togglePicker(.agent)
        check(few.rows.map(\.client) == [.claudeApp])

        // A terminal that cannot start keeps everything in place.
        var stuck = false
        let cannot = QuickInputModel(state: state, environment: environment(runs: false))
        cannot.onDismiss = { stuck = true }
        cannot.prepareForSummon()
        cannot.togglePicker(.agent)
        cannot.pick(cannot.rows.first { $0.client == .codexCLI }!)
        cannot.textChanged("x", cursor: 1)
        cannot.submit()
        check(cannot.notice != nil && cannot.draft == "x" && !stuck)

        // A start that never shows up says so and points at the terminal.
        let silent = QuickInputModel(state: state, environment: environment(timeout: 0.05))
        silent.prepareForSummon()
        silent.togglePicker(.agent)
        silent.pick(silent.rows.first { $0.client == .codexCLI }!)
        silent.textChanged("x", cursor: 1)
        silent.submit()
        eventually({ silent.receipt?.tone == .warning }, "a silent start is reported")
        check(silent.receipt?.actions.contains(.activate("io.appmakes.otty")) == true)

        // A command line that is not logged in cannot start work, so Enter carries the text instead.
        var requests: [QuickInputRun.Request] = []
        let loggedOut = QuickInputModel(state: state, environment: environment(copied: { copied.append($0) }, ran: { requests.append($0) }, claudeWorks: false))
        loggedOut.prepareForSummon()
        loggedOut.togglePicker(.agent)
        loggedOut.pick(loggedOut.rows.first { $0.client == .claudeCode }!)
        loggedOut.textChanged("看看", cursor: 2)
        eventually({ !loggedOut.canSendNow }, "the check takes sending away")
        check(loggedOut.hint?.contains("未登录") == true && loggedOut.primaryVerb == "带过去" && loggedOut.secondaryVerb == nil)
        loggedOut.submit()
        check(requests == [.init(command: .new(.claudeCode), directory: "/repo/cineflow")] && copied.last == "看看", "no prompt, so no pretending to start")
    }

    static func placePicker() {
        let state = makeState()
        var data = AgentDockData()
        let running = session("00000000-0000-4000-8000-000000000001", title: "修复充值边界", cwd: "/repo/cineflow", running: true, event: .working)
        let idle = session("00000000-0000-4000-8000-000000000002", title: "有效期排查", cwd: "/repo/cineflow")
        let other = session("00000000-0000-4000-8000-000000000003", title: "订阅校验", cwd: "/repo/waw")
        data.sessions = [running, idle, other]
        state.agentDashboard = data
        var opened: [AgentDockSession] = [], links: [URL] = [], copied: [String] = []
        state.openAgentSession = { opened.append($0) }
        let model = QuickInputModel(state: state, environment: environment(opened: { links.append($0) }, copied: { copied.append($0) }))
        model.prepareForSummon()
        model.togglePicker(.agent)
        model.pick(model.rows.first { $0.client == .codexApp }!)
        check(model.pickerKind == .place && model.workspaces.map(\.name) == ["全部会话", "cineflow", "waw"] && model.placePane == .workspaces)
        check(model.focusedWorkspace == .all && model.focusedSessions.count == 3 && model.primaryVerb == "选会话" && model.secondaryVerb == nil)
        model.submit()
        check(model.placePane == .sessions && model.sessionIndex == 1 && model.pickerVisible, "Enter on all moves into the sessions")
        check(model.primaryVerb == "选中" && model.secondaryVerb == "打开")
        model.moveSelection(-1)
        check(model.sessionIndex == 1, "all has no new-session row to land on")
        model.leaveSessions()
        model.moveSelection(1)
        check(model.focusedWorkspace?.name == "cineflow" && model.focusedSessions.map(\.title) == ["修复充值边界", "有效期排查"], "the right side belongs to the focused workspace")
        model.moveSelection(1)
        check(model.focusedWorkspace?.name == "waw" && model.focusedSessions.map(\.title) == ["订阅校验"])
        model.moveSelection(5)
        check(model.focusedWorkspace?.name == "waw", "it stops at the end")
        model.moveSelection(-1)
        model.enterSessions()
        check(model.placePane == .sessions && model.sessionIndex == 1)
        model.moveSelection(1)
        check(model.sessionIndex == 2)
        model.moveSelection(-2)
        check(model.sessionIndex == 0, "the first row on the right is a new session")
        model.leaveSessions()
        model.submit()
        check(model.project?.name == "cineflow" && model.target == .client(.codexApp) && model.pickerKind == nil && links.isEmpty, "Enter on a workspace chooses it")

        // Enter on a session chooses it, settling the client and workspace together.
        model.togglePicker(.place)
        check(model.focusedWorkspace?.name == "cineflow", "the list opens on the current workspace")
        model.moveSelection(1)
        model.enterSessions()
        model.submit()
        check(model.target == .session(other.dockIdentity) && model.project?.name == "waw" && model.pickerKind == nil && opened.isEmpty)
        model.clearSessionTarget()
        check(model.target == .client(.codexApp) && model.project?.name == "waw", "stepping back keeps the client and workspace")

        // Only the current family's sessions show, under a workspace and under all. @ is the way across.
        var mixed = data
        let claudeThere = session("00000000-0000-4000-8000-000000000004", source: .claude, title: "克劳德的会话", cwd: "/repo/cineflow", kind: .claudeApp)
        mixed.sessions.append(claudeThere)
        state.agentDashboard = mixed
        model.togglePicker(.place)
        model.focusWorkspace(at: model.workspaces.firstIndex(of: QuickInputProject(path: "/repo/cineflow"))!)
        check(!model.focusedSessions.contains { $0.source == .claude } && model.sessionCount(in: QuickInputProject(path: "/repo/cineflow")) == 2, "no Claude under Codex")
        model.focusWorkspace(at: 0)
        check(!model.focusedSessions.contains { $0.id == claudeThere.id }, "all is the current family")
        model.closePicker()
        model.togglePicker(.agent)
        model.pick(model.rows.first { $0.client == .claudeApp }!)
        model.togglePicker(.place)
        model.focusWorkspace(at: model.workspaces.firstIndex(of: .all)!)
        check(model.focusedSessions.map(\.id) == [claudeThere.id], "\(model.focusedSessions.map(\.title))")
        model.enterSessions()
        while model.focusedSessions.indices.contains(model.sessionIndex - 1), model.focusedSessions[model.sessionIndex - 1].id != claudeThere.id { model.moveSelection(1) }
        model.pickSelected()
        check(model.targetClient == .claudeApp && model.project?.path == "/repo/cineflow", "choosing it makes Claude the client")
        model.togglePicker(.place)
        check(model.focusedSessions.map(\.title) == ["克劳德的会话"], "now the workspace lists Claude's")
        model.closePicker()
        model.togglePicker(.agent)
        model.pick(model.rows.first { $0.client == .codexApp }!)
        state.agentDashboard = data

        // Search: a name match stays on the workspace, a title match lands on the session.
        model.textChanged("#cine", cursor: 5)
        check(model.placePane == .workspaces && model.focusedWorkspace?.name == "cineflow" && model.focusedSessions.count == 2)
        model.textChanged("#有效", cursor: 3)
        check(model.placePane == .sessions && model.focusedSessions.map(\.title) == ["有效期排查"], "Enter must not start a new session here")

        // The fast route: `#word` ⌘Enter goes straight to it, and the token reaches neither the draft nor the link.
        model.submit(go: true)
        check(opened.map(\.id) == [idle.id] && copied.isEmpty && model.draft.isEmpty && !model.pickerVisible)
        model.textChanged("带上这句 #订阅", cursor: 8)
        model.submit(go: true)
        check(links.last?.absoluteString == "codex://threads/\(other.id)?prompt=%E5%B8%A6%E4%B8%8A%E8%BF%99%E5%8F%A5", "the thread opens with the text in it: \(String(describing: links.last))")
        check(copied.isEmpty && opened.count == 1, "filled in, so there is nothing to paste")

        // `#word` Enter chooses, then Enter sends: choosing can never send by itself.
        var sent: [(String, String)] = []
        state.sendAgentMessage = { session, text in sent.append((session.id, text)); return .accepted }
        model.textChanged("直接发 #有效", cursor: 7)
        model.submit()
        check(sent.isEmpty && model.target == .session(idle.dockIdentity) && model.draft == "直接发 " && model.primaryVerb == "发送" && model.secondaryVerb == "打开")
        model.submit()
        eventually({ sent.count == 1 }, "the second Enter sends")
        check(sent[0].0 == idle.id && sent[0].1 == "直接发")
        model.dismissReceipt()

        // A workspace from the list opens a new session there.
        model.togglePicker(.place)
        model.focusWorkspace(at: model.workspaces.firstIndex(of: QuickInputProject(path: "/repo/waw"))!)
        model.submit(go: true)
        check(links.last?.absoluteString == "codex://new?path=%2Frepo%2Fwaw" && !model.pickerVisible)

        model.textChanged("x #不存在", cursor: 6)
        check(!model.pickerVisible, "no match closes the list")
        model.textChanged("", cursor: 0)
        model.togglePicker(.place)
        model.focusWorkspace(at: 2)
        model.focusWorkspace(at: 9)
        check(model.focusedWorkspace == model.workspaces[2], "an index out of range changes nothing")
        check(model.sessionCount(in: .all) == 3)
        model.closePicker()
    }

    /// The records each agent keeps, read from a folder made for the check.
    static func localSessions() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WAWQuickInputRecords-" + UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("rollout.jsonl")
        try! #"{"type":"session_meta","payload":{"id":"x","originator":"codex-tui","cwd":"/a"}}"#.write(to: log, atomically: true, encoding: .utf8)
        check(QuickInputSessionIndex.originator(ofLog: log.path) == "codex-tui")
        let transcript = folder.appendingPathComponent("t.jsonl")
        func write(_ lines: [String]) { try! (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8) }
        func read() -> (title: String?, directory: String?) {
            QuickInputSessionIndex.claudeTranscript(transcript, size: (try! Data(contentsOf: transcript)).count, window: 4096)
        }
        let meta = #"{"type":"user","isMeta":true,"cwd":"/repo/waw","message":{"content":"提示"}}"#
        let wrapped = #"{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}"#
        let asked = #"{"type":"user","cwd":"/repo/waw","message":{"content":[{"type":"text","text":"修一下登录\n第二行"}]}}"#
        write([meta, wrapped, asked])
        check(read() == ("修一下登录", "/repo/waw"), "the first thing typed, one line of it: \(read())")
        write([meta, asked, #"{"type":"ai-title","aiTitle":"生成的标题","sessionId":"s"}"#])
        check(read().title == "生成的标题", "\(read())")
        write([meta, wrapped])
        check(read().title == nil, "nothing was asked, so it is no session to go back to")
        let padding = #"{"type":"assistant","message":{"content":"\#(String(repeating: "x", count: 9000))"}}"#
        write([asked, padding, #"{"type":"custom-title","customTitle":"起的名字","sessionId":"s"}"#])
        check(read().title == "起的名字", "a title near the end of a long transcript: \(read())")
        check(QuickInputSessionIndex.headline("  \n") == nil && QuickInputSessionIndex.headline(String(repeating: "长", count: 300))?.count == 120)
    }

    /// The Agent decides what opens a session, the session decides which conversation continues.
    static func otherClients() {
        let state = makeState()
        func record(_ id: String, source: WorkSource = .codex, title: String, cwd: String = "/repo/old", kind: Kind) -> AgentDockSession {
            var value = session(id, source: source, title: title, cwd: cwd, kind: kind)
            value = QuickInputSessionIndex.record(value.id, source, title: title, directory: cwd, at: Date(timeIntervalSince1970: 1000), url: value.navigationURL,
                                                  resume: (source == .claude ? "claude --resume " : "codex resume ") + value.id)
            return value
        }
        let oldApp = record("00000000-0000-4000-8000-000000000021", title: "旧的桌面会话", kind: .codexApp)
        let oldCLI = record("00000000-0000-4000-8000-000000000022", title: "旧的 CLI 会话", kind: .cli)
        let oldClaudeApp = record("00000000-0000-4000-8000-000000000023", source: .claude, title: "旧的 Claude 桌面会话", kind: .claudeApp)
        let oldClaudeCode = record("00000000-0000-4000-8000-000000000024", source: .claude, title: "旧的 Claude Code 会话", kind: .cli)
        let held = record("00000000-0000-4000-8000-000000000025", title: "开在桌面端的 CLI 会话", kind: .cli)
        let dock = session("00000000-0000-4000-8000-000000000026", title: "猫条里的", cwd: "/repo/waw", kind: .cli)
        let duplicate = record(dock.id, title: "同一个的旧记录", kind: .cli)
        var data = AgentDockData(); data.sessions = [dock]; state.agentDashboard = data
        var links: [URL] = [], copied: [String] = [], ran: [QuickInputRun.Request] = [], brought: [pid_t] = []
        var base = environment(opened: { links.append($0) }, copied: { copied.append($0) }, ran: { ran.append($0) })
        base.localRecords = { QuickInputLocalRecords(sessions: [oldApp, oldCLI, oldClaudeApp, oldClaudeCode, held, duplicate], workspaces: ["/repo/old"]) }
        base.liveSessions = { [held.id: 90] }
        base.bringOwnerForward = { brought.append($0); return true }
        let model = QuickInputModel(state: state, environment: base)
        model.prepareForSummon()
        eventually({ model.knownSessions.count == 6 }, "records join the dock's sessions: \(model.knownSessions.map(\.title))")
        check(model.knownSessions.first?.id == dock.id && model.knownSessions.first?.title == "猫条里的", "the dock's own first, and what it knows wins")
        check(model.projects.map(\.path).contains("/repo/old"), "a workspace only the records know")
        spin(0.05)
        func choose(_ client: QuickInputClient, then pickedSession: AgentDockSession) {
            model.togglePicker(.agent)
            model.pick(model.rows.first { $0.client == client }!)
            if model.pickerVisible { model.closePicker() }
            model.pick(session: pickedSession)
        }
        // Codex CLI takes up a desktop session: Enter resumes it with the message in the background.
        choose(.codexCLI, then: oldApp)
        model.textChanged("继续做", cursor: 3)
        check(model.targetClient == .codexCLI && model.primaryVerb == "发送" && model.secondaryVerb == "打开")
        model.submit()
        check(ran.last == .init(command: .resume(.codexCLI, id: oldApp.id), directory: "/repo/old", prompt: "继续做", background: true), "\(String(describing: ran.last))")
        model.dismissReceipt()
        // ⌘Enter opens it in a terminal, with the text waiting.
        choose(.codexCLI, then: oldApp)
        model.textChanged("等我看", cursor: 3)
        model.submit(go: true)
        check(ran.last == .init(command: .resume(.codexCLI, id: oldApp.id), directory: "/repo/old") && copied.last == "等我看")
        model.dismissReceipt()
        // Codex takes up a CLI session: the thread opens in the app with the text filled in.
        choose(.codexApp, then: oldCLI)
        model.textChanged("带过去", cursor: 3)
        check(model.targetClient == .codexApp && model.primaryVerb == "带过去" && model.secondaryVerb == nil, "an app only fills")
        let before = ran.count, clipboard = copied.count
        model.submit()
        check(links.last?.absoluteString.hasPrefix("codex://threads/\(oldCLI.id)?prompt=") == true && ran.count == before && copied.count == clipboard)
        // Claude imports a Claude Code session; the link carries no text, so the clipboard does.
        choose(.claudeApp, then: oldClaudeCode)
        model.textChanged("粘贴我", cursor: 3)
        model.submit()
        check(links.last?.absoluteString == "claude://resume?session=" + oldClaudeCode.id && copied.last == "粘贴我")
        model.dismissReceipt()
        // Claude Code takes up a desktop session.
        choose(.claudeCode, then: oldClaudeApp)
        model.submit(go: true)
        check(ran.last == .init(command: .resume(.claudeCode, id: oldClaudeApp.id), directory: "/repo/old"))
        // A session a process holds is never opened a second time: the chosen Agent gives way.
        let opens = links.count, runs = ran.count
        choose(.codexApp, then: held)
        model.submit(go: true)
        check(brought == [90] && links.count == opens && ran.count == runs, "goes to where it is")
        // Choosing another of the family keeps the session; another family drops it.
        choose(.codexApp, then: oldCLI)
        model.togglePicker(.agent)
        model.pick(model.rows.first { $0.client == .codexCLI }!)
        check(model.targetSession?.id == oldCLI.id && model.targetClient == .codexCLI)
        model.togglePicker(.agent)
        model.pick(model.rows.first { $0.client == .claudeApp }!)
        check(model.targetSession == nil && model.targetClient == .claudeApp)
        // The list follows the Agent, and search reaches the records.
        model.clearSessionTarget(); model.closePicker()
        model.togglePicker(.agent); model.pick(model.rows.first { $0.client == .codexApp }!); model.closePicker()
        model.textChanged("#旧的", cursor: 3)
        check(model.pickerVisible && model.focusedSessions.allSatisfy { $0.source == .codex } && model.focusedSessions.count == 2, "\(model.focusedSessions.map(\.title))")
        model.textChanged("#没有这个", cursor: 5)
        check(!model.pickerVisible && model.hint?.contains("没找到") == true, "\(String(describing: model.hint))")
    }

    /// DSH is on the list to get back to its sessions, so it never offers a new one.
    static func dshOnlyOpens() {
        let state = makeState()
        var dsh = session("00000000-0000-4000-8000-000000000031", source: .dsh, title: "DSH 会话", cwd: "/repo/waw", kind: .noRoute)
        dsh.localSessionLock = "/tmp/lock"
        let codex = session("00000000-0000-4000-8000-000000000032", title: "Codex 会话", cwd: "/repo/waw")
        var data = AgentDockData(); data.sessions = [dsh, codex]; state.agentDashboard = data
        var opened: [AgentDockSession] = [], ran = 0
        state.openAgentSession = { opened.append($0) }
        let model = QuickInputModel(state: state, environment: environment(ran: { _ in ran += 1 }))
        model.prepareForSummon(); spin(0.05)
        model.togglePicker(.agent)
        model.pick(model.rows.first { $0.client == .dsh }!)
        check(model.pickerKind == .place && !model.offersNewSession(in: model.focusedWorkspace), "goes on to its sessions")
        check(model.primaryVerb == "选会话" && model.secondaryVerb == nil)
        check(model.focusedSessions.map(\.id) == [dsh.id], "only its own: \(model.focusedSessions.map(\.title))")
        let waw = model.workspaces.first { $0.path == "/repo/waw" }!
        model.pick(workspace: waw)
        check(model.project == nil && ran == 0, "a workspace is no place to start one")
        model.pick(session: dsh)
        check(model.targetClient == .dsh && !model.canSendNow && model.primaryVerb == "打开")
        model.submit()
        check(opened.map(\.id) == [dsh.id] && ran == 0)
    }

    static func dshNavigationResults() {
        let state = makeState()
        var dsh = session("00000000-0000-4000-8000-000000000033", source: .dsh, title: "DSH 返回结果", event: .finished, kind: .noRoute)
        dsh.eventAt = Date(); dsh.localSessionLock = "/tmp/fixture-dsh-lock"
        var data = AgentDockData(); data.sessions = [dsh]; state.agentDashboard = data
        var calls = 0, copied: [String] = [], result = AgentSessionNavigationOutcome.openedTerminal
        state.navigateLocalAgentSession = { _ in
            try? await Task.sleep(for: .milliseconds(50))
            calls += 1
            return result
        }
        let model = QuickInputModel(state: state, environment: environment(copied: { copied.append($0) }))
        model.prepareForSummon(); spin(0.05)
        model.goBack(to: dsh)
        check(state.sessionVisitedAt[dsh.dockIdentity] == nil, "queueing navigation is not a visit")
        eventually({ calls == 1 && model.receipt != nil }, "generic terminal fallback reports its result")
        check(model.receipt?.body.contains("标签页") == true && state.sessionVisitedAt[dsh.dockIdentity] == nil)
        model.dismissReceipt()
        model.pick(session: dsh)
        model.textChanged("未发送的草稿", cursor: 6)
        result = .resumeInDefaultTerminal
        model.submit()
        eventually({ calls == 2 && model.receipt != nil }, "recovery reports after opening")
        check(copied.isEmpty && model.draft == "未发送的草稿", "keep the recovery command on the clipboard and retain the draft")
        model.dismissReceipt(); result = .unavailable
        model.submit()
        eventually({ calls == 3 && model.receipt?.tone == .warning }, "opening failure is visible")
        check(model.draft == "未发送的草稿" && state.sessionVisitedAt[dsh.dockIdentity] == nil)
        model.dismissReceipt(); result = .openedSession
        model.submit()
        eventually({ calls == 4 && state.sessionVisitedAt[dsh.dockIdentity] != nil }, "mark visited only after the precise route succeeds")
        check(copied == ["未发送的草稿"] && model.draft.isEmpty)
        model.pick(session: dsh); model.textChanged("准备跳转", cursor: 4)
        model.submit()
        model.textChanged("跳转期间的新草稿", cursor: 8)
        eventually({ calls == 5 }, "another navigation completes")
        check(model.draft == "跳转期间的新草稿", "a delayed navigation cannot erase new writing")
    }

    static func sessions() {
        let state = makeState()
        var data = AgentDockData()
        let running = session("00000000-0000-4000-8000-000000000001", running: true)
        let idle = session("00000000-0000-4000-8000-000000000002", title: "订阅校验")
        let claudeApp = session("00000000-0000-4000-8000-000000000003", source: .claude, title: "桌面端会话", kind: .claudeApp)
        let ended = session("00000000-0000-4000-8000-000000000004", title: "结束的 CLI", kind: .cli)
        let endedClaude = session("00000000-0000-4000-8000-000000000005", source: .claude, title: "结束的 Claude Code", kind: .cli)
        let liveCLI = session("00000000-0000-4000-8000-000000000006", title: "运行中的 CLI", running: true, kind: .cli)
        let idleHeld = session("00000000-0000-4000-8000-000000000007", title: "开着但空闲的 CLI", kind: .cli)
        data.sessions = [running, idle, claudeApp, ended, endedClaude, liveCLI, idleHeld]
        state.agentDashboard = data
        var opened: [AgentDockSession] = [], copied: [String] = [], links: [URL] = [], ran: [QuickInputRun.Request] = [], brought: [pid_t] = []
        var outcome = AgentMessageOutcome.steered, sent: [String] = []
        state.openAgentSession = { opened.append($0) }
        state.sendAgentMessage = { _, text in sent.append(text); return outcome }
        var base = environment(opened: { links.append($0) }, copied: { copied.append($0) }, ran: { ran.append($0) })
        base.liveSessions = { [idleHeld.id: 77, liveCLI.id: 78] }
        base.bringOwnerForward = { brought.append($0); return $0 == 77 }
        let model = QuickInputModel(state: state, environment: base)
        model.prepareForSummon()
        spin(0.1)

        // A Codex desktop thread: Enter sends. ⌘Enter goes there with the text in the composer.
        model.pick(session: idle)
        model.textChanged("补一句", cursor: 3)
        check(model.primaryVerb == "发送" && model.secondaryVerb == "打开")
        model.submit(go: true)
        check(links.last?.absoluteString.hasPrefix("codex://threads/\(idle.id)?prompt=") == true && copied.isEmpty && sent.isEmpty && opened.isEmpty && model.receipt == nil)

        // Enter into a running thread inserts it, and the receipt says what happened.
        model.pick(session: running)
        model.textChanged("补充", cursor: 2)
        check(model.primaryVerb == "发送")
        model.submit()
        eventually({ sent == ["补充"] && model.receipt?.title == "已插入当前这一步" }, "steering reports what happened")
        check(state.quickInputPulse.source == .codex && model.draft.isEmpty && model.targetSession == nil)
        model.dismissReceipt()

        // Claude's desktop app takes nothing, so Enter carries it there on the clipboard.
        model.pick(session: claudeApp)
        model.textChanged("看看", cursor: 2)
        check(model.primaryVerb == "带过去" && model.secondaryVerb == nil && !model.canSendNow)
        model.submit()
        check(opened.last?.id == claudeApp.id && copied.last == "看看" && model.receipt?.title == "内容已复制")
        model.dismissReceipt()
        model.pick(session: claudeApp)
        check(model.primaryVerb == "打开")
        model.submit()
        check(opened.count == 2 && copied.count == 1 && model.receipt == nil, "nothing typed is a plain jump")

        // An ended terminal session: Enter resumes it with the message, in the background.
        model.pick(session: endedClaude)
        model.textChanged("接着做", cursor: 3)
        check(model.primaryVerb == "发送" && model.secondaryVerb == "打开")
        model.submit()
        check(ran.last == .init(command: .resume(.claudeCode, id: endedClaude.id), directory: "/repo/cineflow", prompt: "接着做", background: true))
        check(model.receipt?.title.contains("正在启动") == true)
        var revived = data
        revived.sessions = data.sessions.map { $0.id == endedClaude.id ? session(endedClaude.id, source: .claude, title: "结束的 Claude Code", running: true, event: .working, kind: .cli) : $0 }
        state.agentDashboard = revived
        check(model.receipt?.title == "交给 Claude Code 了", "coming back to life is the proof: \(model.receipt?.title ?? "")")
        state.agentDashboard = data
        model.dismissReceipt()

        // ⌘Enter resumes it in front instead, with the text on the clipboard.
        model.pick(session: ended)
        model.textChanged("带上", cursor: 2)
        model.submit(go: true)
        check(ran.last == .init(command: .resume(.codexCLI, id: ended.id), directory: "/repo/cineflow") && copied.last == "带上")
        model.dismissReceipt()

        // Still held by a process, even idle: never resumed. Enter brings its terminal forward, whichever that is.
        let runs = ran.count
        model.pick(session: idleHeld)
        model.textChanged("先放着", cursor: 3)
        check(model.primaryVerb == "带过去" && !model.canSendNow, "two processes must not share a session")
        model.submit()
        check(ran.count == runs && brought == [77] && copied.last == "先放着" && model.receipt?.title == "内容已复制")
        model.dismissReceipt()

        // Running with no way to reach it is the one dead end, and it is said plainly.
        model.pick(session: liveCLI)
        model.textChanged("留着", cursor: 2)
        model.submit()
        check(ran.count == runs && copied.last == "留着" && model.receipt?.title == "回到它所在的窗口")
        model.dismissReceipt()

        // An uncertain result keeps the text, warns, and never resends.
        model.pick(session: idle)
        outcome = .uncertain
        model.textChanged("继续", cursor: 2)
        model.submit()
        eventually({ model.receipt?.tone == .warning }, "uncertain reaches a receipt")
        check(sent.count == 2 && model.warning != nil && model.receipt?.lingers == true && model.receipt?.actions.contains(.dismiss) == true)
        model.perform(.restore("继续"))
        check(model.draft == "继续" && model.receipt == nil && model.target == .session(idle.dockIdentity))

        // A refused message comes back too, and the dock shakes rather than bumps.
        outcome = .unavailable
        model.submit()
        eventually({ model.receipt?.tone == .failure }, "failure reaches a receipt")
        check(state.quickInputPulse.rejections == 1)
        model.perform(.dismiss)
        check(model.receipt == nil, "every lingering receipt can be closed")

        // A pending request makes a session wait, even when its own record has not caught up.
        model.pick(session: running)
        model.textChanged("等等", cursor: 2)
        check(model.canSendNow)
        state.agentInteractions = [.init(request: PermissionRequest(id: "r", source: .codex, sessionID: running.id, toolName: "Bash", summary: "ls", detail: nil, cwd: "/repo/cineflow", at: Date()))]
        check(!model.canSendNow && model.primaryVerb == "带过去" && model.targetSession?.event == .approval, "a request is never talked over")
        state.agentInteractions = []

        // A session that disappears is explained, and nothing is lost.
        model.textChanged("还在", cursor: 2)
        state.agentDashboard = AgentDockData()
        model.submit()
        check(model.notice?.contains("不在列表") == true && model.draft == "还在" && model.target == nil)
    }

    private static func finished(_ id: String, source: WorkSource = .codex, title: String, cwd: String? = "/repo/cineflow", at: Date = Date(), kind: Kind = .codexApp) -> AgentDockSession {
        var done = session(id, source: source, title: title, cwd: cwd, event: .finished, kind: kind)
        done.eventAt = at
        return done
    }

    /// What the list holds, how it leaves, and that it stays out of the way of writing.
    static func returnList() {
        let state = makeState()
        let now = Date()
        let question = session("00000000-0000-4000-8000-000000000041", title: "清理迁移脚本", event: .input)
        let approval = session("00000000-0000-4000-8000-000000000042", source: .claude, title: "分镜批量重做", cwd: "/repo/waw", event: .approval, kind: .claudeApp)
        let recent = finished("00000000-0000-4000-8000-000000000043", title: "修复充值边界", at: now.addingTimeInterval(-120))
        let older = finished("00000000-0000-4000-8000-000000000044", source: .hermes, title: "整理发版说明", at: now.addingTimeInterval(-7200), kind: .cli)
        let stale = finished("00000000-0000-4000-8000-000000000045", title: "昨天的事", at: now.addingTimeInterval(-25 * 3600))
        var child = finished("00000000-0000-4000-8000-000000000046", title: "子任务", at: now)
        child.parentSessionID = recent.id
        let unreachable = finished("00000000-0000-4000-8000-000000000047", title: "没有去路", at: now, kind: .noRoute)
        let running = session("00000000-0000-4000-8000-000000000048", title: "还在跑", running: true, event: .working)
        var data = AgentDockData()
        data.sessions = [older, recent, stale, child, unreachable, running, approval, question]
        state.agentDashboard = data

        let model = QuickInputModel(state: state, environment: environment())
        model.prepareForSummon(); spin(0.05)
        check(model.returnListVisible && model.returnRows.map(\.kind) == [.waiting, .waiting, .finished, .finished], "waiting above finished: \(model.returnRows.map(\.session.title))")
        check(model.returnRows.prefix(2).map(\.label).compactMap { $0 }.sorted() == ["待回答", "待审批"])
        check(model.returnRows.suffix(2).map(\.session.title) == ["修复充值边界", "整理发版说明"], "newest finished first, and nothing stale, nested, unreachable or running")
        check(model.returnRows[2].age(now: now) == "2 分钟前" && model.returnRows[3].age(now: now) == "2 小时前")
        check(model.returnRows[0].age(now: model.returnRows[0].at.addingTimeInterval(240)) == "4 分钟", "waiting says how long, not how long ago")
        check(QuickInputCatalog.status(recent).text == "刚完成" && QuickInputCatalog.status(stale).text == "空闲", "the # list says it the same way")

        // Enter reads the row, not the sentence.
        check(model.selectedReturn?.kind == .waiting && model.primaryVerb == "去处理" && model.secondaryVerb == nil)
        model.moveReturn(5)
        check(model.selectedReturn?.session.id == older.id && model.primaryVerb == "回到会话", "it stops at the end")
        model.moveReturn(-1)
        check(model.selectedReturn?.session.id == recent.id)

        // Writing takes over, and nothing about it changed.
        model.textChanged("开", cursor: 1)
        check(!model.returnListVisible && model.primaryVerb != "回到会话", "the first character closes the list")
        model.textChanged("", cursor: 0)
        check(model.returnListVisible && model.selectedReturn?.session.id == recent.id, "and it is back, where it was")
        model.textChanged("#", cursor: 1)
        check(model.pickerKind == .place && !model.returnListVisible, "# works as ever")
        model.textChanged("", cursor: 0)

        // Removing moves on to the next row, and a new completion brings the session back.
        model.removeSelectedReturn()
        check(!model.returnRows.contains { $0.session.id == recent.id } && model.selectedReturn?.session.id == older.id, "⌘⌫ moves on")
        var again = data
        again.sessions = again.sessions.map { $0.id == recent.id ? finished(recent.id, title: recent.title, at: Date().addingTimeInterval(1)) : $0 }
        state.agentDashboard = again
        check(model.returnRows.contains { $0.session.id == recent.id }, "finishing again is news again")
        state.agentDashboard = data

        // A waiting row can be removed too, until it asks something new.
        let waitingTitle = model.returnRows[0].session.title
        model.moveReturn(-5); model.removeSelectedReturn()
        check(!model.returnRows.contains { $0.session.title == waitingTitle }, "removing a waiting row holds")

        // Tab writes to it: the sentence names the session, and writing to a waiting one only carries it there.
        let writing = QuickInputModel(state: state, environment: environment())
        writing.prepareForSummon(); spin(0.05)
        let chosen = writing.selectedReturn!.session
        writing.continueWithSelectedReturn()
        check(writing.targetSession?.id == chosen.id && !writing.returnListVisible, "Tab chooses it")
        writing.textChanged("补一句", cursor: 3)
        check(writing.primaryVerb == "带过去" && !writing.canSendNow, "a waiting session is not talked over")
        writing.textChanged("", cursor: 0)
        writing.prepareForSummon()
        check(writing.target == nil || { if case .session = writing.target { return false } else { return true } }(), "nothing written, so the list comes back on the next summon")

        // Capacity, and relaunch keeps what was visited.
        let capped = makeState()
        var many = AgentDockData()
        many.sessions = (0..<5).map { session(String(format: "00000000-0000-4000-8000-0000000001%02d", $0), title: "等 \($0)", event: .approval) }
            + (0..<6).map { finished(String(format: "00000000-0000-4000-8000-0000000002%02d", $0), title: "完成 \($0)", at: now.addingTimeInterval(-Double($0) * 60)) }
        capped.agentDashboard = many
        let full = QuickInputModel(state: capped, environment: environment())
        full.prepareForSummon(); spin(0.05)
        check(full.returnRows.filter { $0.kind == .waiting }.count == 3 && full.returnRows.count == 6 && full.returnMore == 5, "3 waiting, 6 in all, the rest counted")
        let suite = "WhileAIWorks.QuickInputChecks." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        let first = AppState(defaults: defaults)
        first.dismissSessionReturn(recent)
        check(AppState(defaults: defaults).sessionVisitedAt[recent.dockIdentity] != nil, "visits survive relaunch")

        // The paw: another session running no longer hides it, a look settles it but not the list, going settles the session.
        // A first run counts everything earlier as seen, so these finish after it.
        let paws = makeState()
        let soon = Date().addingTimeInterval(5)
        let done = finished("00000000-0000-4000-8000-000000000050", title: "刚刚完成", at: soon)
        var both = AgentDockData()
        both.sessions = [done, running]
        paws.agentDashboard = both
        paws.activeSessionCounts[.codex] = 1
        check(paws.unseenCompletion(for: .codex) == soon, "a completion shows while another session of the client runs")
        paws.markCompletionSeen([.codex], at: soon.addingTimeInterval(1))
        check(paws.unseenCompletion(for: .codex, now: soon.addingTimeInterval(2)) == nil, "a look at the card settles the paw")
        let pawModel = QuickInputModel(state: paws, environment: environment())
        pawModel.prepareForSummon(); spin(0.05)
        check(pawModel.returnRows.map(\.session.id) == [done.id], "but the list still has it")
        let paws2 = makeState()
        let other = finished("00000000-0000-4000-8000-000000000049", title: "另一个", at: soon.addingTimeInterval(-1))
        var two = AgentDockData(); two.sessions = [done, other]
        paws2.agentDashboard = two
        paws2.markSessionVisited(done, at: soon.addingTimeInterval(1))
        check(paws2.unseenCompletion(for: .codex) == other.eventAt, "going to one leaves the other's paw")
        paws2.markSessionVisited(other, at: soon.addingTimeInterval(1))
        check(paws2.unseenCompletion(for: .codex) == nil, "going to both clears it")
        let request = makeState()
        request.agentDashboard = data
        request.markSessionVisited(question)
        check(request.sessionVisitedAt.isEmpty, "going to a waiting session settles nothing; dealing with it does")
    }

    /// Back with the session's own client, whatever is chosen for writing, and never over a live process.
    static func returnRoutes() {
        let state = makeState()
        let now = Date()
        let desktop = finished("00000000-0000-4000-8000-000000000051", title: "桌面线程", at: now)
        let ended = finished("00000000-0000-4000-8000-000000000052", title: "结束的 CLI", cwd: "/repo/waw", at: now.addingTimeInterval(-60), kind: .cli)
        let held = finished("00000000-0000-4000-8000-000000000053", title: "还开着的 CLI", cwd: "/repo/waw", at: now.addingTimeInterval(-120), kind: .cli)
        var data = AgentDockData(); data.sessions = [desktop, ended, held]
        state.agentDashboard = data
        var opened: [AgentDockSession] = [], ran: [QuickInputRun.Request] = [], brought: [pid_t] = [], copied: [String] = []
        state.openAgentSession = { opened.append($0) }
        var base = environment(copied: { copied.append($0) }, ran: { ran.append($0) })
        base.liveSessions = { [held.id: 77] }
        base.bringOwnerForward = { brought.append($0); return true }
        let model = QuickInputModel(state: state, environment: base)
        var dismissed = 0
        model.onDismiss = { dismissed += 1 }
        model.prepareForSummon(); spin(0.05)
        model.togglePicker(.agent)
        model.pick(model.rows.first { $0.client == .claudeCode }!)
        model.closePicker()
        check(model.targetClient == .claudeCode && model.returnListVisible, "writing is set up for another Agent")

        check(model.selectedReturn?.session.id == desktop.id)
        model.submit()
        check(dismissed == 1, "the panel leaves at once")
        eventually({ opened.map(\.id) == [desktop.id] }, "its own route")
        eventually({ state.sessionVisitedAt[desktop.dockIdentity] != nil }, "gone to")
        check(!model.returnRows.contains { $0.session.id == desktop.id }, "and off the list")

        model.submit()
        eventually({ ran.count == 1 }, "an ended session resumes")
        check(ran[0].directory == "/repo/waw" && !ran[0].background, "in front, where it worked")
        if case .resume(let client, let id) = ran[0].command { check(client == .codexCLI && id == ended.id, "with its own client, not the chosen one") } else { check(false, "resume") }

        model.submit()
        eventually({ brought == [77] }, "one a process holds is brought forward")
        check(ran.count == 1, "and never resumed a second time")
        check(copied.isEmpty && model.receipt == nil && model.returnRows.isEmpty)
        check(model.targetClient == .claudeCode, "and nothing about what was being written changed")

        // From the dock: same route, and a draft being written stays.
        let dock = makeState()
        var dockData = AgentDockData()
        let cli = finished("00000000-0000-4000-8000-000000000054", title: "猫条里的 CLI", cwd: "/repo/waw", at: now, kind: .cli)
        dockData.sessions = [cli]
        dock.agentDashboard = dockData
        var dockRuns: [QuickInputRun.Request] = [], dockCopied: [String] = []
        var dockOpened = 0
        dock.openAgentSession = { _ in dockOpened += 1 }
        let dockModel = QuickInputModel(state: dock, environment: environment(copied: { dockCopied.append($0) }, ran: { dockRuns.append($0) }))
        dockModel.prepareForSummon(); spin(0.05)
        dockModel.textChanged("没写完", cursor: 3)
        dock.goToAgentSession(cli)
        eventually({ dockRuns.count == 1 }, "the dock no longer only copies a command")
        check(dockCopied.isEmpty && dockOpened == 0 && dockModel.draft == "没写完", "the draft stays")
        eventually({ dock.sessionVisitedAt[cli.dockIdentity] != nil }, "gone to from the dock counts")

        // Waiting, and nowhere to go: the card can answer it, and the row stays.
        let lost = makeState()
        var lostData = AgentDockData()
        let stuck = session("00000000-0000-4000-8000-000000000055", source: .claude, title: "无处可去", running: true, event: .approval, kind: .noRoute)
        lostData.sessions = [stuck]
        lost.agentDashboard = lostData
        var cards: [WorkSource] = []
        lost.showDockCard = { cards.append($0) }
        let lostModel = QuickInputModel(state: lost, environment: environment())
        lostModel.prepareForSummon(); spin(0.05)
        check(lostModel.selectedReturn?.session.id == stuck.id && lostModel.primaryVerb == "去处理")
        lostModel.submit()
        eventually({ cards == [.claude] }, "the dock's card opens")
        check(lostModel.receipt?.title == "回到它所在的窗口" && lostModel.receipt?.body.contains("猫条卡片") == true)
        check(lostModel.returnRows.map(\.session.id) == [stuck.id], "a waiting row leaves when it is dealt with, not when visited")
        // Dealt with: the request is gone, so is the row.
        lostData.sessions = [session(stuck.id, source: .claude, title: stuck.title, running: true, event: .working, kind: .noRoute)]
        lost.agentDashboard = lostData
        check(lostModel.returnRows.isEmpty && !lostModel.returnListVisible)
    }

    /// The list with real keys in the real panel, and the size it opens at.
    static func returnKeyboard() {
        let state = makeState()
        let now = Date()
        let waiting = session("00000000-0000-4000-8000-000000000061", title: "等你", event: .approval)
        let one = finished("00000000-0000-4000-8000-000000000062", title: "第一个", at: now)
        let two = finished("00000000-0000-4000-8000-000000000063", title: "第二个", at: now.addingTimeInterval(-60))
        var data = AgentDockData(); data.sessions = [waiting, one, two]
        state.agentDashboard = data
        var opened: [AgentDockSession] = []
        state.openAgentSession = { opened.append($0) }
        let controller = QuickInputController(state: state, environment: environment(), tileCenter: { _ in nil }, dockFrame: { nil })
        let model = controller.model, panel = controller.panel
        controller.show()
        check(abs(panel.frame.height - QuickInputView.height(showing: model.returnRows, more: 0)) < 1, "it opens at its final size: \(panel.frame.height)")
        spin(0.4)
        check(abs(panel.frame.height - QuickInputView.height(showing: model.returnRows, more: 0)) < 1, "and stays there, so nothing jumps: \(panel.frame.height) for \(QuickInputView.height(showing: model.returnRows, more: 0))")
        let opening = panel.frame
        guard let text = textView(in: panel.contentView) else { check(false, "the editor exists"); return }
        panel.makeKey(); panel.makeFirstResponder(text); spin(0.1)

        check(model.selectedReturn?.session.id == waiting.id, "the first row is ready")
        key(125, "", to: panel)
        check(model.selectedReturn?.session.id == one.id, "down")
        key(126, "", to: panel); key(125, "", to: panel)
        key(51, "\u{7f}", [.command], to: panel)
        check(!model.returnRows.contains { $0.session.id == one.id } && model.selectedReturn?.session.id == two.id, "⌘⌫ removes and moves on")
        key(51, "\u{7f}", to: panel)
        check(model.returnRows.contains { $0.session.id == two.id }, "plain delete does nothing to the list")
        spin(0.3)
        check(abs(panel.frame.maxY - opening.maxY) < 1 && panel.frame.height < opening.height, "the panel closes up from below")

        // Writing closes it, deleting brings it back, and the top edge never moves.
        text.insertText("写", replacementRange: text.selectedRange()); spin(0.35)
        check(!model.returnListVisible && panel.frame.height < 150 && abs(panel.frame.maxY - opening.maxY) < 1, "writing closes the list: \(panel.frame.height)")
        let plain = panel.frame.height
        text.string = ""; model.textChanged("", cursor: 0); spin(0.35)
        check(model.returnListVisible && panel.frame.height > plain)

        // Tab chooses, delete lets go.
        key(48, "\t", to: panel)
        check(model.targetSession?.id == two.id && model.pickerKind == nil && !model.returnListVisible, "Tab writes to it and opens no list")
        key(51, "\u{7f}", to: panel)
        check(model.targetSession == nil && model.returnListVisible, "delete with nothing written lets go of it")

        // Marked text goes to the input method first. It never reaches the draft, but it is already writing.
        let listed = panel.frame.height
        text.setMarkedText("jian", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        check(model.draft.isEmpty && model.composing && !model.returnListVisible, "composing closes the list")
        spin(0.35)
        check(panel.frame.height < listed && abs(panel.frame.maxY - opening.maxY) < 1, "and the panel closes up: \(panel.frame.height)")
        key(36, "\r", to: panel)
        check(opened.isEmpty && controller.isShown, "Return while composing never goes anywhere")
        // With no input method here to take it, the Return went into the text. Start over.
        text.unmarkText(); text.string = ""; model.textChanged("", cursor: 0)
        check(!model.composing && model.returnListVisible)
        text.setMarkedText("jian", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        check(model.composing)
        text.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        check(!model.composing && model.returnListVisible, "cancelling the candidate brings the list back")
        text.setMarkedText("jian", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        text.insertText("见", replacementRange: text.markedRange())
        check(!model.composing && model.draft == "见" && !model.returnListVisible, "committing it writes it")
        text.string = ""; model.textChanged("", cursor: 0)

        // Esc closes in one press; the next summon starts on the first row at the right size.
        key(125, "", to: panel)
        key(53, "\u{1b}", to: panel); spin(0.3)
        check(!controller.isShown, "Esc closes at once: the list was not asked for")
        controller.show()
        check(model.selectedReturn?.session.id == waiting.id, "back on the first row")
        spin(0.3); panel.makeKey(); panel.makeFirstResponder(text); spin(0.05)
        key(125, "", to: panel)
        key(36, "\r", to: panel)
        spin(0.3)
        check(!controller.isShown, "Return leaves")
        eventually({ opened.map(\.id) == [two.id] }, "and goes to the highlighted row")
        withExtendedLifetime(controller) {}

        // With nothing to come back to the panel is what it always was.
        let empty = makeState()
        let plainController = QuickInputController(state: empty, environment: environment(), tileCenter: { _ in nil }, dockFrame: { nil })
        plainController.show(); spin(0.4)
        check(!plainController.model.returnListVisible && plainController.panel.frame.height < 150, "unchanged: \(plainController.panel.frame.height)")
        let settled = plainController.panel.frame.height
        plainController.dismiss(); spin(0.3)
        plainController.show()
        check(abs(plainController.panel.frame.height - settled) < 1, "and it reopens at that size: \(plainController.panel.frame.height) for \(settled)")
        plainController.dismiss(); spin(0.2)
        withExtendedLifetime(plainController) {}
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
    /// makes Chinese input safe: Return must commit the candidate, not act.
    static func keyboard() throws {
        let state = makeState()
        var data = AgentDockData()
        data.sessions = [session("00000000-0000-4000-8000-000000000001", cwd: "/repo/cineflow"), session("00000000-0000-4000-8000-000000000002", title: "另一个", cwd: "/repo/cineflow")]
        state.agentDashboard = data
        var ran: [QuickInputRun.Request] = [], opened: [URL] = []
        let controller = QuickInputController(state: state, environment: environment(opened: { opened.append($0) }, ran: { ran.append($0) }), tileCenter: { _ in nil }, dockFrame: { nil })
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
        check(opened.isEmpty && ran.isEmpty && controller.isShown, "Return while composing never acts")
        text.unmarkText(); text.string = ""; controller.model.textChanged("", cursor: 0)

        text.insertText("第一行", replacementRange: text.selectedRange())
        check(controller.model.draft == "第一行")
        key(36, "\r", [.shift], to: panel)
        check(text.string == "第一行\n" && controller.model.draft == "第一行\n", "Shift-Return is a newline, got \(text.string.debugDescription)")
        text.insertText("第二行", replacementRange: text.selectedRange())
        spin(0.4)
        check(panel.frame.height > compact.height + 10, "the panel grows with its text: \(panel.frame.height) from \(compact.height)")
        check(abs(panel.frame.maxY - compact.maxY) < 1, "the top edge stays put")

        key(36, "\r", to: panel)
        check(controller.model.pickerKind == .agent && controller.isShown && opened.isEmpty, "Return opens what is missing")
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
        check(controller.model.target == .client(.codexApp) && controller.model.pickerKind == .place && opened.isEmpty, "Return chooses, then where")
        spin(0.35)
        check(panel.frame.height > 280, "both columns fit: \(panel.frame.height)")
        check(controller.model.focusedWorkspace == .all, "nothing chosen yet, so the list starts on all sessions")
        key(124, "", to: panel)
        check(controller.model.placePane == .sessions && controller.model.sessionIndex == 1, "right arrow enters the sessions")
        key(123, "", to: panel)
        check(controller.model.placePane == .workspaces, "left arrow returns")
        key(125, "", to: panel)
        key(36, "\r", to: panel)
        check(controller.model.project?.name == "cineflow" && controller.model.pickerKind == nil && opened.isEmpty, "Return chose without going anywhere")
        spin(0.35)
        check(panel.frame.height < 200, "the panel closes back up: \(panel.frame.height)")

        key(53, "\u{1b}", to: panel)
        spin(0.3)
        check(!controller.isShown && controller.model.draft == "第一行\n第二行", "Escape hides the panel and keeps the draft")
        state.quickInputSummon.send()
        eventually({ controller.isShown }, "it comes back")
        spin(0.2)
        check(textView(in: panel.contentView)?.string == "第一行\n第二行", "the draft is still in the editor")

        // Codex's app cannot start work: Return carries it there, and ⌘Return offers nothing more.
        panel.makeKey(); panel.makeFirstResponder(text); spin(0.05)
        key(36, "\r", [.command], to: panel)
        check(opened.count == 1 && opened[0].scheme == "codex" && ran.isEmpty, "⌘Return follows it there")
        spin(0.3)
        check(!controller.isShown)
        state.quickInputSummon.send()
        eventually({ controller.isShown }, "it comes back")
        spin(0.2)
        panel.makeKey(); panel.makeFirstResponder(text); spin(0.05)
        controller.model.togglePicker(.agent)
        controller.model.pick(controller.model.rows.first { $0.client == .codexCLI }!)
        text.insertText("开工", replacementRange: text.selectedRange())
        key(36, "\r", to: panel)
        check(ran.count == 1 && ran[0].prompt == "开工" && ran[0].directory == "/repo/cineflow" && ran[0].background, "Return sends it from a command line")
        spin(0.3)
        check(!controller.isShown && !panel.isVisible, "the panel leaves at once")
        controller.model.dismissReceipt()

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
        let bundle = Bundle(path: "dist/While AI Works.app")!
        state.desktopEnabled = false; state.desktopPetEnabled = true; state.desktopPetPresentation = .dock
        let dockController = DesktopDockController(state: state, mascot: MascotController(bundle: bundle), cardMascot: MascotController(bundle: bundle))
        dockController.refresh(); spin(0.5)
        guard let center = dockController.tileCenter(for: .codex), let frame = dockController.visibleDockFrame else { check(false, "the dock is on screen"); return }
        check(frame.contains(center), "the tile is inside the dock")
        check(dockController.tileCenter(for: .workbuddy) == nil, "an unwatched source has no tile")
        let controller = QuickInputController(state: state, environment: environment(), tileCenter: { dockController.tileCenter(for: $0) }, dockFrame: { dockController.visibleDockFrame })
        controller.show(); spin(0.3)
        controller.model.pick(session: running)
        textView(in: controller.panel.contentView)?.insertText("补充", replacementRange: NSRange(location: 0, length: 0))
        let landings = state.quickInputPulse.landings
        // The panel opens on the pointer's screen. With the dock on another one the note simply arrives.
        let flies = NSScreen.screens.contains { $0.frame.contains(CGPoint(x: controller.panel.frame.midX, y: controller.panel.frame.midY)) && $0.frame.contains(center) }
        controller.model.submit()
        spin(0.2)
        check(!flies || state.quickInputPulse.landings == landings, "the tile reacts when the note arrives, not when it leaves")
        eventually({ state.quickInputPulse.landings == landings + 1 }, "the flight finishes")
        eventually({ controller.model.receipt?.title == "已插入当前这一步" }, "the receipt reports the result")
        spin(0.4)
        let receipt = controller.receiptPanel.frame
        check(controller.receiptPanel.isVisible && controller.receiptPanel.alphaValue > 0.9, "the receipt shows")
        check(receipt.height > 40, "the receipt has its size: \(receipt)")
        check(receipt.maxX <= frame.minX && receipt.maxX >= frame.minX - 40, "the receipt sits beside a right-edge dock: \(receipt) \(frame)")
        check(!controller.isShown && !controller.panel.isVisible, "the panel has left")
        controller.model.dismissReceipt(); spin(0.3)
        withExtendedLifetime(controller) {}
        withExtendedLifetime(dockController) {}
    }

    /// Asks the views to draw, which needs no Screen Recording, so it has no glass; the layout is what it shows.
    private static func drawn(_ window: NSWindow, dark: Bool, to url: URL) {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        (dark ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
        view.bounds.fill()
        rep.draw(in: view.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        image.unlockFocus()
        if let tiff = image.tiffRepresentation { try? NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])?.write(to: url) }
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
            let running = session("00000000-0000-4000-8000-000000000001", running: true, event: .working)
            data.sessions = [running, session("00000000-0000-4000-8000-000000000005", title: "充值有效期排查"),
                             session("00000000-0000-4000-8000-000000000006", source: .claude, title: "分镜批量重做", kind: .claudeApp),
                             session("00000000-0000-4000-8000-000000000002", title: "订阅校验重试", cwd: "/repo/while-ai-works", kind: .cli),
                             session("00000000-0000-4000-8000-000000000003", source: .claude, title: "修复会话跳转入口", cwd: "/repo/while-ai-works", event: .approval, kind: .cli),
                             finished("00000000-0000-4000-8000-000000000007", title: "快捷输入玻璃材质", cwd: "/repo/while-ai-works", at: Date().addingTimeInterval(-120)),
                             finished("00000000-0000-4000-8000-000000000008", source: .hermes, title: "整理发版说明", cwd: "/repo/while-ai-works", at: Date().addingTimeInterval(-660), kind: .cli)]
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
            capture("return", controller.panel)
            drawn(controller.panel, dark: dark, to: directory.appendingPathComponent("quick-input-\(name)-return-drawn.png"))
            editor?.setMarkedText("shi'de", selectedRange: NSRange(location: 6, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            spin(0.4)
            drawn(controller.panel, dark: dark, to: directory.appendingPathComponent("quick-input-\(name)-composing-drawn.png"))
            editor?.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            editor?.unmarkText()
            editor?.insertText("检查一下充值有效期的处理，重点看边界情况", replacementRange: editor?.selectedRange() ?? NSRange())
            capture("first", controller.panel)
            model.togglePicker(.agent)
            capture("agent", controller.panel)
            model.pick(model.rows.first { $0.client == .codexCLI }!)
            capture("place", controller.panel)
            model.moveSelection(1)
            capture("workspace", controller.panel)
            model.enterSessions()
            capture("sessions", controller.panel)
            model.leaveSessions()
            model.pickSelected()
            capture("cli", controller.panel)
            model.togglePicker(.agent)
            model.pick(model.rows.first { $0.client == .codexApp }!)
            capture("app", controller.panel)
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
