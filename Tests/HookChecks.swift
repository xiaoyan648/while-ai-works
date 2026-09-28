import Foundation
import CryptoKit
import WhileCore

enum CheckFailure: Error { case failed(String) }
@main enum HookChecks {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CheckFailure.failed(message) }
        count += 1
    }
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("while-hooks-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let now = Date()
        func record(_ event: String, _ id: String = "a", generation: String = "new", provider: HookProvider = .qoder) throws {
            let data = try JSONSerialization.data(withJSONObject: ["hook_event_name": event, "session_id": id,
                "generation_id": generation, "prompt": "PRIVATE-PROMPT", "tool_input": "PRIVATE-TOOL"])
            try HookBridge.record(data, provider: provider, directory: root, now: now)
        }
        try record("UserPromptSubmit")
        try check(HookBridge.sessions(provider: .qoder, directory: root).values.contains { $0.working }, "start")
        try check(HookBridge.sessions(provider: .qoder, directory: root).values.first?.phase == .running, "request phase")
        try record("PreToolUse")
        try check(HookBridge.sessions(provider: .qoder, directory: root).values.first?.phase == .tool, "tool phase")
        let legacySnapshot = Data(#"{"working":true,"updatedAt":0,"count":1}"#.utf8)
        let decodedLegacy = try JSONDecoder().decode(HookSession.self, from: legacySnapshot)
        try check(decodedLegacy.phase == nil, "old hook snapshots remain readable")
        try record("Stop", generation: "old")
        try check(HookBridge.sessions(provider: .qoder, directory: root).values.contains { $0.working }, "old generation must not stop new work")
        try record("UserPromptSubmit", "b")
        try record("Stop")
        try check(HookBridge.sessions(provider: .qoder, directory: root).values.filter { $0.working }.count == 1, "parallel sessions")
        try record("SessionEnd", "b", generation: "")
        try check(!HookBridge.sessions(provider: .qoder, directory: root).values.contains { $0.working }, "last session ends")
        try record("PreToolUse", "c", provider: .workbuddy)
        try check(HookBridge.sessions(provider: .workbuddy, directory: root).values.contains { $0.working }, "tool activity can recover missed start")
        try check(!HookBridge.sessions(provider: .qoder, directory: root).values.contains { $0.working }, "provider isolation")
        try check(HookBridge.sessions(provider: .workbuddy, directory: root, now: now.addingTimeInterval(300)).isEmpty, "crashed client expires after five minutes")
        try record("SubagentStop", "c", provider: .workbuddy)
        try check(HookBridge.sessions(provider: .workbuddy, directory: root).values.contains { $0.working }, "subagent cannot stop parent")
        try record("Stop", "c", provider: .workbuddy)
        try check(!HookBridge.sessions(provider: .workbuddy, directory: root).values.contains { $0.working }, "workbuddy stop")
        // WorkBuddy changes message IDs between model responses in the same user turn.
        try record("UserPromptSubmit", "wb-1", generation: "previous-response", provider: .workbuddy)
        try record("UserPromptSubmit", "wb-1", generation: "previous-response", provider: .workbuddy)
        try record("UserPromptSubmit", "wb-2", provider: .workbuddy)
        func workbuddyActiveCount() -> Int {
            HookBridge.sessions(provider: .workbuddy, directory: root).values.filter { $0.working }.count
        }
        try check(workbuddyActiveCount() == 2, "duplicate starts do not inflate active session count")
        try record("PreToolUse", "wb-1", generation: "response-1", provider: .workbuddy)
        try record("PostToolUse", "wb-1", generation: "response-1", provider: .workbuddy)
        try record("PreToolUse", "wb-1", generation: "response-2", provider: .workbuddy)
        try record("PostToolUse", "wb-1", generation: "response-2", provider: .workbuddy)
        let busy = HookBridge.sessions(provider: .workbuddy, directory: root).values
        try check(busy.contains { $0.count == 6 && $0.working && $0.generation == nil }, "all tool events accepted across changing message IDs")
        try record("Stop", "wb-1", generation: "final-response", provider: .workbuddy)
        try check(workbuddyActiveCount() == 1, "final response ID must not prevent WorkBuddy stop")
        try record("Stop", "wb-1", generation: "final-response", provider: .workbuddy)
        try record("SessionEnd", "wb-1", provider: .workbuddy)
        try record("Stop", "unknown", provider: .workbuddy)
        try check(workbuddyActiveCount() == 1, "duplicate and unknown ends cannot stop another session")
        try record("Stop", "wb-2", generation: "another-final-response", provider: .workbuddy)
        try check(workbuddyActiveCount() == 0, "last session end returns to idle")
        try record("UserPromptSubmit", "wb-1", generation: "next-turn", provider: .workbuddy)
        try check(workbuddyActiveCount() == 1, "next turn in same session reactivates work")
        try record("Stop", "wb-1", generation: "next-final-response", provider: .workbuddy)
        try check(workbuddyActiveCount() == 0, "consecutive turn completes normally")
        // Upgrade must also accept a Stop against an old snapshot containing a message ID.
        let legacyID = SHA256.hash(data: Data("legacy".utf8)).map { String(format: "%02x", $0) }.joined()
        let legacy = root.appendingPathComponent("workbuddy/\(legacyID).json")
        try JSONSerialization.data(withJSONObject: ["working": true, "updatedAt": now.timeIntervalSinceReferenceDate,
                                                    "generation": "old-message", "count": 3]).write(to: legacy)
        try record("Stop", "legacy", generation: "final-response", provider: .workbuddy)
        let migrated = try JSONDecoder().decode(HookSession.self, from: Data(contentsOf: legacy))
        try check(!migrated.working && migrated.generation == nil && migrated.count == 4, "new helper ends existing legacy snapshot")
        func claude(_ event: String, _ id: String = "claude-a") throws {
            let data = try JSONSerialization.data(withJSONObject: ["hook_event_name": event, "session_id": id,
                "prompt": "PRIVATE-PROMPT", "tool_input": ["command": "PRIVATE-CODE"], "last_assistant_message": "PRIVATE-REPLY"])
            try HookBridge.record(data, provider: .claude, directory: root)
        }
        func claudeCount() -> Int { HookBridge.sessions(provider: .claude, directory: root).values.filter { $0.working }.count }
        try claude("SessionStart")
        try check(claudeCount() == 0, "opening Claude is not work")
        try claude("UserPromptSubmit"); try claude("UserPromptSubmit"); try claude("UserPromptSubmit", "claude-b")
        try check(claudeCount() == 2, "Claude parallel sessions and duplicate starts")
        try claude("PreToolUse")
        try check(HookBridge.sessions(provider: .claude, directory: root).values.contains { $0.phase == .tool }, "Claude tool phase")
        try claude("PostToolUseFailure"); try claude("SubagentStop")
        try check(claudeCount() == 2, "failed tool and child stop do not end parent")
        try claude("Stop"); try claude("Stop")
        try check(claudeCount() == 1, "Claude completion leaves other session working")
        try claude("StopFailure", "claude-b")
        try check(claudeCount() == 0, "Claude API failure ends turn")
        try claude("UserPromptSubmit"); try claude("SessionEnd")
        try check(claudeCount() == 0, "Claude next turn and session end")
        let timeoutRoot = root.appendingPathComponent("timeout-checks")
        for provider in HookProvider.allCases {
            let data = Data(#"{"hook_event_name":"PreToolUse","session_id":"timeout"}"#.utf8)
            try HookBridge.record(data, provider: provider, directory: timeoutRoot, now: now)
            try check(HookBridge.sessions(provider: provider, directory: timeoutRoot, now: now.addingTimeInterval(299)).values.contains { $0.working }, "still working before five minutes")
            try check(HookBridge.sessions(provider: provider, directory: timeoutRoot, now: now.addingTimeInterval(300)).isEmpty, "expires exactly at five minutes")
            try HookBridge.record(data, provider: provider, directory: timeoutRoot, now: now.addingTimeInterval(301))
            try check(HookBridge.sessions(provider: provider, directory: timeoutRoot, now: now.addingTimeInterval(600)).values.contains { $0.working }, "new tool activity recovers and renews timeout")
            try check(HookBridge.sessions(provider: provider, directory: timeoutRoot, now: now.addingTimeInterval(601)).isEmpty, "renewed activity also expires")
        }
        for provider in HookProvider.allCases {
            for file in try fm.contentsOfDirectory(at: root.appendingPathComponent(provider.rawValue), includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                let text = try String(contentsOf: file)
                try check(!text.contains("PRIVATE-") && !text.contains("prompt") && !text.contains("tool_input"), "no conversation retained")
            }
        }
        let before = HookBridge.sessions(provider: .qoder, directory: root).count
        try HookBridge.record(Data("{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"\"}".utf8), provider: .qoder, directory: root)
        try check(HookBridge.sessions(provider: .qoder, directory: root).count == before, "missing ID ignored")
        try HookBridge.record(Data(repeating: 65, count: 1_048_577), provider: .qoder, directory: root)
        try check(HookBridge.sessions(provider: .qoder, directory: root).count == before, "oversize ignored")

        let home = root.appendingPathComponent("test user's home")
        let config = home.appendingPathComponent(".workbuddy/settings.json")
        try fm.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"enabledPlugins":{"existing":true},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"existing-command"}]}]}}"#.utf8)
        try original.write(to: config)
        let helper = root.appendingPathComponent("helper")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        try HookInstallation.install(provider: .workbuddy, helper: helper, home: home)
        try HookInstallation.install(provider: .workbuddy, helper: helper, home: home)
        let installed = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any]
        try check((installed["enabledPlugins"] as? [String: Bool])?["existing"] == true, "preserve settings")
        let groups = (installed["hooks"] as! [String: [[String: Any]]])["Stop"]!
        try check(groups.count == 2, "idempotent installation, existing hook retained")
        let command = (groups.last!["hooks"] as! [[String: Any]])[0]["command"] as! String
        try check(command.contains("'\\''"), "shell quote apostrophes in path")
        let backups = try fm.contentsOfDirectory(at: config.deletingLastPathComponent(), includingPropertiesForKeys: nil).filter { $0.pathExtension == "bak" }
        let backupBytes = backups.compactMap { try? Data(contentsOf: $0) }
        try check(backupBytes.contains(original), "exact original backup")
        try HookInstallation.install(provider: .workbuddy, helper: helper, home: home, remove: true)
        let removed = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any]
        let originalObject = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        try check(NSDictionary(dictionary: removed).isEqual(to: originalObject), "uninstall preserves original config")
        let invalid = Data(#"{"hooks":{"Stop":"invalid"}}"#.utf8)
        try invalid.write(to: config)
        var rejected = false
        do { try HookInstallation.install(provider: .workbuddy, helper: helper, home: home) } catch { rejected = true }
        try check(rejected, "malformed hooks rejected")
        let unchanged = try Data(contentsOf: config)
        try check(unchanged == invalid, "malformed config left untouched")
        let claudeConfig = home.appendingPathComponent(".claude/settings.json")
        try fm.createDirectory(at: claudeConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: claudeConfig)
        try HookInstallation.install(provider: .claude, helper: helper, home: home)
        try HookInstallation.install(provider: .claude, helper: helper, home: home)
        let claudeSettings = try JSONSerialization.jsonObject(with: Data(contentsOf: claudeConfig)) as! [String: Any]
        let claudeHooks = claudeSettings["hooks"] as! [String: [[String: Any]]]
        for event in HookProvider.claude.events {
            let entries = claudeHooks[event]!.flatMap { $0["hooks"] as! [[String: Any]] }
            try check(entries.filter { ($0["command"] as? String)?.hasSuffix(" claude") == true }.count == 1, "Claude hook installed once: " + event)
        }
        try HookInstallation.install(provider: .claude, helper: helper, home: home, remove: true)
        let claudeRemoved = try JSONSerialization.jsonObject(with: Data(contentsOf: claudeConfig)) as! [String: Any]
        try check(NSDictionary(dictionary: claudeRemoved).isEqual(to: originalObject), "Claude removal preserves existing config")
        print("HookChecks: \(count) passed")
    }
}
