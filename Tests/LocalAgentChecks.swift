import Foundation
import AppKit
import SQLite3
import AgentHUDCore
import AgentHUDSupport

@main enum LocalAgentChecks {
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--probe-dsh-health") {
            let node = DeepSeekLocator.nodeExecutable()
            let reader = LocalAgentReader()
            let value = await reader.read(sources: [.dsh], previews: false)
            precondition(node != nil && value.notices[.dsh] == nil && !value.sessions.isEmpty,
                         "DSH local records must decode with the actual process environment")
            print("DSH health: \(value.sessions.count) sessions decoded; no read error; Node \(node!.path)")
            return
        }
        if CommandLine.arguments.count == 3, ["--probe-dsh-root", "--probe-hermes-root"].contains(CommandLine.arguments[1]) {
            let source: WorkSource = CommandLine.arguments[1] == "--probe-hermes-root" ? .hermes : .dsh
            let reader = LocalAgentReader(environment: [source == .hermes ? "HERMES_HOME" : "DSH_HOME": CommandLine.arguments[2]])
            let value = await reader.read(sources: [source], previews: false)
            let rows = value.sessions.map { ["id": $0.id, "running": $0.running, "finished": $0.event == .finished,
                "input": $0.tokensIn, "output": $0.tokensOut] as [String: Any] }
            print(String(decoding: try JSONSerialization.data(withJSONObject: rows), as: UTF8.self)); return
        }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("WAW-local-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date(), hermes = home.appendingPathComponent(".hermes"), root = home.appendingPathComponent(".dsh")
        try FileManager.default.createDirectory(at: hermes, withIntermediateDirectories: true)
        var db: OpaquePointer?
        precondition(sqlite3_open(hermes.appendingPathComponent("state.db").path, &db) == SQLITE_OK)
        let sql = "CREATE TABLE sessions(id TEXT,title TEXT,cwd TEXT,source TEXT,started_at REAL,last_activity_at REAL,input_tokens INTEGER,output_tokens INTEGER,cache_read_tokens INTEGER,cache_write_tokens INTEGER,model_config TEXT); INSERT INTO sessions VALUES('fixture','Hermes test','/fixture','cli',\(now.timeIntervalSince1970),\(now.timeIntervalSince1970),100,20,50,10,'{}');"
        precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK); sqlite3_close(db)
        let first = try HermesLocalData.read(root: hermes, previews: false, now: now)
        precondition(first.sessions.count == 1 && first.sessions[0].tokensIn == 110 && first.sessions[0].cacheRead == 50)
        precondition(first.counts[.hermes] == 0 && first.sessions[0].event != .finished, "database activity is not a running/completed turn")
        var gateway: [String: Any] = ["gateway_state":"running","active_agents":2,"pid":getpid(),"start_time":LocalAgentProcess.start(getpid())!.timeIntervalSince1970 * 100,"updated_at":ISO8601DateFormatter().string(from: now)]
        func writeGateway() throws { try JSONSerialization.data(withJSONObject: gateway).write(to: hermes.appendingPathComponent("gateway_state.json")) }
        try writeGateway(); precondition(HermesLocalData.gatewayCount(folder: hermes, now: now) == 2)
        gateway["updated_at"] = "2000-01-01T00:00:00Z"; try writeGateway()
        precondition(HermesLocalData.gatewayCount(folder: hermes, now: now) == 2, "stale heartbeat alone cannot end a live Gateway task")
        gateway["active_agents"] = 0; try writeGateway(); precondition(HermesLocalData.gatewayCount(folder: hermes, now: now) == 0, "heartbeats never imply work")
        gateway["active_agents"] = 2; gateway["start_time"] = 1; try writeGateway(); precondition(HermesLocalData.gatewayCount(folder: hermes, now: now) == 0, "reused PID rejected")
        let folder = root.appendingPathComponent("sessions/project/session-fixture")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("session.v4.jsonl")
        let ms = now.timeIntervalSince1970 * 1000
        var events: [[String: Any]] = [["type":"session","version":4,"id":"fixture","createdAt":ms,"cwd":"/fixture","delegationDepth":0],
            ["type":"turn/start","seq":0,"time":ms,"data":["turn":1]],
            ["type":"step/start","seq":1,"time":ms+1,"data":["turn":1,"step":1]],
            ["type":"assistant/message","seq":2,"time":ms+2,"data":["turn":1,"step":1,"usage":["inputTokens":100,"outputTokens":20,"cacheReadTokens":50],"message":["content":[]]]],
            ["type":"turn/end","seq":3,"time":ms+3,"data":["turn":1,"reason":["kind":"completed"]]]]
        func writeEvents() throws { try events.map { try JSONSerialization.data(withJSONObject:$0) + Data([10]) }.reduce(Data(),+).write(to:path) }
        try writeEvents()
        let reader = LocalAgentReader(home: home, environment: [:])
        let read1 = await reader.read(sources:[.hermes,.dsh],previews:false,now:now.addingTimeInterval(1))
        let session = read1.sessions.first { $0.source == .dsh }!
        precondition(session.event == .finished && !session.running && session.tokensIn == 100 && session.cacheRead == 50)
        let read2 = await reader.read(sources:[.dsh],previews:false,now:now.addingTimeInterval(2))
        precondition(read2.sessions[0].tokensIn == 100, "repeated polls must not double count")
        events.append(["type":"turn/start","seq":4,"time":ms+4,"data":["turn":2]])
        try writeEvents()
        let read3 = await reader.read(sources:[.dsh],previews:false,now:now.addingTimeInterval(3))
        precondition(read3.sessions[0].event != .finished, "new turn clears completion")
        precondition(sqlite3_open(hermes.appendingPathComponent("state.db").path, &db) == SQLITE_OK)
        precondition(sqlite3_exec(db, "CREATE TABLE session_model_usage(session_id TEXT, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER); INSERT INTO session_model_usage VALUES('fixture',200,40,70,5); INSERT INTO session_model_usage VALUES('fixture',300,50,80,10);", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let modelUsage = try HermesLocalData.read(root: hermes, previews: false, now: now)
        precondition(modelUsage.sessions[0].tokensIn == 515 && modelUsage.sessions[0].tokensOut == 90 && modelUsage.sessions[0].cacheRead == 150, "model rows replace totals instead of double counting")
        let payload: [String: Any] = ["_catHubSource":"dsh","session_id":"deepseek:fixture","hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":["questions":[["id":"q1","question":"Which?","options":[["label":"A"],["label":"B"]]],["id":"q2","question":"Which?","options":[]]]]]
        let request = try AgentInteractionHookServer.parse(JSONSerialization.data(withJSONObject:payload),id:"fixture")!
        precondition(AgentInteraction(request:request,viaHook:true).source == .dsh)
        precondition(request.questions.map(\.answerKey) == ["q1","q2"], "identical display text retains native IDs")
        let answer = PermissionDecision.answer(["q1":.init(selected:["A"]),"q2":.init(custom:"free text")])
        precondition(AgentInteractionValidation.allows(answer,for:request))
        let response = try JSONSerialization.jsonObject(with:AgentInteractionHookServer.localResponse(answer,request:request)) as! [String:Any]
        precondition(response["action"] as? String == "answer" && (response["answers"] as? [[String:Any]])?.count == 2)
        precondition(!AgentInteractionValidation.allows(.allow,for:request))
        precondition(LocalAgentReader.resume(source:.dsh,id:"bad\nline",root:root) == nil)
        // Actual Node extension -> native Swift socket server -> structured reply.
        let suite = "WhileAIWorks.LocalAgentChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(defaults: defaults)
        state.desktopPetEnabled = true; state.agentInteractionsEnabled = true; state.selectedSources = [.dsh, .hermes]
        let socket = "/tmp/waw-" + String(UUID().uuidString.prefix(8)) + ".sock"
        let server = AgentInteractionHookServer(state: state, path: socket)
        precondition(server.start()); defer { server.stop() }
        try await Task.sleep(for: .milliseconds(100))
        let process = Process(), output = Pipe()
        process.executableURL = DeepSeekLocator.nodeExecutable()
        let plugin = URL(fileURLWithPath: "Sources/WhileAIWorks/Resources/LocalAgents/dsh/index.mjs").absoluteURL
        process.arguments = ["--input-type=module", "-e", "const {request} = await import(process.argv[1]); console.log(JSON.stringify(await request(JSON.parse(process.argv[2]))));", plugin.absoluteString,
            String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)]
        process.environment = ProcessInfo.processInfo.environment.merging(["WHILE_AI_WORKS_INTERACTION_SOCKET": socket], uniquingKeysWith: { _, new in new })
        process.standardOutput = output
        try process.run(); defer { if process.isRunning { process.terminate() } }
        for _ in 0..<100 where state.agentInteractions.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        precondition(state.agentInteractions.count == 1, "real extension reaches native request card")
        server.answer(state.agentInteractions[0].id, decision: answer)
        for _ in 0..<100 where process.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        precondition(!process.isRunning && process.terminationStatus == 0, "native reply returns to extension")
        let roundtrip = try JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as! [String: Any]
        precondition(roundtrip["action"] as? String == "answer" && state.agentInteractions.isEmpty)
        let cancelled = Process(), cancelledOutput = Pipe()
        cancelled.executableURL = process.executableURL; cancelled.environment = process.environment
        var args = process.arguments!
        args[2] = "const {request} = await import(process.argv[1]); const c = new AbortController(); setTimeout(() => c.abort(), 1500); console.log(JSON.stringify(await request(JSON.parse(process.argv[2]), c.signal)));"
        cancelled.arguments = args; cancelled.standardOutput = cancelledOutput
        try cancelled.run(); defer { if cancelled.isRunning { cancelled.terminate() } }
        for _ in 0..<100 where state.agentInteractions.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        precondition(state.agentInteractions.count == 1, "cancellable request arrives")
        for _ in 0..<150 where cancelled.isRunning || !state.agentInteractions.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        precondition(!cancelled.isRunning && state.agentInteractions.isEmpty, "client cancellation withdraws the native card without an answer")
        precondition(String(decoding: cancelledOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "null")
        print("PASS: Hermes SQLite/gateway identity/idle, DSH lifecycle/accounting/replay, native question IDs, response validation")
    }
}
