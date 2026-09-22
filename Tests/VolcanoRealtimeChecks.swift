import Foundation
import WhileCore

@main enum VolcanoRealtimeChecks {
    static func main() throws {
        func event(_ object: [String: Any]) throws -> VolcanoRealtimeProtocol.Event {
            try VolcanoRealtimeProtocol.decode(JSONSerialization.data(withJSONObject: object))
        }
        let start = try VolcanoRealtimeProtocol.start(voice: VolcanoRealtimeProtocol.defaultVoice)
        let json = try JSONSerialization.jsonObject(with: Data(start.utf8)) as! [String: Any]
        let session = json["session"] as! [String: Any]
        precondition(json["type"] as? String == "session.create" && session["model"] as? String == "1.2.6.1")
        precondition(session["tools"] == nil, "chat must not expose computer tools")
        let audio = try event(["type":"response.output_audio.delta", "response_id":"response-a", "delta":Data([0,0,128,62,0,0,128,190]).base64EncodedString()])
        precondition(audio.audio == Data([0,32,0,224]) && audio.responseID == "response-a" && audio.text.isEmpty)
        for value in ["not base64", Data([1]).base64EncodedString(), ""] {
            do { _ = try event(["type":"response.output_audio.delta", "delta":value]); preconditionFailure() } catch {}
        }
        do {
            _ = try event(["type":"error", "error":["code":45000030,"message":"secret-echoed-by-provider"]]); preconditionFailure()
        } catch {
            precondition(error.localizedDescription.contains("45000030") && !error.localizedDescription.contains("secret-echoed"))
        }
        let text = try event(["type":"conversation.item.input_audio_transcription.completed","transcript":"你好"])
        precondition(text.text == "你好")
        let end = try event(["type":"session.closed"]); precondition(end.type == "session.closed")
        do { _ = try VolcanoRealtimeProtocol.start(voice: "bad\nvoice"); preconditionFailure() } catch {}
        print("VolcanoRealtimeChecks passed: session format, audio PCM validation, transcript, close and error redaction")
    }
}
