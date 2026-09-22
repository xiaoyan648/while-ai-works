import AppKit
import AVFoundation
import Combine
import WhileCore

@MainActor final class MiniTooVoice: ObservableObject {
    static let shared = MiniTooVoice()
    enum Phase { case idle, permission, recording, transcribing, answering, synthesizing, speaking }
    static let credentialAccount = "speech-api-key"
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = "点击开始说话，结束后发送"
    @Published private(set) var hasKey: Bool
    @Published private(set) var seconds: Double = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var inputs: [MiniTooAudioDevice] = []
    @Published private(set) var outputs: [MiniTooAudioDevice] = []
    @Published private(set) var configuration: VolcanoSpeechConfiguration
    @Published var inputUID: String { didSet { defaults.set(inputUID, forKey: "minitoo.voice.input") } }
    @Published var outputUID: String { didSet { defaults.set(outputUID, forKey: "minitoo.voice.output") } }
    @Published var readReplies: Bool { didSet { defaults.set(readReplies, forKey: "minitoo.voice.readReplies") } }
    var busy: Bool { phase != .idle }
    private let defaults: UserDefaults
    private let client = VolcanoSpeechClient()
    private let microphone = MiniTooMicrophone()
    private let player = MiniTooSpeechPlayer()
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var timer: Timer?
    private var startedAt = Date()
    private var testOnly = false
    private var sleepObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasKey = MiniTooAgentKeychain.exists(account: Self.credentialAccount)
        configuration = .init(resource: defaults.string(forKey: "minitoo.voice.resource") ?? "seed-tts-2.0",
                              speaker: defaults.string(forKey: "minitoo.voice.speaker") ?? "zh_female_vv_uranus_bigtts")
        inputUID = defaults.string(forKey: "minitoo.voice.input") ?? MiniTooAudioDevices.miniToo
        outputUID = defaults.string(forKey: "minitoo.voice.output") ?? MiniTooAudioDevices.miniToo
        readReplies = defaults.bool(forKey: "minitoo.voice.readReplies")
        refreshDevices()
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.cancel() } }
    }
    func refreshDevices() {
        inputs = MiniTooAudioDevices.list(input: true); outputs = MiniTooAudioDevices.list(input: false)
    }
    func configure(resource: String, speaker: String, newKey: String) throws {
        guard !busy, !MiniTooAgent.shared.running, !MiniTooRealtime.shared.active, !MiniTooRealtime.shared.closing else { throw WorkAgentError.message("请先停止当前任务。") }
        let value = VolcanoSpeechConfiguration(resource: resource, speaker: speaker.trimmingCharacters(in: .whitespacesAndNewlines))
        try value.validate()
        if !newKey.isEmpty { try MiniTooAgentKeychain.save(newKey.trimmingCharacters(in: .whitespacesAndNewlines), account: Self.credentialAccount) }
        configuration = value
        defaults.set(value.resource, forKey: "minitoo.voice.resource"); defaults.set(value.speaker, forKey: "minitoo.voice.speaker")
        hasKey = MiniTooAgentKeychain.exists(account: Self.credentialAccount)
        status = hasKey ? "语音配置已保存，Key 仅在本机钥匙串中" : "音色已保存，请配置豆包语音 Key"
    }
    func removeKey() throws {
        cancel(); try MiniTooAgentKeychain.remove(account: Self.credentialAccount)
        hasKey = false; readReplies = false; status = "已移除语音 Key，模型 Key 不受影响"
    }
    func startRecording(testOnly: Bool = false) {
        guard !busy, !MiniTooAgent.shared.running, !MiniTooRealtime.shared.active, !MiniTooRealtime.shared.closing else { return }
        if !testOnly && (!hasKey || !MiniTooAgent.shared.hasKey) { status = "请先配置模型 Key 和豆包语音 Key"; return }
        self.testOnly = testOnly
        seconds = 0; level = 0; phase = .permission; status = "正在准备麦克风…"
        let ticket = UUID(); generation = ticket
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                try Task.checkCancellation()
                guard self.generation == ticket else { return }
                guard allowed else { throw WorkAgentError.message("麦克风权限未允许。请在系统设置 → 隐私与安全性 → 麦克风中开启本应用。") }
                let name = try await self.microphone.start(deviceUID: self.inputUID)
                try Task.checkCancellation()
                guard self.generation == ticket else { return }
                self.phase = .recording; self.startedAt = Date()
                self.status = testOnly ? "本地收音测试 · \(name) · 不上传音频" : "正在听 · \(name) · 最多 30 秒"
                MiniTooAquarium.shared.setAgentActivity(.listening, detail: self.status)
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.tick() }
                }
            } catch { if self.generation == ticket { self.fail(error) } }
        }
    }
    private func tick() {
        guard phase == .recording else { return }
        do {
            let sample = try microphone.snapshot(); seconds = sample.seconds; level = sample.level
            if sample.seconds >= Double(SpeechPCM.maxRecordingSeconds) || Date().timeIntervalSince(startedAt) >= (testOnly ? 5 : 30) { finishRecording() }
        } catch { fail(error) }
    }
    func finishRecording() {
        guard phase == .recording else { return }
        timer?.invalidate(); timer = nil
        let sample = try? microphone.snapshot()
        let pcm = microphone.stop(); level = 0
        if testOnly {
            phase = .idle
            status = String(format: "本地收音测试结束 · %.1f 秒 · 峰值 %.3f · %@", sample?.seconds ?? 0, sample?.peak ?? 0,
                            (sample?.peak ?? 0) > 0.003 ? "收到声音，未上传" : "声音很弱，请检查麦克风")
            MiniTooAquarium.shared.setAgentActivity(.idle, detail: status)
            return
        }
        guard let sample, sample.seconds >= 0.3, sample.peak > 0.001 else {
            fail(WorkAgentError.message("录音太短或没有声音，请检查收音设备后重试。")); return
        }
        phase = .transcribing; status = "正在识别语音…"
        MiniTooAquarium.shared.setAgentActivity(.thinking, detail: status)
        let ticket = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let key = try MiniTooAgentKeychain.read(account: Self.credentialAccount)
                let text = try await self.client.transcribe(wav: SpeechPCM.wav(pcm), key: key)
                try Task.checkCancellation()
                guard self.generation == ticket else { return }
                self.phase = .idle; self.task = nil
                guard MiniTooAgent.shared.send(text, speakReply: true, fromVoice: true) else {
                    throw WorkAgentError.message("已识别语音，但模型未启动：" + MiniTooAgent.shared.status)
                }
            } catch { if self.generation == ticket { self.fail(error) } }
        }
    }
    func beginAnswer() { phase = .answering; status = "Agent 正在处理语音任务…" }
    func speak(_ fullText: String) async throws {
        let key = try MiniTooAgentKeychain.read(account: Self.credentialAccount)
        let text = String(fullText.prefix(1200))
        phase = .synthesizing; status = fullText.count > 1200 ? "回复较长，朗读前 1200 字…" : "正在合成语音回复…"
        MiniTooAquarium.shared.setAgentActivity(.thinking, detail: status)
        await microphone.waitUntilStopped()
        try Task.checkCancellation()
        let name = try player.start(deviceUID: outputUID)
        defer { player.stop() }
        var started = false
        try await client.speak(text, configuration: configuration, key: key) { [weak self] data in
            guard let self else { throw CancellationError() }
            try await self.player.enqueue(data)
            if !started {
                started = true; self.phase = .speaking; self.status = "正在说 · " + name
                MiniTooAquarium.shared.setAgentActivity(.speaking, detail: self.status)
            }
        }
        try await player.drain()
        phase = .idle; status = "语音播放完成"
    }
    func testSpeaker(cloud: Bool) {
        guard !busy, !MiniTooAgent.shared.running, !MiniTooRealtime.shared.active, !MiniTooRealtime.shared.closing else { return }
        let ticket = UUID(); generation = ticket
        phase = cloud ? .synthesizing : .speaking
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if cloud { try await self.speak("你好，我是你的 MiniToo 工作助手。语音回复已经连接。") }
                else {
                    await self.microphone.waitUntilStopped()
                    try Task.checkCancellation()
                    let name = try self.player.start(deviceUID: self.outputUID)
                    self.status = "测试提示音 · " + name
                    var pcm = Data()
                    for i in 0..<7200 {
                        let amplitude = sin(Double(i) / 24000 * 440 * .pi * 2) * sin(Double(i) / 7200 * .pi) * 0.12
                        let sample = Int16(amplitude * 32767)
                        pcm.append(UInt8(truncatingIfNeeded: sample)); pcm.append(UInt8(truncatingIfNeeded: sample >> 8))
                    }
                    try await self.player.enqueue(pcm); try await self.player.drain()
                    self.status = "提示音播放结束 · " + name
                }
                if self.generation == ticket { self.phase = .idle; self.task = nil; MiniTooAquarium.shared.setAgentActivity(.complete, detail: self.status) }
            } catch { if self.generation == ticket { self.fail(error) } }
        }
    }
    /// Also invoked by Agent cancellation; never recursively cancels the Agent.
    func stopAudio() {
        if busy { status = "语音已停止" }
        generation = UUID(); task?.cancel(); task = nil; timer?.invalidate(); timer = nil
        microphone.stop(discard: true); player.stop(); phase = .idle; level = 0
    }
    func cancel() {
        let wasBusy = busy
        stopAudio(); MiniTooAgent.shared.cancel()
        if wasBusy { status = "语音已停止，录音已丢弃"; MiniTooAquarium.shared.setAgentActivity(.idle, detail: status) }
    }
    func fail(_ error: Error) {
        stopAudio()
        status = error is CancellationError ? "语音已停止" : error.localizedDescription
        MiniTooAquarium.shared.setAgentActivity(.idle, detail: status)
    }
}
