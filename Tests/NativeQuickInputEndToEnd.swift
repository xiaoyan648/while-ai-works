import AppKit
import AgentHUDCore
import WhileCore

/// The real thing, on this Mac: real session data, the real launcher, the default terminal and
/// the agents themselves. It starts live sessions that spend a little quota and stay open, so
/// it is never part of the regular checks. Quit other While AI Works instances first.
/// Usage: check-quick-input-e2e.sh <trusted directory> [claude codex hermes] [--links]
private func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
private func front() -> String { NSWorkspace.shared.frontmostApplication?.localizedName ?? "?" }

@main enum NativeQuickInputEndToEnd {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        AgentCommandEnvironment.configure()
        var arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
        let links = arguments.contains("--links")
        arguments.removeAll { $0 == "--links" }
        guard let directory = arguments.first else { fputs("a directory is required\n", stderr); exit(2) }
        let sources = arguments.dropFirst().compactMap(WorkSource.init(rawValue:))
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
        var failed = 0
        for source in sources {
            let run = String(UUID().uuidString.prefix(6))
            let prompt = "WAW E2E \(run) \"引号\" $(不展开)：只回复 ok，不要调用工具，不要改文件。"
            model.prepareForSummon()
            model.togglePicker(.agent)
            guard let row = model.rows.first(where: { $0.source == source }) else { print("\(source): not listed"); failed += 1; continue }
            model.pick(row)
            model.pick(workspace: workspace)
            model.textChanged(prompt, cursor: (prompt as NSString).length)
            let before = front(), started = Date()
            var frontWhileStarting = Set<String>()
            model.submit()
            if model.notice != nil { print("\(source): could not start: \(model.notice ?? "")"); failed += 1; continue }
            while Date().timeIntervalSince(started) < 80 {
                spin(0.1)
                frontWhileStarting.insert(front())
                if Int(Date().timeIntervalSince(started) * 10) % 40 == 0 { state.refreshAgentData() }
                if let receipt = model.receipt, receipt.tone == .success || receipt.tone == .warning { break }
            }
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
            let outcome = model.receipt?.title ?? "no receipt"
            let confirmed = model.receipt?.tone == .success
            if !confirmed { failed += 1 }
            print("\(source): \(confirmed ? "PASS" : "FAIL") \(elapsed)s | \(outcome) | \(model.receipt?.body.prefix(40) ?? "") | front \(before) -> \(front()), seen \(frontWhileStarting.sorted())")
            spin(6)
            let session = model.dockSessions.first { $0.source == source && $0.title.contains(run) } ?? model.dockSessions.first { $0.source == source && QuickInputCatalog.path(of: $0) == directory }
            print("  in dock: \(session.map { "\(QuickInputCatalog.sessionRow($0).trailing) | \($0.title.prefix(40)) | url \($0.navigationURL?.scheme ?? "none") | canSend \($0.canSend)" } ?? "missing")")
            model.dismissReceipt()
            spin(1)
        }
        if links {
            // Opens real windows; nothing is sent. Focus is handed back after each one.
            let previous = NSWorkspace.shared.frontmostApplication
            for source in [WorkSource.codex, .claude] {
                model.prepareForSummon()
                model.togglePicker(.agent)
                if let row = model.rows.first(where: { $0.source == source }) { model.pick(row) }
                model.pick(workspace: workspace)
                model.textChanged("WAW 深链验证：无需发送", cursor: 12)
                print("\(source): open verb \(model.secondaryVerb ?? "none")")
                model.submit(openClient: true)
                print("  notice \(model.notice ?? "none") | receipt \(model.receipt?.title ?? "none")")
                spin(3)
                print("  front \(front())")
                previous?.activate(); spin(1)
            }
        }
        hub.stop()
        print(failed == 0 ? "End to end passed" : "End to end: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
