import AppKit
import AVFoundation
import Combine
import WhileCore

@MainActor final class MiniTooRealtime: ObservableObject {
    static let shared = MiniTooRealtime()
    static let credentialAccount = "realtime-api-key"
    @Published private(set) var active = false
    @Published private(set) var closing = false
    @Published private(set) var status = "开启后可以连续对话，说完自动回复"
    @Published private(set) var audioRoute = ""
    @Published private(set) var heard = ""
    @Published private(set) var reply = ""
    @Published private(set) var level: Float = 0
    @Published private(set) var hasOwnKey: Bool
    @Published var voiceID: String { didSet { defaults.set(voiceID, forKey: "minitoo.realtime.voice") } }
    @Published var allowInterruption: Bool { didSet { defaults.set(allowInterruption, forKey: "minitoo.realtime.interrupt") } }
    private let defaults: UserDefaults
    private let microphone = MiniTooMicrophone()
    private let player = MiniTooSpeechPlayer()
    private var client: VolcanoRealtimeClient?
    private var task: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var generation = UUID()
    private var responseID = ""
    private var ignoredResponses: [String] = []
    private var receivingAudio = false
    private var audioEnded = false
    private var resumeAt = Date.distantPast
    private var observer: NSObjectProtocol?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        voiceID = defaults.string(forKey: "minitoo.realtime.voice") ?? VolcanoRealtimeProtocol.defaultVoice
        allowInterruption = defaults.bool(forKey: "minitoo.realtime.interrupt")
        hasOwnKey = MiniTooAgentKeychain.exists(account: Self.credentialAccount)
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }
    func saveKey(_ value: String) throws {
        guard !active, !closing else { throw WorkAgentError.message("请先结束闲聊。") }
        if !value.isEmpty { try MiniTooAgentKeychain.save(value.trimmingCharacters(in: .whitespacesAndNewlines), account: Self.credentialAccount) }
        hasOwnKey = MiniTooAgentKeychain.exists(account: Self.credentialAccount)
        status = hasOwnKey ? "实时语音 Key 已保存" : "闲聊使用已保存的豆包语音 Key"
    }
    func removeKey() throws {
        guard !active, !closing else { throw WorkAgentError.message("请先结束闲聊。") }
        try MiniTooAgentKeychain.remove(account: Self.credentialAccount); hasOwnKey = false
        status = "闲聊使用已保存的豆包语音 Key"
    }
    func start() {
        guard !active, !closing, !MiniTooVoice.shared.busy, !MiniTooAgent.shared.running else { return }
        guard MiniTooAquarium.shared.enabled, MiniTooAquarium.shared.mode == .chat else { status = "请先开启 MiniToo 并选择闲聊模式"; return }
        guard !MiniTooAquarium.shared.busy else { status = "等待固定画面发送完成后即可开始闲聊"; return }
        let ticket = UUID(); generation = ticket
        active = true; heard = ""; reply = ""; status = "正在连接豆包实时语音…"
        MiniTooAquarium.shared.setRealtimeActive(true)
        ignoredResponses = []; responseID = ""; receivingAudio = false; audioEnded = false; resumeAt = .distantPast
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                try Task.checkCancellation()
                guard self.generation == ticket else { return }
                guard allowed else { throw WorkAgentError.message("请在系统设置中允许麦克风访问。") }
                let settings = MiniTooVoice.shared
                let inputDevice = try MiniTooAudioDevices.resolve(settings.inputUID, input: true)
                let outputDevice = try MiniTooAudioDevices.resolve(settings.outputUID, input: false)
                self.audioRoute = inputDevice.name + " 收音 → " + outputDevice.name + " 播放"
                let account = self.hasOwnKey ? Self.credentialAccount : MiniTooVoice.credentialAccount
                let key = try MiniTooAgentKeychain.read(account: account)
                let client = VolcanoRealtimeClient(); self.client = client
                let events = try client.connect(key: key, voice: self.voiceID)
                for try await event in events {
                    try Task.checkCancellation()
                    guard self.generation == ticket else { return }
                    if event.type == "session.created" {
                        self.status = "正在准备蓝牙收音和播放…"
                        _ = try await self.microphone.start(deviceUID: inputDevice.id, continuous: true)
                        try Task.checkCancellation()
                        guard self.generation == ticket else { return }
                        _ = try self.player.start(deviceUID: outputDevice.id)
                        try await self.player.waitUntilReady {
                            while try self.microphone.takeFrame() != nil {}
                        }
                        try Task.checkCancellation()
                        guard self.generation == ticket else { return }
                        self.setStatus("正在听 · 说完自动回复")
                        self.startSending(client: client, ticket: ticket)
                    } else { try self.handle(event) }
                }
                if self.generation == ticket { self.stop(message: "实时会话已结束") }
            } catch { if self.generation == ticket { self.stop(message: error.localizedDescription) } }
        }
    }
    private func startSending(client: VolcanoRealtimeClient, ticket: UUID) {
        sender = Task { [weak self] in
            var muted = false
            let clock = ContinuousClock()
            var deadline = clock.now
            var nextLevelUpdate = clock.now
            do {
                while !Task.isCancelled {
                    guard let self, self.generation == ticket else { return }
                    if try self.player.check() { deadline = clock.now }
                    let sample = try self.microphone.snapshot()
                    if clock.now >= nextLevelUpdate {
                        self.level = sample.level; nextLevelUpdate = clock.now + .milliseconds(100)
                    }
                    let frame = try self.microphone.takeFrame() ?? Data(repeating: 0, count: 640)
                    if self.audioEnded && !self.player.hasQueuedAudio {
                        self.audioEnded = false; self.receivingAudio = false; self.resumeAt = Date().addingTimeInterval(0.3)
                        self.setStatus("正在听 · 说完自动回复")
                    }
                    let pause = !self.allowInterruption && (self.receivingAudio || self.player.hasQueuedAudio || Date() < self.resumeAt)
                    if pause != muted {
                        try await client.send(pause ? "input_audio_mute.commit" : "input_audio_unmute.commit"); muted = pause
                    }
                    if !muted { try await client.send("input_audio_buffer.append", fields: ["audio": frame.base64EncodedString()]) }
                    deadline += .milliseconds(20)
                    // Never catch up by uploading a burst of old microphone frames.
                    if deadline < clock.now - .milliseconds(100) { throw WorkAgentError.message("实时音频发送延迟过大，已停止，请检查网络后重试。") }
                    try await clock.sleep(until: max(deadline, clock.now), tolerance: .milliseconds(2))
                }
            } catch { if let self, self.generation == ticket { self.stop(message: error.localizedDescription) } }
        }
    }
    private func handle(_ event: VolcanoRealtimeProtocol.Event) throws {
        switch event.type {
        case "conversation.item.input_audio_transcription.started":
            heard = ""
            if allowInterruption && (receivingAudio || player.hasQueuedAudio) { interrupt() }
            setStatus("正在听你说…")
        // The current service sends a revised cumulative hypothesis despite
        // naming the field "delta"; appending it duplicates every word.
        case "conversation.item.input_audio_transcription.delta": heard = String(event.text.suffix(4000))
        case "conversation.item.input_audio_transcription.completed":
            heard = event.text; reply = ""; setStatus("正在想…")
        case "response.output_text.delta":
            guard !ignoredResponses.contains(event.responseID) else { return }
            reply = String((reply + event.text).suffix(8000))
        case "response.output_text.done":
            if !ignoredResponses.contains(event.responseID) { reply = event.text }
        case "response.output_audio.started":
            guard !ignoredResponses.contains(event.responseID) else { return }
            responseID = event.responseID; receivingAudio = true; audioEnded = false
            setStatus("正在说 · 结束后继续听")
        case "response.output_audio.delta":
            guard !ignoredResponses.contains(event.responseID), let data = event.audio else { return }
            responseID = event.responseID; receivingAudio = true
            try player.enqueueRealtime(data)
        case "response.output_audio.done":
            if !ignoredResponses.contains(event.responseID) { audioEnded = true }
        case "response.canceled": player.clearQueuedAudio(); receivingAudio = false; audioEnded = false
        default: break
        }
    }
    func interrupt() {
        guard active, let client else { return }
        if !responseID.isEmpty { ignoredResponses.append(responseID); ignoredResponses = Array(ignoredResponses.suffix(32)) }
        player.clearQueuedAudio(); receivingAudio = false; audioEnded = false; resumeAt = Date().addingTimeInterval(0.3)
        setStatus("已打断，继续说吧")
        let ticket = generation
        Task { [weak self] in
            do { try await client.send("response.cancel") }
            catch { if self?.generation == ticket { self?.stop(message: "打断失败，请重新连接。") } }
        }
    }
    private func setStatus(_ text: String) {
        status = text
    }
    func stop(message: String = "闲聊已结束，麦克风已关闭") {
        guard active else { return }
        generation = UUID(); sender?.cancel(); sender = nil; task?.cancel(); task = nil
        microphone.stop(discard: true); player.stop(); level = 0; active = false
        MiniTooAquarium.shared.setRealtimeActive(false)
        setStatus(message)
        let old = client; client = nil; closing = old != nil
        Task { [weak self] in await old?.close(); self?.closing = false }
    }
}
