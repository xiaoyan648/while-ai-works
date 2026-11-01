import AppKit
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
                     event: AgentSessionEvent = .recent, sendable: Bool = true) -> AgentDockSession {
    let uuid = UUID(uuidString: id) ?? UUID()
    let identifier = uuid.uuidString.lowercased()
    return AgentDockSession(id: identifier, source: source, title: title, project: cwd.map { URL(fileURLWithPath: $0).lastPathComponent }, status: running ? "工作中" : "最近会话",
                            running: running, tokensIn: 0, tokensOut: 0, cacheRead: 0, reply: nil, observedAt: Date(),
                            navigationURL: sendable ? URL(string: "codex://threads/" + identifier) : nil, resumeCommand: nil,
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
        tokens()
        handoffLinks()
        catalog()
        modelFlows()
        queueFlows()
        try keyboard()
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count { snapshots(URL(fileURLWithPath: arguments[index + 1], isDirectory: true)) }
        print("Quick input checks passed")
    }

    private static func makeState() -> AppState {
        let suite = "WhileAIWorks.QuickInputChecks." + UUID().uuidString
        let state = AppState(defaults: UserDefaults(suiteName: suite)!)
        state.soundEnabled = false; state.selectedSources = [.codex, .claude, .dsh]
        return state
    }
    private static func environment(opened: ((URL) -> Void)? = nil, handler: Bool = true, copied: ((String) -> Void)? = nil) -> QuickInputEnvironment {
        QuickInputEnvironment(open: { opened?($0); return true }, canOpen: { _ in handler }, copy: { copied?($0) }, directoryExists: { _ in true }, chooseDirectory: { nil })
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

    static func handoffLinks() {
        let codex = QuickInputHandoff.url(source: .codex, path: "/repo/云 流", prompt: "a+b & c=d\n第二行")!.absoluteString
        check(codex.hasPrefix("codex://new?path=%2Frepo%2F"))
        check(codex.contains("prompt=a%2Bb%20%26%20c%3Dd%0A"), "plus and ampersand must survive: \(codex)")
        check(codex.contains("path=") && !codex.contains(" "))
        let claude = QuickInputHandoff.url(source: .claude, path: "/repo/x", prompt: "看一下")!.absoluteString
        check(claude.hasPrefix("claude-cli://open?cwd=%2Frepo%2Fx&q=%E7%9C%8B"))
        check(QuickInputHandoff.url(source: .claude, path: "/repo/x", prompt: nil)!.absoluteString == "claude-cli://open?cwd=%2Frepo%2Fx")
        check(QuickInputHandoff.url(source: .dsh, path: "/repo", prompt: "x") == nil)
    }

    static func catalog() {
        var data = AgentDockData()
        data.sessions = [session("00000000-0000-4000-8000-000000000001", running: true),
                         session("00000000-0000-4000-8000-000000000002", title: "等待", cwd: "/repo/waw", event: .approval),
                         session("00000000-0000-4000-8000-000000000003", source: .claude, title: "终端会话", cwd: "/repo/waw", sendable: false)]
        let rows = QuickInputCatalog.targetRows(data: data, sources: [.codex, .claude, .dsh], quota: { _ in nil }, query: "")
        check(rows.first?.section == "开新任务" && rows.first { $0.section == "继续会话" } != nil)
        check(rows.first { $0.kind == .agent(.dsh) }?.enabled == false, "unsupported agents stay visible but disabled")
        let running = rows.first { $0.title == "修复充值边界" }, waiting = rows.first { $0.title == "等待" }, claude = rows.first { $0.title == "终端会话" }
        check(running?.enabled == true && running?.tone == .working && running?.trailing == "运行中")
        check(waiting?.enabled == false && waiting?.tone == .attention, "a session waiting for the user takes no message")
        check(claude?.enabled == false && claude?.subtitle.contains("只能回原客户端") == true, "only sendable sessions are offered")
        let filtered = QuickInputCatalog.targetRows(data: data, sources: [.codex, .claude], quota: { _ in nil }, query: "claude")
        check(filtered.first?.kind == .agent(.claude))
        let projects = QuickInputCatalog.projects(sessions: data.sessions, recents: ["/repo/old", "/repo/waw"], exists: { $0 != "/repo/old" })
        check(projects.map(\.path) == ["/repo/waw", "/repo/cineflow"], "recents first, unique, and only existing directories")
        check(QuickInputCatalog.projects(sessions: [session("x", cwd: "/a/app"), session("y", cwd: "/b/app")], recents: [], exists: { _ in true }).count == 2, "worktrees with one name stay apart")
    }

    static func modelFlows() {
        let state = makeState()
        var opened: [URL] = []
        let model = QuickInputModel(state: state, environment: environment(opened: { opened.append($0) }))
        var dismissals = 0
        model.onDismiss = { dismissals += 1 }
        var data = AgentDockData()
        data.sessions = [session("00000000-0000-4000-8000-000000000001", running: true)]
        state.agentDashboard = data
        model.prepareForSummon()
        check(model.target == nil && model.project == nil && model.primaryVerb == "下一步", "nothing is chosen for a first-time user")

        // Enter walks through what is missing and never loses the text or sends to a guess.
        model.textChanged("检查一下", cursor: 4)
        model.submit()
        check(model.pickerKind == .target && model.pickerNote != nil && model.draft == "检查一下" && opened.isEmpty)
        model.pick(model.rows.first { $0.kind == .agent(.dsh) }!)
        check(model.target == nil && model.pickerNote?.contains("暂时不能") == true, "a disabled agent is explained, not chosen")
        model.pick(model.rows.first { $0.kind == .agent(.codex) }!)
        check(model.target == .agent(.codex) && model.pickerKind == .project)
        model.pick(model.rows.first { $0.title == "cineflow" }!)
        check(model.project?.path == "/repo/cineflow" && model.pickerKind == nil && model.primaryVerb == "带到 Codex" && opened.isEmpty)
        model.submit()
        check(opened.count == 1 && opened[0].absoluteString.hasPrefix("codex://new?path=%2Frepo%2Fcineflow&prompt="))
        check(dismissals == 1 && model.draft.isEmpty && model.receipt?.tone == .handedOff && model.receipt?.title.contains("等你发送") == true,
              "a handoff is never reported as delivered")

        // The next task starts from what was remembered, still in plain view.
        model.prepareForSummon()
        check(model.target == .agent(.codex) && model.project?.path == "/repo/cineflow")
        let reborn = QuickInputModel(state: state, environment: environment())
        reborn.prepareForSummon()
        check(reborn.target == .agent(.codex) && reborn.project?.path == "/repo/cineflow", "the choice survives a restart")

        // A typed token picks a target and leaves the sentence clean; `@` inside plain text stays.
        model.textChanged("看一下 @", cursor: 5)
        check(model.pickerVisible && model.pickerKind == .target)
        model.textChanged("看一下 @cla", cursor: 8)
        check(model.rows.first?.kind == .agent(.claude))
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
        long.submit()
        check(copied == text && opened.last?.absoluteString.contains("prompt=") == false && long.receipt?.body.contains("已复制") == true)

        // A missing handler keeps everything in place.
        let missing = QuickInputModel(state: state, environment: environment(handler: false))
        var missingDismissed = false
        missing.onDismiss = { missingDismissed = true }
        missing.prepareForSummon()
        missing.textChanged("x", cursor: 1)
        missing.submit()
        check(missing.notice != nil && missing.draft == "x" && !missingDismissed)

        sending()
    }

    private static func sending() {
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

        model.pick(QuickInputRow(id: "s", kind: .session(running), title: "", subtitle: ""))
        check(model.primaryVerb == "插入当前步" && model.secondaryVerb == "排队", "both behaviours are on show while it runs")
        model.textChanged("补充", cursor: 2)
        model.submit()
        eventually({ sent.count == 1 && model.receipt?.title == "已插入当前这一步" }, "steering reports what happened")
        check(state.quickInputPulse.source == .codex && state.quickInputPulse.landings == 1)
        check(model.draft.isEmpty && model.target == .agent(.codex), "the next message starts as a new task for the same agent")

        // An uncertain result keeps the text, warns, and never resends.
        model.pick(QuickInputRow(id: "s", kind: .session(idle), title: "", subtitle: ""))
        check(model.primaryVerb == "继续" && model.secondaryVerb == nil)
        outcome = .uncertain
        model.textChanged("继续", cursor: 2)
        model.submit()
        eventually({ model.receipt?.tone == .warning }, "uncertain reaches a receipt")
        check(sent.count == 2 && model.warning != nil && model.receipt?.lingers == true)
        check(model.receipt?.actions.contains(.restore("继续")) == true)
        model.perform(.restore("继续"))
        check(model.draft == "继续" && model.receipt == nil && model.target == .session(idle.dockIdentity))

        // A refused message comes back too, and the dock shakes rather than bumps.
        outcome = .unavailable
        model.submit()
        eventually({ model.receipt?.tone == .failure }, "failure reaches a receipt")
        check(state.quickInputPulse.rejections == 1 && model.receipt?.lingers == true)

        // A session that starts waiting for the user stops taking messages.
        var waiting = data
        waiting.sessions = [session("00000000-0000-4000-8000-000000000002", title: "订阅校验", event: .approval)]
        state.agentDashboard = waiting
        model.perform(.restore("继续"))
        let before = sent.count
        model.submit()
        check(sent.count == before && model.notice?.contains("等你回应") == true)
    }

    static func queueFlows() {
        let state = makeState()
        let id = "00000000-0000-4000-8000-000000000001"
        func publish(running: Bool, event: AgentSessionEvent = .working) {
            var data = AgentDockData(); data.sessions = [session(id, running: running, event: event)]; state.agentDashboard = data
        }
        publish(running: true)
        var sent: [String] = []
        state.sendAgentMessage = { _, text in sent.append(text); return .accepted }
        let model = QuickInputModel(state: state, environment: environment())
        model.prepareForSummon()
        let running = state.agentDashboard.sessions[0]
        model.pick(QuickInputRow(id: "s", kind: .session(running), title: "", subtitle: ""))
        model.textChanged("下一件事", cursor: 4)
        model.submit(alternate: true)
        check(sent.isEmpty && model.queue.count == 1 && state.quickInputQueued[.codex] == 1 && model.receipt?.title.contains("已排队") == true)
        check(model.receipt?.lingers == true, "a queued message stays cancellable")
        check(state.quickInputDefaults.data(forKey: "quickInput.queue") != nil)

        publish(running: true); spin()
        check(sent.isEmpty, "nothing leaves while it still runs")
        publish(running: false, event: .recent); spin()
        check(sent.isEmpty, "one quiet reading is not the end of a turn")
        publish(running: true); publish(running: false, event: .recent); spin()
        check(sent.isEmpty, "a run between idle readings starts the count again")
        publish(running: false, event: .approval); publish(running: false, event: .approval); spin()
        check(sent.isEmpty, "a session waiting for the user is not idle")
        publish(running: false, event: .recent); publish(running: false, event: .recent)
        eventually({ sent == ["下一件事"] }, "two idle readings deliver it once")
        eventually({ model.receipt?.title == "排队的内容已发出" }, "delivery is reported")
        check(model.queue.isEmpty && state.quickInputQueued.isEmpty && state.quickInputDefaults.data(forKey: "quickInput.queue") == nil)
        publish(running: false, event: .recent); publish(running: false, event: .recent); spin()
        check(sent.count == 1, "delivered once")

        // Cancelling puts the text back for editing.
        publish(running: true)
        model.pick(QuickInputRow(id: "s", kind: .session(state.agentDashboard.sessions[0]), title: "", subtitle: ""))
        model.textChanged("算了", cursor: 2)
        model.submit(alternate: true)
        let queued = model.queue[0].id
        model.perform(.cancelQueue(queued))
        check(model.queue.isEmpty && model.draft == "算了" && state.quickInputQueued.isEmpty)
        model.textChanged("", cursor: 0)

        // The session disappearing returns the message rather than dropping it.
        model.pick(QuickInputRow(id: "s", kind: .session(state.agentDashboard.sessions[0]), title: "", subtitle: ""))
        model.textChanged("留着", cursor: 2)
        model.submit(alternate: true)
        state.agentDashboard = AgentDockData(); spin()
        check(model.queue.isEmpty && model.draft == "留着" && model.receipt?.tone == .failure)

        // Quitting while something waits: it returns as a draft and is not sent by itself.
        let persisted = makeState()
        persisted.quickInputDefaults.set(try! JSONEncoder().encode([QuickInputQueuedMessage(sessionID: "codex:x", source: "codex", title: "t", text: "重启前排队的")]), forKey: "quickInput.queue")
        var resent = 0
        persisted.sendAgentMessage = { _, _ in resent += 1; return .accepted }
        let restored = QuickInputModel(state: persisted, environment: environment())
        check(restored.draft == "重启前排队的" && restored.queue.isEmpty && resent == 0)
        check(persisted.quickInputDefaults.data(forKey: "quickInput.queue") == nil)
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
        var opened: [URL] = []
        let controller = QuickInputController(state: state, environment: environment(opened: { opened.append($0) }), tileCenter: { _ in nil }, dockFrame: { nil })
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

        text.setMarkedText("jian", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        check(text.hasMarkedText())
        controller.model.textChanged(text.string, cursor: text.selectedRange().location)
        key(36, "\r", to: panel)
        check(opened.isEmpty && controller.isShown, "Return while composing never sends")
        text.unmarkText(); text.string = ""; controller.model.textChanged("", cursor: 0)

        text.insertText("第一行", replacementRange: text.selectedRange())
        check(controller.model.draft == "第一行")
        key(36, "\r", [.shift], to: panel)
        check(text.string == "第一行\n" && controller.model.draft == "第一行\n" && opened.isEmpty, "Shift-Return is a newline, got \(text.string.debugDescription)")
        text.insertText("第二行", replacementRange: text.selectedRange())
        let heightBefore = panel.frame.height
        spin(0.4)
        check(panel.frame.height > heightBefore - 1, "the panel grows with its text")

        key(36, "\r", to: panel)
        check(controller.model.pickerKind == .target && controller.isShown && opened.isEmpty, "Return opens what is missing")
        spin(0.35)
        check(panel.frame.height > 150, "the list opens inside the same panel: \(panel.frame.height)")
        key(53, "\u{1b}", to: panel)
        check(controller.model.pickerKind == nil && controller.isShown, "Escape closes the list first")
        key(48, "\t", to: panel)
        check(controller.model.pickerKind == .target, "Tab opens who")
        key(125, "", to: panel)
        check(controller.model.selection == 1)
        key(126, "", to: panel)
        check(controller.model.selection == 0)
        key(36, "\r", to: panel)
        check(controller.model.target == .agent(.codex) && controller.model.pickerKind == .project)
        key(53, "\u{1b}", to: panel)
        key(53, "\u{1b}", to: panel)
        spin(0.3)
        check(!controller.isShown && controller.model.draft == "第一行\n第二行", "Escape hides the panel and keeps the draft")
        state.quickInputSummon.send()
        eventually({ controller.isShown }, "it comes back")
        spin(0.2)
        state.quickInputSummon.send()
        eventually({ !controller.isShown }, "the same shortcut toggles it away")
        spin(0.2)
        check(textView(in: panel.contentView)?.string == "第一行\n第二行", "the draft is still in the editor")

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

    /// Windows are captured over a bright backdrop window so the glass has something to show.
    static func snapshots(_ directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [true, false] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            NSApp.appearance = appearance
            let state = makeState()
            state.desktopCompanionAppearance = dark ? .dark : .light
            var data = AgentDockData()
            data.quotas = [AgentDockQuota(id: "c", source: .codex, title: "每周", remaining: 64, resetAt: nil, observedAt: Date(), stale: false, window: .weekly),
                           AgentDockQuota(id: "l", source: .claude, title: "会话", remaining: 31, resetAt: nil, observedAt: Date(), stale: false, window: .session)]
            let running = session("00000000-0000-4000-8000-000000000001", running: true)
            data.sessions = [running, session("00000000-0000-4000-8000-000000000002", title: "订阅校验重试", cwd: "/repo/while-ai-works"),
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
                let ids = [CGWindowID(window.windowNumber), CGWindowID(backdrop.windowNumber)]
                let list = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }.withUnsafeBufferPointer { CFArrayCreate(nil, unsafeBitCast($0.baseAddress, to: UnsafeMutablePointer<UnsafeRawPointer?>?.self), ids.count, nil) }!
                guard let image = CGImage(windowListFromArrayScreenBounds: .null, windowArray: list, imageOption: [.boundsIgnoreFraming, .bestResolution]) else { print("snapshot failed: \(label)"); return }
                let target = directory.appendingPathComponent("quick-input-\(name)-\(label).png")
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: target)
                print("snapshot: \(target.path)")
            }
            controller.show(); spin(0.4)
            let model = controller.model
            let editor = textView(in: controller.panel.contentView)
            editor?.insertText("检查一下充值有效期的处理，重点看边界情况", replacementRange: editor?.selectedRange() ?? NSRange())
            capture("first", controller.panel)
            model.pick(model.rowsForSnapshot(.target).first { $0.kind == .agent(.codex) } ?? QuickInputRow(id: "c", kind: .agent(.codex), title: "", subtitle: ""))
            model.pick(QuickInputRow(id: "p", kind: .project(QuickInputProject(path: "/repo/cineflow")), title: "", subtitle: ""))
            capture("new", controller.panel)
            model.togglePicker(.target)
            capture("picker", controller.panel)
            model.closePicker()
            model.pick(QuickInputRow(id: "s", kind: .session(running), title: "", subtitle: ""))
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

extension QuickInputModel {
    fileprivate func rowsForSnapshot(_ kind: QuickInputPickerKind) -> [QuickInputRow] {
        togglePicker(kind)
        defer { closePicker() }
        return rows
    }
}
