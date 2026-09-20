import Foundation
import AVFoundation

enum AudioFailure: Error { case invalid(String) }

@main enum NativeAudioChecks {
    static func main() throws {
        let sounds: [(String, Data, ClosedRange<Double>)] = [
            ("wipe", PlayAudio.frictionWAV(), 1.9...2.1),
            ("splash", PlayAudio.splashWAV(), 0.34...0.36),
            ("bite", PlayAudio.biteWAV(), 0.27...0.29),
            ("bubble", PlayAudio.impactWAV(wood: false, variant: 0), 0.10...0.13),
            ("woodfish", PlayAudio.impactWAV(wood: true, variant: 0), 0.44...0.46)
        ]
        let output = URL(fileURLWithPath: ".build/audio-checks")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, data, expectedDuration) in sounds {
            let decoded = try AVAudioPlayer(data: data)
            guard expectedDuration.contains(decoded.duration) else { throw AudioFailure.invalid("\(name): invalid duration") }
            let bytes = Array(data.dropFirst(44))
            var peak = 0.0, energy = 0.0
            for index in stride(from: 0, to: bytes.count - 1, by: 2) {
                let sample = Double(Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)) / 32768
                peak = max(peak, abs(sample)); energy += sample * sample
            }
            guard peak > 0.02, peak < 0.981, energy > 1 else { throw AudioFailure.invalid("\(name): silence or clipping") }
            if name != "wipe" {
                let last = Int16(bitPattern: UInt16(bytes[bytes.count - 2]) | UInt16(bytes[bytes.count - 1]) << 8)
                guard abs(Int(last)) < 400 else { throw AudioFailure.invalid("\(name): abrupt waveform ending") }
            }
            try data.write(to: output.appendingPathComponent("\(name).wav"))
        }
        guard PlayAudio.impactWAV(wood: false, variant: 0) != PlayAudio.impactWAV(wood: false, variant: 1) else {
            throw AudioFailure.invalid("bubble impacts must have variation")
        }
        print("NativeAudioChecks: WAV decoding, duration, non-silence, clipping, decay and variation passed.")
    }
}
