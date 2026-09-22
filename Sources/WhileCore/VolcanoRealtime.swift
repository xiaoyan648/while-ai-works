import Foundation

/// Doubao Seeduplex 3.0 JSON event protocol. No Agent tools are exposed by chat mode.
public enum VolcanoRealtimeProtocol {
    public static let endpoint = "wss://openspeech.bytedance.com/api/v3/duplex/realtime/dialogue"
    public static let defaultVoice = "zh_female_vv_jupiter_bigtts"
    public struct Event {
        public let type: String
        public let responseID: String
        public let text: String
        public let audio: Data?
    }
    public static func encode(_ type: String, fields: [String: Any] = [:]) throws -> String {
        var object = fields; object["type"] = type; object["event_id"] = UUID().uuidString
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    public static func start(voice: String) throws -> String {
        guard !voice.isEmpty, voice.count <= 128,
              voice.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw WorkAgentError.message("请填写正确的实时语音音色 ID。")
        }
        return try encode("session.create", fields: ["session": [
            "model": "1.2.6.1", "instructions": "你是 MiniToo，一个亲切自然的桌面聊天伙伴。用中文简短交流，每次通常一到三句话。你处于闲聊模式，没有电脑操作工具，不要声称执行过电脑操作。",
            "audio": ["input": ["format": ["type": "pcm", "rate": 16000]],
                      "output": ["format": ["type": "pcm", "rate": 24000], "voice": voice]]]])
    }
    public static func decode(_ data: Data) throws -> Event {
        guard data.count <= 2_000_000,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { throw WorkAgentError.message("实时语音返回了无效事件。") }
        if type == "error" || type == "conversation.item.input_audio_transcription.failed" {
            let error = object["error"] as? [String: Any] ?? object
            let raw = error["code"] ?? error["status_code"] ?? "未知"
            let code = String(describing: raw).filter { $0.isNumber || $0 == "-" }
            throw WorkAgentError.message("实时语音服务错误（\(code.isEmpty ? "未知" : code)），请检查实时语音 3.0 权限、音色和连接。")
        }
        var audio: Data?
        if type == "response.output_audio.delta" {
            guard let value = object["delta"] as? String, let decoded = Data(base64Encoded: value),
                  !decoded.isEmpty, decoded.count % 4 == 0 else { throw WorkAgentError.message("实时语音音频格式不正确。") }
            // With output format `pcm`, the live service returns Float32 LE
            // (as in the legacy TTS audio_config), even though the new guide
            // describes PCM16. Convert explicitly to our player's PCM16 format.
            var pcm = Data(); pcm.reserveCapacity(decoded.count / 2)
            for offset in stride(from: 0, to: decoded.count, by: 4) {
                let bits = UInt32(decoded[offset]) | UInt32(decoded[offset + 1]) << 8 |
                    UInt32(decoded[offset + 2]) << 16 | UInt32(decoded[offset + 3]) << 24
                let value = Float(bitPattern: bits)
                guard value.isFinite, abs(value) <= 1.01 else { throw WorkAgentError.message("实时音频采样异常，已停止播放。") }
                let sample = Int16((max(-1, min(1, value)) * 32767).rounded())
                pcm.append(UInt8(truncatingIfNeeded: sample)); pcm.append(UInt8(truncatingIfNeeded: sample >> 8))
            }
            audio = pcm
        }
        let text = (object["transcript"] ?? object["text"] ?? object["delta"]) as? String ?? ""
        return Event(type: type, responseID: object["response_id"] as? String ?? "", text: audio == nil ? String(text.prefix(8000)) : "", audio: audio)
    }
}

private final class RealtimeNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor public final class VolcanoRealtimeClient {
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var reader: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<VolcanoRealtimeProtocol.Event, Error>.Continuation?
    public init() {}
    public func connect(key: String, voice: String) throws -> AsyncThrowingStream<VolcanoRealtimeProtocol.Event, Error> {
        cancel()
        guard key.count >= 8, key.count <= 512, !key.contains(where: { $0.isWhitespace }) else { throw WorkAgentError.message("请配置豆包语音 API Key。") }
        let start = try VolcanoRealtimeProtocol.start(voice: voice)
        var request = URLRequest(url: URL(string: VolcanoRealtimeProtocol.endpoint)!)
        request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.urlCache = nil; config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: RealtimeNoRedirect(), delegateQueue: nil)
        let socket = session.webSocketTask(with: request); socket.maximumMessageSize = 2_000_000
        self.session = session; self.socket = socket
        let stream = AsyncThrowingStream<VolcanoRealtimeProtocol.Event, Error>(bufferingPolicy: .bufferingOldest(128)) { self.continuation = $0 }
        socket.resume()
        timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            guard let self, self.socket === socket else { return }
            self.continuation?.finish(throwing: WorkAgentError.message("实时语音连接超时，请检查网络和实时语音 3.0 权限。")); self.cancel()
        }
        reader = Task { [weak self] in
            do {
                try await socket.send(.string(start))
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let data: Data
                    switch message { case .string(let value): data = Data(value.utf8); case .data(let value): data = value; @unknown default: continue }
                    let event = try VolcanoRealtimeProtocol.decode(data)
                    guard let self, self.socket === socket else { return }
                    if event.type == "session.created" { self.timeout?.cancel(); self.timeout = nil }
                    if case .dropped = self.continuation?.yield(event) { throw WorkAgentError.message("实时语音接收积压，已停止，请重试。") }
                    if event.type == "session.closed" { self.continuation?.finish(); self.cancel(); return }
                }
            } catch {
                guard let self, self.socket === socket else { return }
                let status = (socket.response as? HTTPURLResponse)?.statusCode
                let safe: Error = error is WorkAgentError ? error : WorkAgentError.message(status.map { "实时语音连接失败（HTTP \($0)），请检查实时语音 3.0 服务权限。" } ?? "实时语音连接中断，请重新开始闲聊。")
                self.continuation?.finish(throwing: safe); self.cancel()
            }
        }
        return stream
    }
    public func send(_ type: String, fields: [String: Any] = [:]) async throws {
        guard let socket else { throw WorkAgentError.message("实时语音尚未连接。") }
        try Task.checkCancellation()
        try await socket.send(.string(VolcanoRealtimeProtocol.encode(type, fields: fields)))
    }
    public func close() async {
        guard let socket else { return }
        // Bound even the close write: a stalled network must not leave the UI
        // in the closing state while URLSession waits for its request timeout.
        let deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            if self?.socket === socket { self?.cancel() }
        }
        defer { deadline.cancel() }
        try? await send("session.close")
        // Reader remains active for the server's session.closed acknowledgement.
        for _ in 0..<40 {
            if self.socket !== socket { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if self.socket === socket { cancel() }
    }
    public func cancel() {
        timeout?.cancel(); timeout = nil; reader?.cancel(); reader = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
        continuation?.finish(); continuation = nil
    }
}
