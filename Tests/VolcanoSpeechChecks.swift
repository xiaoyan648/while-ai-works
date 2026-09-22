import Foundation
import WhileCore

final class SpeechFixtureProtocol: URLProtocol {
    static var code = 200
    static var headers: [String: String] = [:]
    static var parts: [Data] = []
    static var inspect: ((URLRequest) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.inspect?(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.code, httpVersion: nil, headerFields: Self.headers)!, cacheStoragePolicy: .notAllowed)
        for data in Self.parts { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main enum VolcanoSpeechChecks {
    static func expectFailure(_ body: () throws -> Void) {
        do { try body(); preconditionFailure("expected failure") } catch {}
    }
    static func main() async throws {
        let pcm = Data(repeating: 0, count: 32000)
        let wav = try SpeechPCM.wav(pcm)
        precondition(wav.count == 32044 && wav.prefix(4) == Data("RIFF".utf8))
        precondition(wav.subdata(in: 24..<28) == Data([0x80, 0x3e, 0, 0]))
        precondition(wav.suffix(pcm.count) == pcm)
        expectFailure { _ = try SpeechPCM.wav(Data()) }
        expectFailure { _ = try SpeechPCM.wav(Data([1])) }
        expectFailure { _ = try SpeechPCM.wav(Data(repeating: 0, count: 960002)) }
        expectFailure { try VolcanoSpeechConfiguration(speaker: "voice\r\ninvalid").validate() }
        expectFailure { try VolcanoSpeechConfiguration(resource: "https://example.com").validate() }
        var decoder = SpeechStreamDecoder()
        precondition(tryOptional(&decoder, "event: 352") == nil)
        let audio = Data([0, 0, 255, 127])
        let line = "data: {\"code\":0,\"data\":\"\(audio.base64EncodedString())\"}"
        let event = try decoder.consume(line)
        precondition(event == .audio(audio))
        let meta = try decoder.consume("data: {\"code\":0,\"data\":null,\"sentence\":{}}")
        precondition(meta == .metadata)
        let terminal = try decoder.consume("data: {\"code\":20000000,\"data\":null}")
        precondition(terminal == .finished); try decoder.validateEnd()
        expectFailure { _ = try decoder.consume(line) }
        expectFailure { var value = SpeechStreamDecoder(); _ = try value.consume("data: {\"code\":20000000}") }
        expectFailure { var value = SpeechStreamDecoder(); _ = try value.consume(line); try value.validateEnd() }
        expectFailure { var value = SpeechStreamDecoder(); _ = try value.consume("data: {\"code\":0,\"data\":\"!!\"}") }
        expectFailure { var value = SpeechStreamDecoder(); _ = try value.consume("data: {\"code\":0,\"data\":\"AA==\"}"); _ = try value.consume("data: {\"code\":20000000}") }
        let fixtureSecret = "fixture-key-do-not-echo"
        do {
            var value = SpeechStreamDecoder()
            _ = try value.consume("data: {\"code\":45000000,\"message\":\"\(fixtureSecret)\"}")
            preconditionFailure()
        } catch { precondition(!error.localizedDescription.contains(fixtureSecret)) }
        let transcript = Data("{\"result\":{\"text\":\"  查询当前任务。  \"}}".utf8)
        let text = try VolcanoSpeechClient.decodeTranscript(transcript, status: "20000000")
        precondition(text == "查询当前任务。")
        expectFailure { _ = try VolcanoSpeechClient.decodeTranscript(transcript, status: nil) }
        expectFailure { _ = try VolcanoSpeechClient.decodeTranscript(transcript, status: "20000003") }
        expectFailure { _ = try VolcanoSpeechClient.decodeTranscript(Data("{}".utf8), status: "20000000") }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SpeechFixtureProtocol.self]
        let client = VolcanoSpeechClient(session: URLSession(configuration: config))
        SpeechFixtureProtocol.inspect = { request in
            precondition(request.url?.host == "openspeech.bytedance.com")
            precondition(request.value(forHTTPHeaderField: "X-Api-Key") == fixtureSecret)
            precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
        }
        SpeechFixtureProtocol.headers = ["X-Api-Status-Code": "20000000"]
        SpeechFixtureProtocol.parts = [transcript]
        let recognised = try await client.transcribe(wav: wav, key: fixtureSecret)
        precondition(recognised == text)
        SpeechFixtureProtocol.code = 401
        SpeechFixtureProtocol.parts = [Data(fixtureSecret.utf8)]
        do { _ = try await client.transcribe(wav: wav, key: fixtureSecret); preconditionFailure() }
        catch { precondition(error.localizedDescription.contains("401") && !error.localizedDescription.contains(fixtureSecret)) }
        SpeechFixtureProtocol.code = 200
        SpeechFixtureProtocol.headers = ["Content-Type": "text/event-stream"]
        let stream = Data(("event: 352\n" + line + "\n\nevent: 152\ndata: {\"code\":20000000,\"data\":null}\n\n").utf8)
        // Network fragmentation across every UTF-8/JSON/base64 boundary.
        SpeechFixtureProtocol.parts = stream.map { Data([$0]) }
        var received = Data()
        try await client.speak("测试", configuration: .init(), key: fixtureSecret) { received.append($0) }
        precondition(received == audio)
        SpeechFixtureProtocol.parts = [Data((line + "\n").utf8)]
        do { try await client.speak("测试", configuration: .init(), key: fixtureSecret) { _ in }; preconditionFailure() }
        catch { precondition(error.localizedDescription.contains("提前结束")) }
        print("VolcanoSpeechChecks passed: WAV bounds, ASR status/silence, SSE fragmentation/terminal marker, malformed audio, HTTP errors and key redaction")
    }
    static func tryOptional(_ decoder: inout SpeechStreamDecoder, _ line: String) -> SpeechStreamDecoder.Event? { try! decoder.consume(line) }
}
