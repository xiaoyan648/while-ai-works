import AppKit
import SwiftUI
import WhileCore
import AgentHUDCore

/// Measures main-thread stalls while the pointer moves across agents with the card
/// open. A 240 Hz timer records how late each tick fires; long gaps are dropped frames.
/// `--loop N` keeps switching for N seconds so a sampler can attach.
@main enum NativeDockSwitchPerf {
    static func main() {
        _ = NSApplication.shared
        let suite = "WhileAIWorks.DockSwitchPerf." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(defaults: defaults)
        state.soundEnabled = false
        state.selectedSources = Set(WorkSource.allCases)
        let env = ProcessInfo.processInfo.environment
        state.agentReplyPreviews = env["PERF_REPLIES"] != "0"
        let perSource = Int(env["PERF_SESSIONS"] ?? "") ?? 15
        state.desktopPetEnabled = true
        let now = Date()
        let reply = "已完成猫条交互与布局调整。详细检查覆盖多种状态，以及窗口切换、键盘焦点和原会话同步；长回复按真实宽度截断。"
        var sessions: [AgentDockSession] = []
        for source in WorkSource.allCases {
            for index in 0..<perSource {
                let running = index < 2
                sessions.append(AgentDockSession(id: "\(source.rawValue)-\(index)", source: source,
                    title: "\(source.clientName) 会话 \(index + 1) · 调整猫条动效与详情卡布局", project: "While AI Works",
                    status: running ? "工作中" : "已回复", running: running,
                    tokensIn: 1000 * (index + 1), tokensOut: 300 * (index + 1), cacheRead: 9000 * (index + 1),
                    reply: running ? nil : reply + String(repeating: "补充说明。", count: index % 4),
                    observedAt: now.addingTimeInterval(-Double(index) * 300), navigationURL: nil, resumeCommand: nil,
                    event: running ? .working : .finished, eventAt: now.addingTimeInterval(-Double(index) * 300),
                    turnStartedAt: running ? now.addingTimeInterval(-600) : nil))
            }
        }
        state.agentDashboard = AgentDockData(quotas: WorkSource.allCases.map {
            AgentDockQuota(id: "q-" + $0.rawValue, source: $0, title: "每周", remaining: 62, resetAt: now.addingTimeInterval(86400),
                           observedAt: now, stale: false, window: .weekly)
        }, sessions: sessions, updatedAt: now)
        state.activeSessionCounts = [.codex: 2, .claude: 2, .qoder: 2, .workbuddy: 2]
        // `--real` reads this Mac's Codex and Claude data through the app's own pipeline.
        var hub: AnyObject?
        if CommandLine.arguments.contains("--real") {
            state.agentDashboard = AgentDockData(); state.activeSessionCounts = [:]
            state.selectedSources = [.codex, .claude]
            hub = AgentHubDataController(state: state)
            let begin = Date()
            while state.agentDashboard.updatedAt == nil && Date().timeIntervalSince(begin) < 120 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            }
            print(String(format: "real data after %.1f s: %d sessions, %d quotas", Date().timeIntervalSince(begin),
                         state.agentDashboard.sessions.count, state.agentDashboard.quotas.count))
        }
        let bundle = Bundle(path: "dist/While AI Works.app")!
        let dock = DesktopDockController(state: state, mascot: MascotController(bundle: bundle), cardMascot: MascotController(bundle: bundle))
        func settle(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        settle(1.0)

        var ticks: [CFTimeInterval] = []
        var recording = false
        let timer = Timer(timeInterval: 1.0 / 240, repeats: true) { _ in if recording { ticks.append(CACurrentMediaTime()) } }
        RunLoop.main.add(timer, forMode: .common)

        let order = WorkSource.dockOrder
        dock.hover(.codex, entered: true); settle(0.6)
        precondition(dock.cardVisible, "card opens for the switch test")
        if let seconds = CommandLine.arguments.firstIndex(of: "--idle").flatMap({ Double(CommandLine.arguments[$0 + 1]) }) {
            settle(seconds); return
        }
        if let seconds = CommandLine.arguments.firstIndex(of: "--updates").flatMap({ Double(CommandLine.arguments[$0 + 1]) }) {
            let begin = CACurrentMediaTime(); var step = 0
            while CACurrentMediaTime() - begin < seconds {
                state.workIntensity = Double(step % 5) / 5; state.activeSessionCounts[.codex] = 2 + step % 2
                step += 1; settle(0.1)
            }
            return
        }
        // Rapid clicks on the Codex tile: each click toggles the pinned card open or closed.
        if let clicks = CommandLine.arguments.firstIndex(of: "--tiles").flatMap({ Int(CommandLine.arguments[$0 + 1]) }) {
            dock.dismiss(); settle(0.4)
            var handling: [Double] = []
            recording = true
            for _ in 0..<clicks {
                let begin = CACurrentMediaTime()
                dock.select(.codex)
                handling.append((CACurrentMediaTime() - begin) * 1000)
                settle(0.06)
            }
            settle(1.0)
            recording = false
            let gaps = zip(ticks, ticks.dropFirst()).map { ($1 - $0) * 1000 }.sorted()
            let long = gaps.filter { $0 > 25 }
            print(String(format: "tile clicks %d · gap p95 %.1f ms, max %.1f ms · gaps > 25 ms: %d (%.0f ms total) · click handling mean %.1f ms, max %.1f ms",
                         clicks, gaps.isEmpty ? 0 : gaps[Int(Double(gaps.count) * 0.95)], gaps.last ?? 0, long.count, long.reduce(0, +),
                         handling.reduce(0, +) / Double(max(1, handling.count)), handling.max() ?? 0))
            withExtendedLifetime(dock) {}; withExtendedLifetime(hub) {}
            return
        }
        // Rapid clicks on the sessions/quota tabs of a pinned Codex card, as the tab
        // button does them: every click writes the tab even when it is already shown.
        if let clicks = CommandLine.arguments.firstIndex(of: "--tabs").flatMap({ Int(CommandLine.arguments[$0 + 1]) }) {
            dock.select(.codex); settle(0.4)
            precondition(dock.cardVisible && state.desktopDockSource == .codex, "a pinned Codex card for the tab test")
            let interval = Double(env["PERF_TAB_INTERVAL"] ?? "") ?? 0.04
            var handling: [Double] = [], settles: [Double] = []
            recording = true
            for click in 0..<clicks {
                let begin = CACurrentMediaTime()
                // PERF_TAB_IDLE=1 measures the same time span with no switches, as a baseline.
                if env["PERF_TAB_IDLE"] != "1" {
                    state.desktopDockTab = click % 3 == 2 ? state.desktopDockTab : (click % 2 == 0 ? .quota : .sessions)
                }
                state.agentInteractionInputID = nil
                state.hideAgentReplyPreview()
                handling.append((CACurrentMediaTime() - begin) * 1000)
                let settleBegin = CACurrentMediaTime()
                settle(interval)
                settles.append((CACurrentMediaTime() - settleBegin) * 1000 - interval * 1000)
            }
            settle(1.0)
            recording = false
            let gaps = zip(ticks, ticks.dropFirst()).map { ($1 - $0) * 1000 }.sorted()
            func percentile(_ p: Double) -> Double { gaps.isEmpty ? 0 : gaps[min(gaps.count - 1, Int(Double(gaps.count) * p))] }
            let long = gaps.filter { $0 > 25 }
            // Time the 240 Hz timer could not fire: main-thread work, per click.
            let busy = gaps.reduce(0) { $0 + max(0, $1 - 1000.0 / 240) }
            print(String(format: "tab clicks %d · main-thread gaps: p50 %.1f ms, p95 %.1f ms, max %.1f ms · gaps > 25 ms: %d (%.0f ms total) · busy %.1f ms per click",
                         clicks, percentile(0.5), percentile(0.95), gaps.last ?? 0, long.count, long.reduce(0, +), busy / Double(max(1, clicks))))
            print(String(format: "click handling: mean %.2f ms, max %.2f ms · overrun per click: mean %.1f ms, max %.1f ms",
                         handling.reduce(0, +) / Double(max(1, handling.count)), handling.max() ?? 0,
                         settles.reduce(0, +) / Double(max(1, settles.count)), settles.max() ?? 0))
            withExtendedLifetime(dock) {}; withExtendedLifetime(hub) {}
            return
        }
        let loop = CommandLine.arguments.firstIndex(of: "--loop").flatMap { Double(CommandLine.arguments[$0 + 1]) }
        var switches = 0
        var synchronous: [Double] = []
        recording = true
        let start = CACurrentMediaTime()
        var previous = WorkSource.codex
        while loop.map({ CACurrentMediaTime() - start < $0 }) ?? (switches < 40) {
            let next = order[(order.firstIndex(of: previous)! + 1) % order.count]
            let begin = CACurrentMediaTime()
            dock.hover(next, entered: true)
            dock.hover(previous, entered: false)
            synchronous.append((CACurrentMediaTime() - begin) * 1000)
            previous = next; switches += 1
            settle(0.12)
        }
        recording = false
        let gaps = zip(ticks, ticks.dropFirst()).map { ($1 - $0) * 1000 }.sorted()
        func percentile(_ p: Double) -> Double { gaps.isEmpty ? 0 : gaps[min(gaps.count - 1, Int(Double(gaps.count) * p))] }
        let long = gaps.filter { $0 > 25 }
        print(String(format: "switches %d · main-thread gaps: p50 %.1f ms, p95 %.1f ms, p99 %.1f ms, max %.1f ms · gaps > 25 ms: %d (%.0f ms total)",
                     switches, percentile(0.5), percentile(0.95), percentile(0.99), gaps.last ?? 0, long.count, long.reduce(0, +)))
        print(String(format: "synchronous hover handling: mean %.2f ms, max %.2f ms",
                     synchronous.reduce(0, +) / Double(max(1, synchronous.count)), synchronous.max() ?? 0))
        if loop == nil {
            // Guard rails, well above today's numbers (p95 ≈ 14 ms, ≈ 0.5 s of long gaps)
            // and far below the 2026-10-17 baseline (p95 109 ms, 4.2 s).
            precondition(percentile(0.95) < 25, "switching agents keeps 95% of frames under 25 ms")
            precondition(long.reduce(0, +) < 1500, "long main-thread gaps while switching stay under 1.5 s in total")
        }
        // Ordinary state churn with the card open (the monitor publishes every few seconds).
        settle(0.5)
        var updates: [Double] = []
        for step in 0..<20 {
            let begin = CACurrentMediaTime()
            state.workIntensity = Double(step % 5) / 5
            state.activeSessionCounts[.codex] = 2 + step % 2
            settle(0.0)
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            updates.append((CACurrentMediaTime() - begin) * 1000 - 30)
        }
        print(String(format: "state update with card open: mean %.1f ms, max %.1f ms",
                     updates.reduce(0, +) / Double(updates.count), updates.max() ?? 0))
        withExtendedLifetime(dock) {}
    }
}
