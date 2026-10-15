import AppKit
import Foundation
import AgentHUDCore
import AgentHUDSupport
import WhileCore

@MainActor final class FakeRequestBridge: AgentNativeRequestBridge {
    var result: AgentInteractionResult = .accepted
    var count = 0
    func fetch(_ ids: Set<String>) async throws -> AgentNativeRequestSnapshot { .init(requests: [], observed: ids) }
    func resolve(_ id: String, decision: PermissionDecision) async -> AgentInteractionResult { count += 1; return result }
}

@main enum AgentInteractionChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let suite = "WhileAIWorks.InteractionChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(defaults: defaults); state.desktopPetEnabled = true; state.selectedSources = [.codex, .claude]
        let bridge = FakeRequestBridge(), controller = AgentInteractionController(state: state, codex: bridge, start: false)
        let question = PermissionQuestion(id: "q1", question: "用哪种格式？", options: [.init(label: "摘要"), .init(label: "详细")])
        let request = PermissionRequest(id: "native-q", source: .codex, sessionID: "fixture", toolName: "request_user_input_async",
            summary: question.question, detail: nil, cwd: "/fixture", questions: [question], nativeApproval: .asynchronousQuestion(turnID: "t1"), at: Date())
        var draft = AgentInteractionDraft(); draft.pick(0, for: question); draft.pick(1, for: question)
        precondition(draft.answers(for: [question])[question.answerKey]?.selected == ["详细"])
        draft.type("我自己写", for: question)
        precondition(draft.answers(for: [question])[question.answerKey]?.selected.isEmpty == true)
        let decision = PermissionDecision.answer(draft.answers(for: [question]))
        precondition(AgentInteractionValidation.allows(decision, for: request))
        precondition(!AgentInteractionValidation.allows(.allow, for: request))
        precondition(!AgentInteractionValidation.allows(.answer(["wrong": .init(custom: "bad")]), for: request))
        controller.reconcile(.init(requests: [request], observed: ["fixture"]), queried: ["fixture"])
        state.agentInteractionDrafts[request.id] = draft
        controller.answer(request.id, decision: decision)
        precondition(state.agentInteractions[0].phase == .sending)
        controller.answer(request.id, decision: decision)
        try await eventually("native answer reaches confirming") { bridge.count == 1 && state.agentInteractions.first?.phase == .confirming }
        precondition(bridge.count == 1 && state.agentInteractions[0].phase == .confirming, "submission waits for withdrawal, no duplicate sends")
        controller.reconcile(.init(requests: [], observed: []), queried: ["fixture"])
        precondition(state.agentInteractions.count == 1 && !state.agentInteractions[0].fresh, "failed owner read cannot erase an outstanding request")
        controller.reconcile(.init(requests: [], observed: ["fixture"]), queried: ["fixture"])
        precondition(state.agentInteractions.isEmpty && state.agentInteractionDrafts.isEmpty)
        bridge.result = .uncertain
        controller.reconcile(.init(requests: [request], observed: ["fixture"]), queried: ["fixture"])
        controller.answer(request.id, decision: decision)
        try await eventually("uncertain native delivery is retained") { bridge.count == 2 && state.agentInteractions.first?.phase == .uncertain }
        controller.answer(request.id, decision: decision)
        precondition(bridge.count == 2 && state.agentInteractions[0].phase == .uncertain && !state.agentInteractions[0].canAnswer)
        controller.stop(); precondition(state.agentInteractions.isEmpty)
        try await nativeWireChecks()
        try await claudeWireChecks(state: state)
        try await codexHookChecks(state: state)
        print("AgentInteractionChecks: real isolated Codex owner wire, stale identity/receipt, no duplicate answer, Claude hook response/withdrawal, drafts and config preservation passed; no real agent message or approval sent")
    }

    /// A helper's process exit and its UI withdrawal are independent callbacks.
    /// Wait for both instead of racing a fixed number of yields or a one-second loop.
    @MainActor static func eventually(_ message: String, condition: () -> Bool) async throws {
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() && clock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard condition() else { fputs("AgentInteractionChecks timed out: " + message + "\n", stderr); exit(1) }
    }

    @MainActor static func nativeWireChecks() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cat-ipc-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString
        try Data("ready".utf8).write(to: root.appendingPathComponent("mode"))
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["Tests/Fixtures/codex-interaction-owner.py", root.path, id]
        process.standardOutput = pipe; process.standardError = FileHandle.standardError
        try process.run(); defer { process.terminate(); process.waitUntilExit() }
        precondition(!pipe.fileHandleForReading.availableData.isEmpty)
        let client = CodexDesktopPermissions(dataDirectory: root)
        let snapshot = try await client.fetch(threadIDs: [id])
        precondition(snapshot.pending.count == 1 && snapshot.observedThreadIDs == [id])
        let pending = snapshot.pending[0], question = pending.request.questions[0]
        let decision = PermissionDecision.answer([question.answerKey: .init(selected: ["摘要"])])
        try await client.resolve(decision, for: pending)
        let line = try String(contentsOf: root.appendingPathComponent("submitted.jsonl"))
        let wire = try JSONValue.parse(Data(line.utf8))
        let text = wire[cat: "params"][cat: "input"].catArray![0][cat: "text"].catString!
        precondition(text.contains("<send_user_message_question_reply>") && text.contains("questionItemId") && text.contains("摘要"))
        try Data("wrong-receipt".utf8).write(to: root.appendingPathComponent("mode"))
        do { try await client.resolve(decision, for: pending); preconditionFailure("wrong turn receipt must not confirm") }
        catch CodexDesktopIPC.Failure.acceptanceUncertain {}
        try Data("changed-owner".utf8).write(to: root.appendingPathComponent("mode"))
        do { try await client.resolve(decision, for: pending); preconditionFailure("owner change must reject") }
        catch CodexDesktopPermissions.Failure.noLongerWaiting {}
        try Data("answered".utf8).write(to: root.appendingPathComponent("mode"))
        do { try await client.resolve(decision, for: pending); preconditionFailure("withdrawn request must reject") }
        catch CodexDesktopPermissions.Failure.noLongerWaiting {}
        let submitted = try String(contentsOf: root.appendingPathComponent("submitted.jsonl"))
        precondition(submitted.split(separator: "\n").count == 2)
    }

    @MainActor static func claudeWireChecks(state: AppState) async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cat-hook-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = URL(fileURLWithPath: "dist/While AI Works.app/Contents/Resources/while-ai-works-agent-interaction")
        let file = root.appendingPathComponent("settings.json")
        let original: [String: Any] = ["env": ["TEST_GATEWAY": "retained"], "hooks": ["PermissionRequest": [["matcher": "Read", "hooks": [["type": "command", "command": "original-hook"]]]], "Stop": [["hooks": [["type": "command", "command": "status-hook"]]]]]]
        try JSONSerialization.data(withJSONObject: original).write(to: file)
        try AgentInteractionHookInstallation.configure(helper: helper, remove: false, file: file)
        precondition(AgentInteractionHookInstallation.isInstalled(at: file))
        try AgentInteractionHookInstallation.configure(helper: helper, remove: false, file: file)
        try AgentInteractionHookInstallation.configure(helper: helper, remove: true, file: file)
        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        precondition(NSDictionary(dictionary: restored).isEqual(to: original))
        let path = root.appendingPathComponent("sock").path
        let server = AgentInteractionHookServer(state: state, path: path)
        precondition(server.start()); defer { server.stop() }
        try await Task.sleep(for: .milliseconds(100))
        let payload: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": "fixture-claude", "cwd": "/fixture",
            "tool_name": "AskUserQuestion", "tool_input": ["questions": [["question": "选哪些？", "options": [["label": "A"], ["label": "B"]], "multiSelect": true]]]]
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = helper; process.arguments = ["--cat-interaction-hook", "claude"]
        var env = ProcessInfo.processInfo.environment; env["WHILE_AI_WORKS_INTERACTION_SOCKET"] = path; process.environment = env
        process.standardInput = input; process.standardOutput = output
        try process.run(); defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: payload)); try input.fileHandleForWriting.close()
        try await eventually("Claude hook request arrives") { !state.interactions(for: .claude).isEmpty }
        let request = state.interactions(for: .claude)[0].request
        let question = request.questions[0]
        server.answer(request.id, decision: .answer([question.answerKey: .init(selected: ["A", "B"], custom: "补充")]))
        try await eventually("hook exits and withdrawal reaches the app") { !process.isRunning && state.agentInteractions.isEmpty }
        precondition(!process.isRunning)
        let response = try JSONValue.parse(output.fileHandleForReading.readDataToEndOfFile())
        precondition(response[cat: "hookSpecificOutput"][cat: "decision"][cat: "updatedInput"][cat: "answers"][cat: "选哪些？"].catString == "A, B, 补充")
        precondition(state.interactions(for: .claude).isEmpty)
        // Whole unreadable questions are left to Claude, not partially answered.
        var malformed = payload; malformed["_catHubSource"] = "claude"; malformed["tool_input"] = ["questions": [["question": "bad", "options": [["description": "missing label"]]]]]
        let invalid = try AgentInteractionHookServer.parse(JSONSerialization.data(withJSONObject: malformed), id: "bad")
        precondition(invalid == nil)
        // An answer in the original client causes the helper to leave without a second answer.
        let transcript = root.appendingPathComponent("external.jsonl")
        let toolUse: [String: Any] = ["message": ["content": [["type": "tool_use", "id": "call1", "name": "Read", "input": ["file_path": "/fixture/example"]]]]]
        try (JSONSerialization.data(withJSONObject: toolUse) + Data([10])).write(to: transcript)
        let second = Process(), secondInput = Pipe(), secondOutput = Pipe()
        second.executableURL = helper; second.arguments = ["--cat-interaction-hook", "claude"]; second.environment = env
        second.standardInput = secondInput; second.standardOutput = secondOutput
        try second.run(); defer { if second.isRunning { second.terminate() }; second.waitUntilExit() }
        let external: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": "fixture-external", "cwd": "/fixture",
            "transcript_path": transcript.path, "tool_name": "Read", "tool_input": ["file_path": "/fixture/example"]]
        secondInput.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: external)); try secondInput.fileHandleForWriting.close()
        try await eventually("Claude hook request arrives") { !state.interactions(for: .claude).isEmpty }
        precondition(state.interactions(for: .claude).count == 1)
        let result: [String: Any] = ["message": ["content": [["type": "tool_result", "tool_use_id": "call1", "content": "done"]]]]
        let handle = try FileHandle(forWritingTo: transcript); try handle.seekToEnd()
        handle.write(try JSONSerialization.data(withJSONObject: result) + Data([10])); try handle.close()
        try await eventually("external Claude answer withdraws the request without another answer") { !second.isRunning && state.interactions(for: .claude).isEmpty }
        precondition(!second.isRunning && state.interactions(for: .claude).isEmpty && secondOutput.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }

    @MainActor static func codexHookChecks(state: AppState) async throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("cat-codex-hook-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = URL(fileURLWithPath: "dist/While AI Works.app/Contents/Resources/while-ai-works-agent-interaction")
        let transcript = root.appendingPathComponent("rollout.jsonl")
        let path = root.appendingPathComponent("sock").path
        let server = AgentInteractionHookServer(state: state, path: path)
        precondition(server.start()); defer { server.stop() }
        try await Task.sleep(for: .milliseconds(100))
        let payload: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": "fixture-codex-hook", "turn_id": "t1",
            "transcript_path": transcript.path, "tool_name": "Bash", "tool_input": ["command": "printf fixture"]]
        for reviewer in ["auto", "user"] {
            let context: [String: Any] = ["type": "turn_context", "payload": ["turn_id": "t1", "approvals_reviewer": reviewer]]
            try (JSONSerialization.data(withJSONObject: context) + Data([10])).write(to: transcript)
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = helper; process.arguments = ["--cat-interaction-hook", "codex"]
            var env = ProcessInfo.processInfo.environment; env["WHILE_AI_WORKS_INTERACTION_SOCKET"] = path; process.environment = env
            process.standardInput = input; process.standardOutput = output
            try process.run(); defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
            input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: payload)); try input.fileHandleForWriting.close()
            if reviewer == "user" {
                try await eventually("manual Codex review request arrives") { !state.interactions(for: .codex).isEmpty }
                let request = state.interactions(for: .codex)[0]
                precondition(request.viaHook && request.canAnswer)
                server.answer(request.id, decision: .deny)
            }
            try await eventually("hook exits and withdrawal reaches the app") { !process.isRunning && state.agentInteractions.isEmpty }
            precondition(!process.isRunning)
            let response = output.fileHandleForReading.readDataToEndOfFile()
            if reviewer == "auto" { precondition(response.isEmpty && state.interactions(for: .codex).isEmpty) }
            else {
                let json = try JSONValue.parse(response)
                precondition(json[cat: "hookSpecificOutput"][cat: "decision"][cat: "behavior"].catString == "deny")
            }
        }
    }
}
