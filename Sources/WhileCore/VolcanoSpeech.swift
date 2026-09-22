import Foundation

public struct VolcanoSpeechConfiguration: Equatable {
    public var resource: String
    public var speaker: String
    public init(resource: String = "seed-tts-2.0", speaker: String = "zh_female_vv_uranus_bigtts") {
        self.resource = resource; self.speaker = speaker
    }
    public func validate() throws {
        guard ["seed-tts-2.0", "seed-tts-1.0", "seed-tts-1.0-concurr"].contains(resource),
              !speaker.isEmpty, speaker.count <= 128,
              speaker.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw WorkAgentError.message("请检查语音合成资源与音色 ID。")
        }
    }
}

/// PCM16 mono audio is bounded and held in memory; no recording files are created.
public enum SpeechPCM {
    public static let inputRate = 16_000
    public static let outputRate = 24_000
    public static let maxRecordingSeconds = 30
    public static func wav(_ pcm: Data, sampleRate: Int = inputRate) throws -> Data {
        guard !pcm.isEmpty, pcm.count % 2 == 0, pcm.count <= inputRate * 2 * maxRecordingSeconds,
              [inputRate, outputRate].contains(sampleRate) else { throw WorkAgentError.message("录音为空、过长或格式不正确。") }
        var data = Data()
        func word(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func number(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        data.append(Data("RIFF".utf8)); number(UInt32(36 + pcm.count)); data.append(Data("WAVEfmt ".utf8))
        number(16); word(1); word(1); number(UInt32(sampleRate)); number(UInt32(sampleRate * 2)); word(2); word(16)
        data.append(Data("data".utf8)); number(UInt32(pcm.count)); data.append(pcm)
        return data
    }
}

/// A complete SSE data line yields audio, metadata or the terminal success marker.
public struct SpeechStreamDecoder {
    public enum Event: Equatable { case audio(Data), metadata, finished }
    public private(set) var finished = false
    public private(set) var audioBytes = 0
    public init() {}
    public mutating func consume(_ line: String) throws -> Event? {
        guard line.utf8.count <= 2_000_000 else { throw WorkAgentError.message("语音响应分块过大。") }
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("data:") else { return nil }
        guard !finished else { throw WorkAgentError.message("语音结束后收到异常数据。") }
        struct Chunk: Decodable { let code: Int; let data: String? }
        let payload = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
        guard let chunk = try? JSONDecoder().decode(Chunk.self, from: payload) else {
            throw WorkAgentError.message("语音响应格式不正确。")
        }
        if chunk.code == 20_000_000 {
            guard audioBytes > 0, audioBytes % 2 == 0 else { throw WorkAgentError.message("语音服务返回了空音频或不完整采样。") }
            finished = true; return .finished
        }
        guard chunk.code == 0 else { throw WorkAgentError.message("语音合成失败（服务码 \(chunk.code)），请检查资源、音色权限及额度。") }
        guard let encoded = chunk.data, !encoded.isEmpty else { return .metadata }
        guard let audio = Data(base64Encoded: encoded), !audio.isEmpty else { throw WorkAgentError.message("语音音频解码失败。") }
        audioBytes += audio.count
        guard audioBytes <= SpeechPCM.outputRate * 2 * 180 else { throw WorkAgentError.message("语音回复超过三分钟，已停止。") }
        return .audio(audio)
    }
    public func validateEnd() throws {
        guard finished else { throw WorkAgentError.message("语音连接提前结束，回复可能未播放完整。") }
    }
}

private final class SpeechNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public final class VolcanoSpeechClient {
    private let session: URLSession
    public init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 240
        config.urlCache = nil; config.httpCookieStorage = nil
        self.session = session ?? URLSession(configuration: config, delegate: SpeechNoRedirect(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    private static func request(path: String, key: String, resource: String, body: [String: Any]) throws -> URLRequest {
        guard key.count >= 8, key.count <= 512, !key.contains(where: { $0.isWhitespace }) else {
            throw WorkAgentError.message("请配置豆包语音 API Key，它与方舟模型 Key 分开保存。")
        }
        var request = URLRequest(url: URL(string: "https://openspeech.bytedance.com" + path)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        request.setValue(resource, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    private static func checkHTTP(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let response = response as? HTTPURLResponse else { throw WorkAgentError.message("未收到有效的语音服务响应。") }
        guard response.statusCode == 200 else {
            // Raw provider bodies/headers can echo credentials. Never display them.
            throw WorkAgentError.message("豆包语音 HTTP \(response.statusCode)：请检查语音 Key、服务开通、音色权限与额度。")
        }
        return response
    }
    public func transcribe(wav: Data, key: String) async throws -> String {
        guard wav.count > 44, wav.count <= SpeechPCM.inputRate * 2 * SpeechPCM.maxRecordingSeconds + 44,
              wav.prefix(4) == Data("RIFF".utf8) else { throw WorkAgentError.message("录音格式或长度不正确。") }
        var request = try Self.request(path: "/api/v3/auc/bigmodel/recognize/flash", key: key, resource: "volc.bigasr.auc_turbo",
            body: ["user": ["uid": "minitoo-work"], "audio": ["data": wav.base64EncodedString()],
                   "request": ["model_name": "bigmodel", "enable_itn": true, "enable_punc": true]])
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        let (data, raw) = try await session.data(for: request)
        try Task.checkCancellation()
        let response = try Self.checkHTTP(raw)
        return try Self.decodeTranscript(data, status: response.value(forHTTPHeaderField: "X-Api-Status-Code"))
    }
    public static func decodeTranscript(_ data: Data, status: String?) throws -> String {
        if status == "20000003" { throw WorkAgentError.message("没有识别到说话声，请检查收音设备后重试。") }
        guard status == "20000000" else {
            let code = status.flatMap(Int.init).map(String.init) ?? "未知"
            throw WorkAgentError.message("语音识别失败（服务码 \(code)），请检查语音服务权限。")
        }
        struct Result: Decodable { struct Text: Decodable { let text: String }; let result: Text }
        guard data.count <= 1_000_000, let decoded = try? JSONDecoder().decode(Result.self, from: data) else {
            throw WorkAgentError.message("语音识别返回格式不正确。")
        }
        let text = decoded.result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw WorkAgentError.message("没有识别到文字，请再说一次。") }
        guard text.count <= 4000 else { throw WorkAgentError.message("识别内容过长，请缩短这次录音。") }
        return text
    }
    public func speak(_ text: String, configuration: VolcanoSpeechConfiguration, key: String,
                      chunk: (Data) async throws -> Void) async throws {
        try configuration.validate()
        guard !text.isEmpty, text.count <= 1200 else { throw WorkAgentError.message("单次朗读需要 1–1200 字。") }
        let request = try Self.request(path: "/api/v3/tts/unidirectional/sse", key: key, resource: configuration.resource,
            body: ["user": ["uid": "minitoo-work"], "req_params": ["text": text, "speaker": configuration.speaker,
                "audio_params": ["format": "pcm", "sample_rate": SpeechPCM.outputRate]]])
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        _ = try Self.checkHTTP(response)
        var decoder = SpeechStreamDecoder()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let event = try decoder.consume(line) else { continue }
            switch event {
            case .audio(let audio): try await chunk(audio)
            case .finished: try decoder.validateEnd(); return
            case .metadata: break
            }
        }
        try decoder.validateEnd()
    }
}
