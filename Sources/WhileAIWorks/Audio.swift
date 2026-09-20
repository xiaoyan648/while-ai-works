import AppKit
import AVFoundation
import WhileCore

/// One continuous friction voice; prewarmed, reusable voices for individual impacts.
final class PlayAudio {
    static let shared = PlayAudio()
    var masterVolume: Float = 0.55
    private var friction = FrictionEnvelope()
    private var splashPlayer: AVAudioPlayer?
    private var bitePlayer: AVAudioPlayer?
    private var wipePlayer: AVAudioPlayer?
    private var popPlayers: [AVAudioPlayer] = []
    private var woodPlayers: [AVAudioPlayer] = []
    private var popIndex = 0
    private var woodIndex = 0
    private var timer: Timer?
    private var lastTick = ProcessInfo.processInfo.systemUptime

    private init() {
        splashPlayer = try? AVAudioPlayer(data: Self.splashWAV())
        splashPlayer?.prepareToPlay()
        bitePlayer = try? AVAudioPlayer(data: Self.biteWAV())
        bitePlayer?.prepareToPlay()
        wipePlayer = try? AVAudioPlayer(data: Self.frictionWAV())
        wipePlayer?.numberOfLoops = -1
        wipePlayer?.enableRate = true
        wipePlayer?.volume = 0
        wipePlayer?.prepareToPlay()
        for index in 0..<12 {
            if let player = try? AVAudioPlayer(data: Self.impactWAV(wood: false, variant: index)) {
                player.prepareToPlay(); popPlayers.append(player)
            }
            if let player = try? AVAudioPlayer(data: Self.impactWAV(wood: true, variant: index)) {
                player.prepareToPlay(); woodPlayers.append(player)
            }
        }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    deinit { timer?.invalidate() }
    func wipe(speed: Double, dirt: Double) {
        friction.move(speed: speed, dirt: dirt, now: ProcessInfo.processInfo.systemUptime)
    }
    func endWipe() { friction.release() }
    func pop(position: Double) {
        guard !popPlayers.isEmpty else { return }
        let player = popPlayers[popIndex % popPlayers.count]; popIndex += 1
        player.currentTime = 0
        player.volume = masterVolume * 0.58
        player.pan = Float(max(-1, min(1, position))) * 0.45
        player.play()
    }
    func wood(position: Double) {
        guard !woodPlayers.isEmpty else { return }
        let player = woodPlayers[woodIndex % woodPlayers.count]; woodIndex += 1
        player.currentTime = 0
        player.volume = masterVolume * 0.78
        player.pan = Float(max(-1, min(1, position))) * 0.3
        player.play()
    }
    func splash(position: Double) {
        splashPlayer?.currentTime = 0
        splashPlayer?.volume = masterVolume * 0.5
        splashPlayer?.pan = Float(max(-1, min(1, position))) * 0.4
        splashPlayer?.play()
    }
    func bite(position: Double) {
        bitePlayer?.currentTime = 0
        bitePlayer?.volume = masterVolume * 0.62
        bitePlayer?.pan = Float(max(-1, min(1, position))) * 0.4
        bitePlayer?.play()
    }
    /// One short water "plip" with a restrained bright overtone, distinct from bubble pops.
    static func biteWAV() -> Data {
        var samples: [Double] = []
        for i in 0..<12348 {
            let t = Double(i) / 44100.0
            let attack = 1.0 - exp(-t / 0.002)
            let phase = 2.0 * Double.pi * (610.0 * t - 680.0 * t * t)
            let drop = sin(phase) * exp(-t / 0.042) * 0.52
            let bell = sin(2.0 * Double.pi * 1320.0 * t) * exp(-t / 0.055) * 0.16
            samples.append(attack * (drop + bell))
        }
        return wav(samples)
    }
    static func splashWAV() -> Data {
        var rng = AudioRandom(seed: 8713)
        var low = 0.0
        var samples: [Double] = []
        for i in 0..<15435 {
            let t = Double(i) / 44100
            low += 0.16 * (rng.next() - low)
            let air = low * exp(-t / 0.055) * 1.5
            let phase: Double = 2.0 * Double.pi * (420.0 * t - 390.0 * t * t)
            let drop = sin(phase) * exp(-t / 0.035) * 0.24
            samples.append((1 - exp(-t / 0.004)) * (air + drop))
        }
        return wav(samples)
    }
    func stopAll() {
        splashPlayer?.stop()
        bitePlayer?.stop()
        friction = FrictionEnvelope()
        wipePlayer?.stop()
        wipePlayer?.volume = 0
        popPlayers.forEach { $0.stop() }
        woodPlayers.forEach { $0.stop() }
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        friction.tick(now: now, delta: min(0.1, now - lastTick))
        lastTick = now
        let volume = Float(friction.volume) * masterVolume
        if volume > 0.0002 {
            if wipePlayer?.isPlaying == false { wipePlayer?.play() }
            wipePlayer?.volume = volume
            wipePlayer?.rate = Float(friction.rate)
        } else if wipePlayer?.isPlaying == true {
            wipePlayer?.stop()
            wipePlayer?.volume = 0
        }
    }

    /// Filtered, smoothly looped noise: no repeated mini-impacts or new voices per drag.
    static func frictionWAV() -> Data {
        let count = 44_100 * 2
        var rng = AudioRandom(seed: 7351)
        var low = 0.0, slower = 0.0
        var samples = [Double](); samples.reserveCapacity(count)
        for i in 0..<count {
            let white = rng.next()
            low += 0.16 * (white - low)
            slower += 0.025 * (white - slower)
            let texture = low - slower + white * 0.055
            let t = Double(i) / 44_100
            let modulation = 0.86 + 0.08 * sin(2 * .pi * 7 * t) + 0.04 * sin(2 * .pi * 13 * t)
            samples.append(texture * modulation * 2.2)
        }
        // Blend the seam in a 20 ms region; keep the loop's level continuous.
        let overlap = 882
        for i in 0..<overlap {
            let mix = Double(i) / Double(overlap)
            samples[count - overlap + i] = samples[count - overlap + i] * (1 - mix) + samples[i] * mix
        }
        return wav(Array(samples.dropFirst(overlap)))
    }
    static func impactWAV(wood: Bool, variant: Int) -> Data {
        let duration = wood ? 0.45 : 0.115
        let count = Int(44_100 * duration)
        var rng = AudioRandom(seed: UInt64(variant + 1) * 8317)
        let variation = 0.96 + Double(variant % 7) * 0.013
        var samples = [Double](); samples.reserveCapacity(count)
        var low = 0.0
        for i in 0..<count {
            let t = Double(i) / 44_100
            let noise = rng.next()
            low += 0.28 * (noise - low)
            let attack = 1 - exp(-t / 0.00045)
            let sample: Double
            if wood {
                // Damped inharmonic resonances, plus the short wooden mallet contact.
                let f = 535 * variation
                let body = sin(2 * .pi * f * t) * exp(-t / 0.092) * 0.62
                    + sin(2 * .pi * f * 1.61 * t) * exp(-t / 0.056) * 0.28
                    + sin(2 * .pi * f * 2.73 * t) * exp(-t / 0.028) * 0.14
                    + sin(2 * .pi * f * 4.19 * t) * exp(-t / 0.012) * 0.075
                sample = attack * (body + low * exp(-t / 0.0045) * 0.9) * 0.68
            } else {
                let air = (noise - low) * exp(-t / 0.0031) * 0.55
                let pressure = sin(2 * .pi * variation * (340 * t - 1150 * t * t)) * exp(-t / 0.011) * 0.64
                let membrane = low * exp(-t / 0.021) * 0.38
                let crackle = noise * exp(-pow((t - 0.018) / 0.0018, 2)) * 0.07
                sample = attack * (air + pressure + membrane + crackle) * 0.72
            }
            samples.append(sample)
        }
        return wav(samples)
    }
    private static func wav(_ samples: [Double]) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            var value = Int16(max(-0.98, min(0.98, sample)) * 32767).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        var result = Data()
        func string(_ value: String) { result.append(contentsOf: value.utf8) }
        func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { result.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { result.append(contentsOf: $0) } }
        string("RIFF"); u32(UInt32(36 + pcm.count)); string("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(44_100); u32(88_200); u16(2); u16(16)
        string("data"); u32(UInt32(pcm.count)); result.append(pcm)
        return result
    }
}

private struct AudioRandom {
    var seed: UInt64
    mutating func next() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 11) / Double(UInt64.max >> 11) * 2 - 1
    }
}
