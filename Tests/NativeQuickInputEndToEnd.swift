import AppKit
import AgentHUDCore
import WhileCore

/// The real thing, on this Mac: real session data, the real launcher, the default terminal and
/// the agents themselves. It starts live sessions that spend a little quota and stay open, so
/// it is never part of the regular checks. Quit other While AI Works instances first.
/// Usage: check-quick-input-e2e.sh <trusted directory> [codexCLI claudeCode hermes] [--resume] [--open]
private func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
private func front() -> String { NSWorkspace.shared.frontmostApplication?.localizedName ?? "?" }

@main enum NativeQuickInputEndToEnd {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        AgentCommandEnvironment.configure()
        var arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
        let resume = arguments.contains("--resume"), opening = arguments.contains("--open")
        arguments.removeAll { $0.hasPrefix("--") }
        guard let directory = arguments.first else { fputs("a directory is required\n", stderr); exit(2) }
        let clients = arguments.dropFirst().compactMap(QuickInputClient.init(rawValue:))
        let suite = "WhileAIWorks.QuickInputE2E." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(defaults: defaults)
        state.soundEnabled = false; state.selectedSources = [.codex, .claude, .hermes, .dsh]
        let hub = AgentHubDataController(state: state)
        let begin = Date()
        while state.agentDashboard.updatedAt == nil && Date().timeIntervalSince(begin) < 90 { spin(0.2) }
        print("dashboard after \(Int(Date().timeIntervalSince(begin)))s: \(state.agentDashboard.sessions.count) sessions")

        var environment = QuickInputEnvironment()
        environment.startTimeout = 75
        let model = QuickInputModel(state: state, environment: environment)
        let workspace = QuickInputProject(path: directory)
        model.prepareForSummon(); spin(2)
        model.togglePicker(.agent)
        print("clients:", model.rows.map { $0.title + "(" + $0.subtitle + ")" })
        model.closePicker()
        var failed = 0

        func waitForReceipt(_ label: String, started: Date, before: String) {
            var seen = Set<String>()
            while Date().timeIntervalSince(started) < 80 {
                spin(0.1)
                seen.insert(front())
                if Int(Date().timeIntervalSince(started) * 10) % 40 == 0 { state.refreshAgentData() }
                if let receipt = model.receipt, receipt.tone == .success || receipt.tone == .warning { break }
            }
            let confirmed = model.receipt?.tone == .success
            if !confirmed { failed += 1 }
            print("\(label): \(confirmed ? "PASS" : "FAIL") \(String(format: "%.1f", Date().timeIntervalSince(started)))s | \(model.receipt?.title ?? "no receipt") | front \(before) -> \(front()), seen \(seen.sorted())")
        }

        for client in clients {
            let run = String(UUID().uuidString.prefix(6))
            let prompt = "WAW E2E \(run) \"引号\" $(不展开)：只回复 ok，不要调用工具，不要改文件。"
            model.prepareForSummon(); spin(1)
            model.togglePicker(.agent)
            guard let row = model.rows.first(where: { $0.client == client }) else { print("\(client): not offered"); failed += 1; continue }
            model.pick(row)
            model.pick(workspace: workspace)
            model.textChanged(prompt, cursor: (prompt as NSString).length)
            print("\(client): sendable \(model.canSendNow), hint \(model.hint ?? "none")")
            guard model.canSendNow else { model.textChanged("", cursor: 0); model.closePicker(); continue }
            let before = front(), started = Date()
            model.submit()
            if model.notice != nil { print("\(client): could not start: \(model.notice ?? "")"); failed += 1; continue }
            waitForReceipt(client.rawValue, started: started, before: before)
            spin(25)
            state.refreshAgentData(); spin(3)
            let session = model.dockSessions.first { $0.title.contains(run) } ?? model.dockSessions.first { QuickInputCatalog.client(of: $0) == client && QuickInputCatalog.path(of: $0) == directory }
            print("  in dock: \(session.map { "\(QuickInputCatalog.status($0).text) | \($0.title.prefix(30)) | client \(QuickInputCatalog.client(of: $0)?.rawValue ?? "?") | canSend \(QuickInputCatalog.canSend($0, claudeCodeWorks: true))" } ?? "missing")")
            model.dismissReceipt(); spin(0.5)
        }

        if resume {
            // The newest ended Codex CLI session takes a second message by being resumed.
            state.refreshAgentData(); spin(3)
            model.prepareForSummon(); spin(1.5)
            let candidates = model.dockSessions.filter { QuickInputCatalog.client(of: $0) == .codexCLI && ($0.title.contains("WAW") || $0.title.contains("回复 ok")) }
            print("resume candidates:", candidates.map { String($0.title.prefix(14)) })
            var resumed = false
            for session in candidates where !resumed {
                model.pick(session: session); spin(0.1)
                let text = "WAW E2E 续发：只回复 ok2，不要调用工具。"
                model.textChanged(text, cursor: (text as NSString).length)
                guard model.canSendNow else { print("  still held by a process, not resumed:", String(session.title.prefix(14))); model.textChanged("", cursor: 0); continue }
                resumed = true
                let before = front(), started = Date()
                model.submit()
                waitForReceipt("resume", started: started, before: before)
                model.dismissReceipt()
            }
            if !resumed { print("resume: every candidate is still open") }
            model.clearSessionTarget()
        }

        // Liveness comes from the agents, and a held session's terminal comes forward whichever it is.
        let held = QuickInputLiveness.current()
        print("live sessions:", held.count, "| CLI among them:", model.dockSessions.filter { held[$0.id] != nil && $0.navigationURL == nil }.map { String($0.title.prefix(12)) })
        if opening, let pid = model.dockSessions.first(where: { held[$0.id] != nil && $0.navigationURL == nil }).flatMap({ held[$0.id] }) {
            let previous = NSWorkspace.shared.frontmostApplication
            print("bring forward:", QuickInputLiveness.bringOwnerForward(of: pid)); spin(0.8)
            print("  front \(front())")
            previous?.activate(); spin(0.8)
        }

        if opening {
            // Opens real windows; nothing is sent. Focus is handed back after each one.
            let previous = NSWorkspace.shared.frontmostApplication
            for client in [QuickInputClient.codexApp, .claudeApp, .codexCLI] {
                model.prepareForSummon(); spin(0.5)
                model.togglePicker(.agent)
                guard let row = model.rows.first(where: { $0.client == client }) else { print("\(client): not offered"); continue }
                model.pick(row)
                model.pick(workspace: workspace)
                model.textChanged("WAW 打开验证：无需发送", cursor: 12)
                model.submit(go: true)
                spin(2)
                print("\(client): notice \(model.notice ?? "none") | receipt \(model.receipt?.title ?? "none") | front \(front())")
                model.dismissReceipt()
                previous?.activate(); spin(1)
            }
        }
        hub.stop()
        print(failed == 0 ? "End to end passed" : "End to end: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
