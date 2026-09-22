import Foundation
import WhileCore

final class ArkFixtureProtocol: URLProtocol {
    static var status = 200
    static var data = Data()
    static var inspect: ((URLRequest) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.inspect?(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main enum WorkAgentChecks {
    @MainActor static func main() async throws {
        func response(_ text: String = "完成", call: WorkAgentCall? = nil, finish: String = "stop") throws -> ArkAgentReply {
            var message: [String: Any] = ["content": text]
            if let call { message["tool_calls"] = [call.json] }
            return try ArkAgentClient.decode(JSONSerialization.data(withJSONObject: ["choices": [["message": message, "finish_reason": finish]]]))
        }
        func invalid(_ name: String, _ args: String) {
            do { _ = try WorkAgentAction.parse(.init(id: "x", name: name, arguments: args)); preconditionFailure("must reject \(name) \(args)") }
            catch {}
        }
        let desktopAction = try WorkAgentAction.parse(.init(id: "x", name: "set_desktop_game", arguments: "{\"enabled\":false}"))
        precondition(desktopAction == .desktop(false))
        invalid("run_shell", "{\"command\":\"anything\"}")
        invalid("set_desktop_game", "{\"enabled\":1}")
        invalid("set_desktop_game", "{\"enabled\":\"false\"}")
        invalid("get_app_status", "{\"extra\":true}")
        invalid("open_app", "{\"app\":\"Terminal\"}")
        invalid("set_minitoo_display", "{\"mode\":\"chat\",\"enabled\":true}")
        for url in ["file:///etc/passwd", "javascript:alert(1)", "http://example.com", "https://user:password@example.com", "https://127.0.0.1", "https://localhost", "https://a.local", "https://example.com:8080"] {
            let args = String(data: try JSONSerialization.data(withJSONObject: ["url": url]), encoding: .utf8)!
            invalid("open_webpage", args)
        }
        for input in [Data("{}".utf8), Data("not-json".utf8), Data("{\"choices\":[{\"message\":{\"content\":null}}]}".utf8)] {
            do { _ = try ArkAgentClient.decode(input); preconditionFailure("invalid response") } catch {}
        }
        do { _ = try response("partial", finish: "length"); preconditionFailure("truncation cannot be success") } catch {}

        let runner = WorkAgentRunner()
        var rounds = 0, executions = 0
        var events: [String] = []
        let answer = try await runner.run("查状态", complete: { messages in
            rounds += 1
            if rounds == 1 { return try response("", call: .init(id: "status-1", name: "get_app_status", arguments: "{}")) }
            precondition(messages.last?["role"] as? String == "tool")
            precondition(messages.last?["tool_call_id"] as? String == "status-1")
            precondition(messages.last?["content"] as? String == "fixture: desktop=false")
            return try response("桌面游戏已关闭")
        }, execute: { action in
            precondition(action == .appStatus); executions += 1; return "fixture: desktop=false"
        }, event: { events.append($0) })
        precondition(answer == "桌面游戏已关闭" && rounds == 2 && executions == 1 && events.count == 2)
        _ = try await runner.run("继续", complete: { messages in
            precondition(messages.count == 6 && messages[2]["role"] as? String == "assistant")
            return try response()
        }, execute: { _ in preconditionFailure() }, event: { _ in })

        runner.reset(); rounds = 0; executions = 0
        _ = try await runner.run("禁止工具测试", complete: { messages in
            rounds += 1
            if rounds == 1 { return try response("", call: .init(id: "bad-1", name: "run_shell", arguments: "{}")) }
            precondition((messages.last?["content"] as? String)?.contains("未提供") == true)
            return try response("无法执行")
        }, execute: { _ in executions += 1; return "never" }, event: { _ in })
        precondition(executions == 0)

        runner.reset(); rounds = 0; executions = 0
        do {
            _ = try await runner.run("循环限制", complete: { _ in
                rounds += 1
                return try response("", call: .init(id: "same-id", name: "get_app_status", arguments: "{}"))
            }, execute: { _ in executions += 1; return "fixture" }, event: { _ in })
            preconditionFailure("must stop loop")
        } catch {}
        precondition(rounds == 6 && executions == 1, "duplicate calls must not repeat side effects")

        executions = 0
        let cancelled = Task { @MainActor in
            try await runner.run("取消测试", complete: { _ in
                try await Task.sleep(nanoseconds: 100_000_000)
                return try response("", call: .init(id: "cancel-1", name: "set_desktop_game", arguments: "{\"enabled\":true}"))
            }, execute: { _ in executions += 1; return "never" }, event: { _ in })
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("must cancel") } catch {}
        precondition(executions == 0)
        _ = try await runner.run("取消后继续", complete: { messages in
            precondition(messages.count == 2, "failed/cancelled partial turns must not leak into context")
            return try response()
        }, execute: { _ in preconditionFailure() }, event: { _ in })

        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ArkFixtureProtocol.self]
        let client = ArkAgentClient(session: URLSession(configuration: config))
        let fixtureKey = "fixture-not-a-real-secret"
        ArkFixtureProtocol.inspect = { request in
            precondition(request.url?.host == "ark.cn-beijing.volces.com")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + fixtureKey)
        }
        ArkFixtureProtocol.status = 401
        ArkFixtureProtocol.data = Data("secret echo: \(fixtureKey)".utf8)
        do {
            _ = try await client.complete(configuration: .init(), key: fixtureKey, messages: [])
            preconditionFailure("401 must fail")
        } catch { precondition(!error.localizedDescription.contains(fixtureKey) && error.localizedDescription.contains("401")) }
        ArkFixtureProtocol.status = 200
        ArkFixtureProtocol.data = Data("{\"choices\":[{\"message\":{\"content\":\"连接成功\"},\"finish_reason\":\"stop\"}]}".utf8)
        let connected = try await client.complete(configuration: .init(), key: fixtureKey, messages: [], useTools: false)
        precondition(connected.text == "连接成功")
        print("WorkAgentChecks passed: strict tools, network errors/key redaction, multi-turn tools, cancellation, deduplication and loop limits")
    }
}
