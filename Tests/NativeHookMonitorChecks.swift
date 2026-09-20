import AppKit
import WhileCore

@main enum NativeHookMonitorChecks {
    static func main() throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("while-monitor-\(UUID())")
        let suite = "WhileAIWorks.HookMonitor.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? fm.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let state = AppState(defaults: defaults)
        precondition(state.followAI && state.selectedSources == Set(WorkSource.allCases), "fresh installs default to all clients")
        defaults.set("qoder", forKey: "source")
        precondition(AppState(defaults: defaults).selectedSources == Set(WorkSource.allCases), "legacy single selection migrates to all")
        defaults.set("manual", forKey: "source")
        precondition(!AppState(defaults: defaults).followAI, "preserve explicitly chosen manual mode")
        let codexRoot = root.appendingPathComponent("sessions")
        let monitor = CodexMonitor(state: state, codexRoot: codexRoot, hookDirectory: root)
        func tick() { RunLoop.main.run(until: Date().addingTimeInterval(1.8)) }
        func hook(_ event: String, _ provider: HookProvider, generation: String = "start") throws {
            let data = try JSONSerialization.data(withJSONObject: ["session_id": "test", "hook_event_name": event, "generation_id": generation])
            try HookBridge.record(data, provider: provider, directory: root)
        }
        state.followAI = true; state.selectedSources = [.qoder]; state.desktopEnabled = true
        try hook("UserPromptSubmit", .qoder); tick()
        precondition(state.detectedWorking && state.workIntensity >= 0.12)
        precondition(state.status.contains("Qoder"))
        state.followAI = true; state.selectedSources = [.workbuddy]
        precondition(!state.detectedWorking && state.workIntensity == 0)
        tick(); precondition(!state.detectedWorking, "old provider must not reactivate new selection")
        try hook("UserPromptSubmit", .workbuddy); tick()
        precondition(state.detectedWorking && state.status.contains("WorkBuddy"))
        try hook("Stop", .qoder); tick()
        precondition(state.detectedWorking, "unselected client stop must not affect current client")
        try hook("PostToolUse", .workbuddy, generation: "tool-response"); tick()
        precondition(state.detectedWorking)
        try hook("Stop", .workbuddy, generation: "final-response"); tick()
        precondition(!state.detectedWorking && state.workIntensity == 0)
        try hook("UserPromptSubmit", .workbuddy); tick()
        precondition(state.detectedWorking)
        let stale = Data(#"{"session_id":"test","hook_event_name":"PreToolUse"}"#.utf8)
        try HookBridge.record(stale, provider: .workbuddy, directory: root, now: Date().addingTimeInterval(-301))
        tick(); precondition(!state.detectedWorking && state.workIntensity == 0, "five-minute inactivity must stop work without Stop")
        try hook("PostToolUse", .workbuddy); tick()
        precondition(state.detectedWorking, "fresh tool activity must recover expired work")
        state.desktopEnabled = false; tick()
        precondition(!state.detectedWorking && state.workIntensity == 0)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"; formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let folder = codexRoot.appendingPathComponent(formatter.string(from: Date().addingTimeInterval(-30 * 86400)))
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("test.jsonl")
        let start = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"one\"}}\n"
        try Data(start.utf8).write(to: file)
        state.followAI = true; state.selectedSources = [.codex]; state.desktopEnabled = true; tick()
        precondition(state.detectedWorking && state.status.contains("Codex"), "Codex must discover a resumed task in a month-old creation folder")
        let end = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"one\"}}\n"
        try Data((start + end).utf8).write(to: file); tick()
        precondition(!state.detectedWorking)
        // The same hook session ID in two providers must remain independent.
        state.selectedSources = Set(WorkSource.allCases)
        try Data(start.utf8).write(to: file)
        try hook("UserPromptSubmit", .qoder)
        try hook("UserPromptSubmit", .workbuddy); tick()
        precondition(state.activeSessionCount == 3 && state.activeSessionCounts[.codex] == 1)
        precondition(state.status.contains("Codex") && state.status.contains("Qoder") && state.status.contains("WorkBuddy"))
        precondition(state.workIntensity >= 0.36 && state.workIntensity <= 1)
        try hook("UserPromptSubmit", .qoder); tick()
        precondition(state.activeSessionCount == 3, "duplicate start must not increment work count")
        try hook("Stop", .qoder); try hook("Stop", .qoder); tick()
        precondition(state.activeSessionCount == 2 && state.detectedWorking, "duplicate stop cannot stop other clients")
        try Data((start + end).utf8).write(to: file); tick()
        precondition(state.activeSessionCount == 1 && state.activeSessionCounts[.workbuddy] == 1)
        state.setSource(.workbuddy, selected: false); tick()
        precondition(state.activeSessionCount == 0 && !state.detectedWorking && state.workIntensity == 0)
        try hook("PreToolUse", .workbuddy); tick()
        precondition(!state.detectedWorking, "unselected events cannot contribute work or pace")
        // Reverse completion order for Codex + Qoder.
        try Data(start.utf8).write(to: file); try hook("UserPromptSubmit", .qoder); tick()
        precondition(state.activeSessionCount == 2)
        try Data((start + end).utf8).write(to: file); tick()
        precondition(state.activeSessionCount == 1 && state.status.contains("Qoder"))
        try hook("Stop", .qoder); tick()
        precondition(state.activeSessionCount == 0 && !state.detectedWorking && state.workIntensity == 0)
        let stamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-301))
        let silentStart = "{\"timestamp\":\"\(stamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"silent\"}}\n"
        try Data(silentStart.utf8).write(to: file); tick()
        precondition(!state.detectedWorking, "Codex also becomes idle after five silent minutes")
        let progress = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\"}}\n"
        try Data((silentStart + progress).utf8).write(to: file); tick()
        precondition(state.activeSessionCounts[.codex] == 1, "new Codex activity recovers after idle timeout")
        try Data((silentStart + progress + end.replacingOccurrences(of: "one", with: "silent")).utf8).write(to: file); tick()
        precondition(!state.detectedWorking)
        // Attach mid-turn to a >2 MB log whose start is outside the initial tail.
        state.desktopEnabled = false; tick()
        let padding = String(repeating: "{\"type\":\"ignored\",\"padding\":\"" + String(repeating: "x", count: 3000) + "\"}\n", count: 1000)
        let recoveredProgress = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"turn_id\":\"one\"}}\n"
        try Data((start + padding + recoveredProgress).utf8).write(to: file)
        state.desktopEnabled = true; tick()
        precondition(state.activeSessionCounts[.codex] == 1, "bounded tail must recover a currently running turn")
        try Data((start + padding + recoveredProgress + end + recoveredProgress).utf8).write(to: file); tick()
        precondition(!state.detectedWorking, "late progress for a completed turn cannot reactivate it")
        // Also discover an old task resumed after monitoring has already started.
        let olderFolder = codexRoot.appendingPathComponent(formatter.string(from: Date().addingTimeInterval(-90 * 86400)))
        try fm.createDirectory(at: olderFolder, withIntermediateDirectories: true)
        let resumedFile = olderFolder.appendingPathComponent("resumed.jsonl")
        try Data((start + end).utf8).write(to: resumedFile)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: resumedFile.path)
        RunLoop.main.run(until: Date().addingTimeInterval(6.5))
        precondition(!state.detectedWorking, "historical completed tasks must remain idle")
        let resume = start.replacingOccurrences(of: "one", with: "resumed")
        let stopResume = end.replacingOccurrences(of: "one", with: "resumed")
        try Data((start + end + resume).utf8).write(to: resumedFile)
        RunLoop.main.run(until: Date().addingTimeInterval(6.5))
        precondition(state.activeSessionCounts[.codex] == 1, "old task resumed during monitoring must be discovered")
        try Data((start + end + resume + stopResume).utf8).write(to: resumedFile); tick()
        precondition(!state.detectedWorking, "resumed old task must stop on its completion event")
        state.selectedSources = []; tick()
        precondition(!state.isWorking, "empty selection is idle, not manual")
        precondition(AppState(defaults: defaults).selectedSources.isEmpty, "explicit empty selection persists")
        state.selectedSources = [.codex, .qoder]
        precondition(AppState(defaults: defaults).selectedSources == [.codex, .qoder])
        // Rapid switch-away-and-back must reject stale queued publications.
        state.selectedSources = [.workbuddy]; state.selectedSources = [.codex, .qoder]; tick()
        precondition(!state.detectedWorking && state.activeSessionCount == 0)
        state.followAI = false; tick()
        precondition(state.isWorking && !state.detectedWorking && state.activeSessionCount == 0)
        state.followAI = true; try hook("UserPromptSubmit", .qoder); tick()
        state.desktopEnabled = false; tick()
        precondition(!state.detectedWorking && state.activeSessionCount == 0 && state.workIntensity == 0)
        withExtendedLifetime(monitor) {}
        print("NativeHookMonitorChecks: defaults/migration/persistence, per-client isolation, 3→2→1→0, duplicate lifecycle, both Codex+Qoder completion orders, deselection, empty/manual/off and timeout passed")
    }
}
