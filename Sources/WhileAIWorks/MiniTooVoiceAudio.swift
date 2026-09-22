import AppKit
@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import WhileCore

struct MiniTooAudioDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let objectID: AudioDeviceID
}

enum MiniTooAudioDevices {
    static let miniToo = "@minitoo"
    static let systemDefault = "@default"
    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func list(input: Bool) -> [MiniTooAudioDevice] {
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = address(kAudioDevicePropertyStreams, input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput)
            var count: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &count) == noErr, count > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            return MiniTooAudioDevice(id: uid, name: name, objectID: id)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector)
        var value: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
    static func resolve(_ uid: String, input: Bool) throws -> MiniTooAudioDevice {
        let choices = list(input: input)
        let found: MiniTooAudioDevice?
        if uid == miniToo { found = choices.first { $0.name.lowercased().contains("minitoo") } }
        else if uid == systemDefault {
            var property = address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
            var id: AudioDeviceID = 0; var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &id)
            found = choices.first { $0.objectID == id }
        } else { found = choices.first { $0.id == uid } }
        guard let found else { throw WorkAgentError.message("所选\(input ? "麦克风" : "扬声器")未连接，请刷新并重新选择音频设备。") }
        return found
    }
    static func use(_ device: MiniTooAudioDevice, on unit: AUAudioUnit) throws {
        // Configure the AVAudioEngine-owned unit through its v3 wrapper. Writing
        // the raw v2 property is overwritten when the engine initializes its
        // default aggregate device, which can route input back to a headset.
        do { try unit.setDeviceID(device.objectID) }
        catch { throw WorkAgentError.message("无法使用所选音频设备，请检查蓝牙连接。") }
    }
    static func remainsSelected(_ device: MiniTooAudioDevice, on unit: AUAudioUnit) -> Bool {
        let id = unit.deviceID
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard id == device.objectID else { return false }
        var property = address(kAudioDevicePropertyDeviceIsAlive); var alive: UInt32 = 0
        return AudioObjectGetPropertyData(id, &property, 0, nil, &size, &alive) == noErr && alive != 0
    }
}

/// Capture-thread state: 30-second recordings or a two-second streaming queue.
final class MiniTooCaptureBuffer {
    private let lock = NSLock()
    private var pcm = Data()
    private var active = true
    private var peak: Float = 0
    private var rms: Float = 0
    private var error: String?
    private let continuous: Bool
    private var totalFrames = 0
    let converter: AVAudioConverter
    let target: AVAudioFormat
    init(format: AVAudioFormat, continuous: Bool = false) throws {
        self.continuous = continuous
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else { throw WorkAgentError.message("麦克风格式不受支持。") }
        self.target = target; self.converter = converter
        pcm.reserveCapacity(SpeechPCM.inputRate * 2 * (continuous ? 2 : SpeechPCM.maxRecordingSeconds))
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        let limit = SpeechPCM.inputRate * 2 * (continuous ? 2 : SpeechPCM.maxRecordingSeconds)
        if pcm.count >= limit { if continuous { error = "实时收音积压，已停止。" }; return }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { error = "无法分配录音缓冲区。"; return }
        var fed = false; var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, state in
            if fed { state.pointee = .noDataNow; return nil }
            fed = true; state.pointee = .haveData; return buffer
        }
        guard status != .error, conversionError == nil, let samples = output.floatChannelData?[0] else { error = "麦克风采样转换失败。"; return }
        var sum: Float = 0
        let count = min(Int(output.frameLength), (limit - pcm.count) / 2)
        for index in 0..<count {
            let sample = samples[index].isFinite ? max(-1, min(1, samples[index])) : 0
            peak = max(peak, abs(sample)); sum += sample * sample
            let value = Int16((sample * 32767).rounded())
            pcm.append(UInt8(truncatingIfNeeded: value)); pcm.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        totalFrames += count
        if continuous && count < Int(output.frameLength) { error = "实时收音积压，已停止。" }
        rms = count > 0 ? sqrt(sum / Float(count)) : 0
    }
    func snapshot() -> (seconds: Double, level: Float, peak: Float, error: String?) {
        lock.lock(); defer { lock.unlock() }
        return (Double(totalFrames) / 16000, min(1, rms * 8), peak, error)
    }
    func takeFrame() -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard active, pcm.count >= 640 else { return nil }
        let frame = Data(pcm.prefix(640)); pcm = Data(pcm.dropFirst(640)); return frame
    }
    func stop(discard: Bool = false) -> Data {
        lock.lock(); defer { lock.unlock() }; active = false
        let result = discard ? Data() : pcm
        pcm.removeAll(keepingCapacity: false)
        return result
    }
}

/// AVCapture binds its input to a physical device UID; AVAudioEngine can
/// replace its input unit with a default aggregate during Bluetooth negotiation.
final class MiniTooCaptureReceiver: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let lock = NSLock()
    private var buffer: MiniTooCaptureBuffer?
    private var active = true
    private var failure: String?
    private let continuous: Bool
    init(continuous: Bool = false) { self.continuous = continuous; super.init() }
    func takeFrame() -> Data? { lock.lock(); defer { lock.unlock() }; return buffer?.takeFrame() }
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        consume(sample)
    }
    func consume(_ sample: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let format = AVAudioFormat(cmAudioFormatDescription: description) as AVAudioFormat?,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))) else {
            failure = "麦克风返回了不支持的音频格式。"; return
        }
        pcm.frameLength = pcm.frameCapacity
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(pcm.frameLength), into: pcm.mutableAudioBufferList) == noErr else {
            failure = "无法读取麦克风采样。"; return
        }
        do {
            if buffer == nil { buffer = try MiniTooCaptureBuffer(format: format, continuous: continuous) }
            buffer?.append(pcm)
        } catch { failure = "麦克风采样转换失败。" }
    }
    func snapshot() -> (seconds: Double, level: Float, peak: Float, error: String?) {
        lock.lock(); defer { lock.unlock() }
        if let failure { return (0, 0, 0, failure) }
        return buffer?.snapshot() ?? (0, 0, 0, nil)
    }
    func stop(discard: Bool) -> Data {
        lock.lock(); defer { lock.unlock() }; active = false
        return buffer?.stop(discard: discard) ?? Data()
    }
}

@MainActor final class MiniTooMicrophone {
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var receiver: MiniTooCaptureReceiver?
    private var device: AVCaptureDevice?
    private let controlQueue = DispatchQueue(label: "minitoo.microphone.control")
    private let sampleQueue = DispatchQueue(label: "minitoo.microphone.samples", qos: .userInitiated)
    func start(deviceUID: String, continuous: Bool = false) async throws -> String {
        stop(discard: true)
        let selected = try MiniTooAudioDevices.resolve(deviceUID, input: true)
        guard let device = AVCaptureDevice(uniqueID: selected.id), device.isConnected else {
            throw WorkAgentError.message("无法连接所选麦克风，请刷新音频设备后重试。")
        }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false]
        let receiver = MiniTooCaptureReceiver(continuous: continuous)
        output.setSampleBufferDelegate(receiver, queue: sampleQueue)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration(); throw WorkAgentError.message("所选麦克风无法创建收音通道。")
        }
        session.addInput(input); session.addOutput(output); session.commitConfiguration()
        self.session = session; self.output = output; self.receiver = receiver; self.device = device
        await withCheckedContinuation { continuation in
            controlQueue.async { session.startRunning(); continuation.resume() }
        }
        try Task.checkCancellation()
        guard self.session === session else { throw CancellationError() }
        guard session.isRunning else { throw WorkAgentError.message("麦克风启动失败，请检查设备或权限。") }
        return selected.name
    }
    func snapshot() throws -> (seconds: Double, level: Float, peak: Float) {
        guard let session, let device, session.isRunning, device.isConnected, let receiver else {
            throw WorkAgentError.message("麦克风已断开或采集已中断，录音已停止。")
        }
        let value = receiver.snapshot()
        if let error = value.error { throw WorkAgentError.message(error) }
        return (value.seconds, value.level, value.peak)
    }
    @discardableResult func stop(discard: Bool = false) -> Data {
        output?.setSampleBufferDelegate(nil, queue: nil)
        let pcm = receiver?.stop(discard: discard) ?? Data()
        if let session { controlQueue.async { session.stopRunning() } }
        session = nil; output = nil; receiver = nil; device = nil
        return pcm
    }
    func takeFrame() throws -> Data? {
        _ = try snapshot(); return receiver?.takeFrame()
    }
    func waitUntilStopped() async {
        await withCheckedContinuation { continuation in controlQueue.async { continuation.resume() } }
    }
}

@MainActor final class MiniTooSpeechPlayer {
    private let makeEngine: () -> AVAudioEngine
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var device: MiniTooAudioDevice?
    private var queuedFrames = 0
    private var generation = UUID()
    private var remainder = Data()
    private var recoveryAttempts: [TimeInterval] = []
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
    init(makeEngine: @escaping () -> AVAudioEngine = { AVAudioEngine() }) {
        self.makeEngine = makeEngine
    }
    func start(deviceUID: String) throws -> String {
        stop()
        let device = try MiniTooAudioDevices.resolve(deviceUID, input: false)
        let engine = makeEngine(); let node = AVAudioPlayerNode()
        try MiniTooAudioDevices.use(device, on: engine.outputNode.auAudioUnit)
        engine.attach(node); engine.connect(node, to: engine.mainMixerNode, format: format)
        node.volume = 0.65
        do { try engine.start() }
        catch { throw WorkAgentError.message("扬声器启动失败，请检查蓝牙连接。") }
        self.engine = engine; self.node = node; self.device = device
        node.play()
        return device.name
    }
    /// Bluetooth can change its playback format just after capture starts.
    /// Yield to configuration notifications and require a stable running period
    /// before starting the realtime sender's 20 ms deadline.
    func waitUntilReady(discardCapturedAudio: () throws -> Void) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        var stableSince = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - stableSince < 0.5 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if try check() { stableSince = ProcessInfo.processInfo.systemUptime }
            try discardCapturedAudio()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw WorkAgentError.message("蓝牙音频配置未稳定，请重新连接设备后再试。")
            }
        }
    }
    func enqueue(_ data: Data) async throws {
        try check()
        // Bound queued playback to roughly two seconds plus one provider chunk.
        let deadline = Date().addingTimeInterval(Double(queuedFrames) / 24000 + 8)
        while queuedFrames > 48_000 {
            try await Task.sleep(nanoseconds: 20_000_000); try check()
            guard Date() < deadline else { throw WorkAgentError.message("音频设备没有继续播放，已停止回复。") }
        }
        try append(data)
    }
    var hasQueuedAudio: Bool { queuedFrames > 0 }
    func enqueueRealtime(_ data: Data) throws {
        try check()
        guard queuedFrames + data.count / 2 <= 24000 * 15 else { throw WorkAgentError.message("播放积压超过 15 秒，已停止闲聊。") }
        try append(data)
    }
    func clearQueuedAudio() {
        generation = UUID(); node?.stop(); queuedFrames = 0; remainder.removeAll(); node?.play()
    }
    private func append(_ data: Data) throws {
        remainder.append(data)
        let frames = remainder.count / 2
        guard frames > 0, let node, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        for index in 0..<frames {
            let value = UInt16(remainder[index * 2]) | UInt16(remainder[index * 2 + 1]) << 8
            samples[index] = Float(Int16(bitPattern: value)) / 32768
        }
        remainder = Data(remainder.dropFirst(frames * 2))
        queuedFrames += frames
        let ticket = generation
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == ticket else { return }
                self.queuedFrames = max(0, self.queuedFrames - frames)
            }
        }
    }
    func drain() async throws {
        guard remainder.isEmpty else { throw WorkAgentError.message("语音音频包含不完整采样。") }
        let deadline = Date().addingTimeInterval(Double(queuedFrames) / 24000 + 8)
        while queuedFrames > 0 {
            try await Task.sleep(nanoseconds: 20_000_000); try check()
            guard Date() < deadline else { throw WorkAgentError.message("等待音频播放完成超时，已停止回复。") }
        }
        try check(); stop()
    }
    @discardableResult func check() throws -> Bool {
        try Task.checkCancellation()
        guard let engine, let device, MiniTooAudioDevices.remainsSelected(device, on: engine.outputNode.auAudioUnit) else {
            throw WorkAgentError.message("播放设备断开或路由改变，已停止语音回复。")
        }
        guard !engine.isRunning else { return false }
        // Only recover an idle engine on the SAME live device. Never silently
        // switch speakers or discard a response already scheduled for playback.
        guard queuedFrames == 0, remainder.isEmpty else {
            throw WorkAgentError.message("播放配置改变，当前语音回复已中断，请重新开始。")
        }
        let now = ProcessInfo.processInfo.systemUptime
        recoveryAttempts.removeAll { now - $0 > 10 }
        guard recoveryAttempts.count < 3 else {
            throw WorkAgentError.message("蓝牙音频配置反复变化，请重新连接设备后再试。")
        }
        recoveryAttempts.append(now)
        node?.stop()
        engine.disconnectNodeOutput(engine.mainMixerNode)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        do { try engine.start() }
        catch { throw WorkAgentError.message("无法恢复蓝牙播放，请重新连接设备后再试。") }
        guard MiniTooAudioDevices.remainsSelected(device, on: engine.outputNode.auAudioUnit) else {
            engine.stop()
            throw WorkAgentError.message("播放路由已改变，已停止语音回复。")
        }
        node?.play()
        NSLog("MiniToo audio: recovered idle playback engine after configuration change (attempt=%d)", recoveryAttempts.count)
        return true
    }
    func stop() {
        generation = UUID(); node?.stop(); engine?.stop()
        node = nil; engine = nil; device = nil; queuedFrames = 0; remainder.removeAll(); recoveryAttempts.removeAll()
    }
}
