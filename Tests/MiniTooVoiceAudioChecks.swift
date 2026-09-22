import AVFoundation
import WhileCore

@main enum MiniTooVoiceAudioChecks {
    @MainActor static func main() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let capture = try MiniTooCaptureBuffer(format: format)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        for channel in 0..<2 {
            for i in 0..<4800 { buffer.floatChannelData![channel][i] = Float(sin(Double(i) / 48000 * 440 * 2 * .pi) * 0.25) }
        }
        for _ in 0..<10 { capture.append(buffer) }
        let sample = capture.snapshot()
        precondition(sample.error == nil && sample.seconds > 0.95 && sample.seconds <= 1.01)
        precondition(sample.peak > 0.1 && sample.peak < 0.6 && sample.level > 0.1)
        let pcm = capture.stop()
        precondition(pcm.count > 30000 && pcm.count <= 32200 && pcm.count % 2 == 0)
        capture.append(buffer); precondition(capture.stop().isEmpty, "stopped capture cannot collect more audio")
        let bounded = try MiniTooCaptureBuffer(format: format)
        for _ in 0..<310 { bounded.append(buffer) }
        precondition(bounded.snapshot().seconds == 30)
        precondition(bounded.stop(discard: true).isEmpty)
        let unavailable = "fixture-nonexistent-device"
        do { _ = try MiniTooAudioDevices.resolve(unavailable, input: true); preconditionFailure() } catch {}
        let player = MiniTooSpeechPlayer(); player.stop(); player.stop()
        // Exercise actual AVCapture sample-buffer conversion without opening a microphone.
        let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let values = [Float](repeating: 0.25, count: 1600)
        var block: CMBlockBuffer?
        precondition(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: values.count * 4, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: values.count * 4, flags: 0, blockBufferOut: &block) == noErr)
        let copied = values.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes.count)
        }
        precondition(copied == noErr)
        var audioSample: CMSampleBuffer?
        precondition(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
            dataBuffer: block!, formatDescription: sourceFormat.formatDescription, sampleCount: values.count,
            presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &audioSample) == noErr)
        let receiver = MiniTooCaptureReceiver()
        receiver.consume(audioSample!)
        let captured = receiver.snapshot()
        precondition(captured.error == nil && captured.seconds > 0.09 && captured.peak > 0.2)
        precondition(!receiver.stop(discard: false).isEmpty)
        receiver.consume(audioSample!)
        precondition(receiver.stop(discard: false).isEmpty, "late capture callbacks must not retain audio after stop")
        let live = try MiniTooCaptureBuffer(format: format, continuous: true)
        var delivered = 0
        for _ in 0..<400 {
            live.append(buffer)
            while let frame = live.takeFrame() { precondition(frame.count == 640); delivered += frame.count }
        }
        precondition(live.snapshot().seconds > 39 && live.snapshot().error == nil && delivered > 1_200_000,
                     "continuous capture must exceed 30 seconds without growing the pending buffer")
        _ = live.stop(discard: true); precondition(live.takeFrame() == nil)
        let slow = try MiniTooCaptureBuffer(format: format, continuous: true)
        for _ in 0..<30 { slow.append(buffer) }
        precondition(slow.snapshot().error != nil, "slow network must fail rather than retain unbounded audio")
        print("MiniTooVoiceAudioChecks passed: 48k stereo to 16k mono resampling, signal levels, 30-second memory cap, discard and missing device; no microphone opened")
        // Opt-in hardware regression: stop a real idle engine to reproduce the
        // configuration-change outcome. No microphone, cloud call or sound.
        if CommandLine.arguments.contains("--playback-device") {
            let output = try MiniTooAudioDevices.resolve(MiniTooAudioDevices.miniToo, input: false)
            var engine: AVAudioEngine!
            let recoveryPlayer = MiniTooSpeechPlayer(makeEngine: {
                let created = AVAudioEngine(); engine = created; return created
            })
            defer { recoveryPlayer.stop() }
            _ = try recoveryPlayer.start(deviceUID: output.id)
            for _ in 0..<3 {
                engine.stop()
                precondition(tryCheck(recoveryPlayer), "same-device idle interruption should recover")
                precondition(engine.isRunning)
                precondition(MiniTooAudioDevices.remainsSelected(output, on: engine.outputNode.auAudioUnit))
            }
            engine.stop()
            do { try recoveryPlayer.check(); preconditionFailure("recovery must be bounded") }
            catch { precondition(error.localizedDescription.contains("反复变化")) }
            _ = try recoveryPlayer.start(deviceUID: output.id)
            try recoveryPlayer.enqueueRealtime(Data(repeating: 0, count: 48000))
            engine.stop()
            do { try recoveryPlayer.check(); preconditionFailure("queued response must not be silently discarded") }
            catch { precondition(error.localizedDescription.contains("回复已中断")) }
            recoveryPlayer.stop()
            do { try recoveryPlayer.check(); preconditionFailure("stopped player cannot recover") } catch {}
            print("MiniToo playback device checks passed: 3 same-device recoveries, retry limit, queued-response interruption and explicit stop")
        }
    }
    @MainActor private static func tryCheck(_ player: MiniTooSpeechPlayer) -> Bool {
        do { return try player.check() } catch { preconditionFailure(error.localizedDescription) }
    }
}
