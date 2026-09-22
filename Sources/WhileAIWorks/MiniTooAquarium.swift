import AppKit
import Combine
import IOBluetooth
import CoreBluetooth
import WhileCore

/// Main-run-loop RFCOMM state machine. No network service or external runtime.
final class MiniTooAquarium: NSObject, ObservableObject, IOBluetoothRFCOMMChannelDelegate, CBCentralManagerDelegate {
    static let shared = MiniTooAquarium()
    enum Mode: String, CaseIterable { case aquarium, codex, work, chat
        var title: String {
            switch self { case .aquarium: return "鱼缸"; case .codex: return "Codex"; case .work: return "工作模式"; case .chat: return "闲聊模式" }
        }
    }
    @Published private(set) var mode: Mode
    @Published private(set) var companionPreviewState: MiniTooCompanionArtwork.State = .idle
    @Published private(set) var agentActivityDetail: String?
    @Published private(set) var preview = MiniTooArtwork.frame(0)
    @Published private(set) var page = 0
    @Published private(set) var pageCount = 1
    @Published private(set) var contentDetail = "同步水下观赏中入住的鱼"
    private var fishIDs: [String] = []
    private var fish: [MiniTooArtwork.Fish] = []
    private var snapshot = CodexDisplay()
    private var contentTimer: Timer?
    private var started = false
    private var sleeping = false
    private var lastSentKey: String?
    private var previewKey: String?
    private var screenAwake = false
    private var chunkDelay: TimeInterval = 0.005
    private var prepareStarted = 0.0
    private var transferStarted = 0.0
    private var preparedMS = 0.0
    private var payloadBytes = 0
    private var lastProgress = 0.0
    private var uploadKey = ""
    private var uploadMode: Mode = .aquarium
    enum Phase { case idle, preparing, connecting, waiting, sending, confirming, displaying, stopping, failed }
    @Published private(set) var enabled: Bool
    @Published private(set) var realtimeActive = false
    @Published private(set) var status = "开启后，将所选内容发送到 MiniToo"
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var deviceName = "Divoom MiniToo"
    var busy: Bool { [.preparing, .connecting, .waiting, .sending, .confirming, .stopping].contains(phase) }
    var canRetry: Bool { enabled && !busy && !realtimeActive }
    private let defaults: UserDefaults
    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private var decoder = MiniTooProtocol.Decoder()
    private var packets: [Data] = []
    private var outgoing: [Data] = []
    private var writeBuffer: NSData?
    private var writeSequence = 0
    private var pendingWrite: Int?
    private var handshakeAttempts = 0
    private var deadline: Timer?
    private var pacing: Timer?
    private var generation = 0
    private var confirmed = false
    private var uploaded = 0
    private var cachedAquarium: (key: String, payload: Data)?
    private var cachedCompanion: [MiniTooCompanionArtwork.State: Data] = [:]
    private var bluetooth: CBCentralManager?
    private var pendingPayload: Data?
    private var observers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "minitoo.aquarium.enabled")
        mode = Mode(rawValue: defaults.string(forKey: "minitoo.mode") ?? "") ?? .aquarium
        super.init()
        // Construction never connects; app lifecycle explicitly starts the controller.
    }
    func start() {
        guard !started else { return }
        started = true
        contentTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.enabled, self.mode == .codex else { return }
            self.refreshPreview(); self.pump()
        }
        if observers.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.sleeping = true
                self.resetTransport()
                self.phase = .idle
                if self.enabled { self.status = "Mac 已休眠，唤醒后重新连接" }
            })
            observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.sleeping = false
                if self.enabled { self.retry() }
            })
        }
        if enabled { retry() }
    }
    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        defaults.set(value, forKey: "minitoo.aquarium.enabled")
        if value { retry() } else { stopDisplay() }
    }
    func setMode(_ value: Mode) {
        guard mode != value else { return }
        mode = value; defaults.set(value.rawValue, forKey: "minitoo.mode")
        page = 0; refreshPreview(); pump()
    }
    func setCompanionPreview(_ value: MiniTooCompanionArtwork.State) {
        guard mode != .chat else { return }
        guard value != companionPreviewState || agentActivityDetail != nil else { return }
        agentActivityDetail = nil
        companionPreviewState = value
        if mode == .work || mode == .chat { refreshPreview(); pump() }
    }
    func setAgentActivity(_ value: MiniTooCompanionArtwork.State, detail: String) {
        guard mode != .chat else { return }
        companionPreviewState = value; agentActivityDetail = detail
        if mode == .work || mode == .chat { refreshPreview(); pump() }
    }
    func setRealtimeActive(_ value: Bool) {
        realtimeActive = value
        if !value { pump() }
    }
    func updateFish(_ ids: [String]) {
        guard ids != fishIDs else { return }
        fishIDs = ids; fish = MiniTooArtwork.loadFish(ids)
        if mode == .aquarium { refreshPreview(); pump() }
    }
    func updateCodex(_ value: CodexDisplay) {
        snapshot = value
        let pages = max(1, (value.sessions.count + 2) / 3)
        if pageCount != pages { pageCount = pages }
        if page >= pageCount { page = pageCount - 1 }
        if mode == .codex { refreshPreview(); pump() }
    }
    func changePage(_ delta: Int) {
        page = max(0, min(pageCount - 1, page + delta))
        refreshPreview(); pump()
    }
    private func refreshPreview() {
        if mode == .aquarium {
            let key = "fish:" + fishIDs.joined(separator: ",")
            if previewKey != key { preview = MiniTooArtwork.frame(0, fish: fish); previewKey = key }
            let names = fishIDs.compactMap { id in CatchSpecies.catalog.first { $0.id == id }?.name }
            var detail = names.isEmpty ? "与水下观赏同步 · 暂无入住的鱼" : "水下观赏 · " + names.joined(separator: "、")
            if fish.count != fishIDs.count { detail += "（部分素材缺失）" }
            if contentDetail != detail { contentDetail = detail }
        } else if mode == .chat {
            if previewKey != "chat-static" {
                preview = MiniTooCompanionArtwork.frame(.idle, index: 0); previewKey = "chat-static"
            }
            contentDetail = "闲聊保持固定画面 · 对话期间不上传动画"
        } else if mode == .work {
            let key = "work-preview:" + companionPreviewState.rawValue
            if previewKey != key {
                preview = MiniTooCompanionArtwork.frame(companionPreviewState, index: 0); previewKey = key
            }
            let detail = agentActivityDetail.map { $0 + "\n语音模式 · 详情见控制面板。" } ??
                "角色动作预览 · \(companionPreviewState.title)\n动作预览不会收音或调用 Agent。"
            if contentDetail != detail { contentDetail = detail }
        } else {
            let dashboard = MiniTooArtwork.dashboardPage(snapshot, page: page)
            let key = "codex:" + dashboard.key
            if previewKey != key { preview = MiniTooArtwork.dashboard(dashboard); previewKey = key }
            let number = snapshot.sessions.count
            var detail = "本机近期会话 \(number) 个 · 编号在本次应用运行中保持不变"
            if let date = snapshot.quotaUpdatedAt {
                let formatter = DateFormatter(); formatter.dateFormat = "MM-dd HH:mm"
                detail += "\n额度更新 " + formatter.string(from: date)
                for quota in snapshot.quotas {
                    if let reset = quota.resetsAt { detail += " · \(quota.label)重置 " + formatter.string(from: reset) }
                }
            }
            if contentDetail != detail { contentDetail = detail }
        }
    }
    func retry() {
        guard enabled, !realtimeActive else { return }
        if !started { start(); return }
        guard !busy else { return }
        if phase == .failed { chunkDelay = 0.02; resetTransport(); phase = .idle }
        lastSentKey = nil
        refreshPreview(); pump()
    }
    /// One transfer at a time. Changes during an upload are coalesced into the
    /// latest snapshot and sent only after its final ACK; modes never interleave.
    private func pump() {
        guard started, enabled, !sleeping, !busy, !realtimeActive, phase != .failed else { return }
        let chosenMode = mode
        let chosenFish = fish
        let chosenCompanion = companionPreviewState
        let dashboard = MiniTooArtwork.dashboardPage(snapshot, page: page)
        let key: String
        switch chosenMode {
        case .aquarium: key = "fish:" + fishIDs.joined(separator: ",")
        case .codex: key = "codex:" + dashboard.key
        case .work: key = "work-preview:" + chosenCompanion.rawValue
        case .chat: key = "chat-static"
        }
        guard key != lastSentKey else { return }
        resetTransport(closeChannel: channel?.isOpen() != true)
        uploadKey = key; uploadMode = chosenMode
        prepareStarted = ProcessInfo.processInfo.systemUptime
        phase = .preparing; status = "正在准备\(chosenMode.title)画面…"
        let ticket = generation
        let cached = chosenMode == .work ? cachedCompanion[chosenCompanion] :
            (chosenMode == .aquarium && cachedAquarium?.key == key ? cachedAquarium?.payload : nil)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { () throws -> Data in
                if let cached { return cached }
                if chosenMode == .aquarium { return try MiniTooArtwork.payload(fish: chosenFish) }
                if chosenMode == .work { return try MiniTooCompanionArtwork.payload(chosenCompanion) }
                if chosenMode == .chat { return try MiniTooCompanionArtwork.chatPayload() }
                return MiniTooProtocol.animation(jpegs: [try MiniTooArtwork.jpeg(MiniTooArtwork.dashboard(dashboard))], milliseconds: 1000)
            }
            DispatchQueue.main.async {
                guard let self, self.generation == ticket, self.enabled else { return }
                switch result {
                case .success(let payload):
                    self.preparedMS = (ProcessInfo.processInfo.systemUptime - self.prepareStarted) * 1000
                    self.payloadBytes = payload.count
                    if chosenMode == .aquarium { self.cachedAquarium = (key, payload) }
                    if chosenMode == .work { self.cachedCompanion[chosenCompanion] = payload }
                    if self.channel?.isOpen() == true {
                        self.packets = MiniTooProtocol.upload(payload); self.beginUpload()
                    } else { self.connect(payload: payload) }
                case .failure: self.fail("画面生成失败，请重试")
                }
            }
        }
    }
    private func connect(payload: Data) {
        pendingPayload = payload
        phase = .connecting; status = "等待蓝牙授权，请在系统弹窗中允许…"
        armTimeout(60, "请在系统设置 → 隐私与安全性 → 蓝牙中允许本应用，然后重试")
        // Request permission asynchronously before touching the Classic-Bluetooth shim.
        if let bluetooth { centralManagerDidUpdateState(bluetooth) }
        else { bluetooth = CBCentralManager(delegate: self, queue: .main) }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard enabled, phase == .connecting, let payload = pendingPayload else { return }
        switch central.state {
        case .poweredOn:
            pendingPayload = nil
            findDevice(payload: payload)
        case .unauthorized:
            fail("请在系统设置 → 隐私与安全性 → 蓝牙中允许本应用，然后重试")
        case .poweredOff: fail("Mac 蓝牙已关闭，请打开蓝牙后重试")
        case .unsupported: fail("这台 Mac 的蓝牙不可用")
        default: break
        }
    }
    private func findDevice(payload: Data) {
        phase = .connecting; status = "正在查找已配对的 MiniToo…"
        armTimeout(20, "蓝牙初始化超时，请检查系统设置中的蓝牙权限后重试")
        let ticket = generation
        // First IOBluetooth use waits for CoreBluetooth initialization, which itself
        // needs the main queue. Calling pairedDevices there can deadlock macOS.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
            DispatchQueue.main.async {
                guard let self, self.enabled, self.generation == ticket else { return }
                self.open(payload: payload, devices: devices)
            }
        }
    }
    private func open(payload: Data, devices: [IOBluetoothDevice]) {
        let matches = devices.filter {
            let name = ($0.name ?? "").lowercased()
            return name.contains("divoom") && name.contains("minitoo") && name.contains("audio")
        }
        let connected = matches.filter { $0.isConnected() }
        let preferred = defaults.string(forKey: "minitoo.aquarium.address")
        let target = connected.count == 1 ? connected.first : matches.first { $0.addressString == preferred }
            ?? (matches.count == 1 ? matches.first : nil)
        guard let target else {
            fail(matches.isEmpty ? "未找到 MiniToo，请先在 Mac 蓝牙设置中配对 MiniToo-Audio，再点重试" : "有多台 MiniToo，请只连接要展示的那台，再点重试")
            return
        }
        device = target; deviceName = target.name ?? "Divoom MiniToo"
        defaults.set(target.addressString, forKey: "minitoo.aquarium.address")
        packets = MiniTooProtocol.upload(payload)
        phase = .connecting; status = "正在连接 \(deviceName)…"
        armTimeout(15, "连接超时，请断开手机上的 Divoom 连接后重试")
        var opened: IOBluetoothRFCOMMChannel?
        let result = target.openRFCOMMChannelAsync(&opened, withChannelID: 1, delegate: self)
        guard result == kIOReturnSuccess, let opened else {
            fail("蓝牙控制连接失败（\(result)），请在 Mac 蓝牙中断开再重连，然后重试")
            return
        }
        channel = opened
    }
    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        guard let rfcommChannel, rfcommChannel === channel, phase == .connecting, enabled else { return }
        guard error == kIOReturnSuccess else { fail("蓝牙控制通道不可用（\(error)），请断开手机连接后重试"); return }
        beginUpload()
    }
    private func beginUpload() {
        transferStarted = ProcessInfo.processInfo.systemUptime
        handshakeAttempts = 1
        phase = .waiting; status = "已连接，等待 MiniToo 接收画面…"
        armTimeout(8, "MiniToo 未回应，请退出手机 Divoom App 后重试")
        outgoing = screenAwake ? [packets[0]] : [MiniTooProtocol.screen(true), packets[0]]
        writeNext()
    }
    private func writeNext() {
        guard writeBuffer == nil, let channel, channel.isOpen(), !outgoing.isEmpty else { return }
        let next = outgoing.removeFirst()
        // RFCOMM is a byte stream; fragment at its negotiated MTU if necessary.
        let mtu = max(1, Int(channel.getMTU()))
        let part = Data(next.prefix(mtu))
        if next.count > mtu { outgoing.insert(Data(next.dropFirst(mtu)), at: 0) }
        let buffer = part as NSData
        writeBuffer = buffer
        writeSequence += 1; pendingWrite = writeSequence
        let result = channel.writeAsync(UnsafeMutableRawPointer(mutating: buffer.bytes), length: UInt16(buffer.length),
                                        refcon: UnsafeMutableRawPointer(bitPattern: writeSequence))
        if result != kIOReturnSuccess { fail("画面发送失败（\(result)），请重试") }
    }
    func rfcommChannelWriteComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn, bytesWritten length: Int) {
        rfcommChannelWriteComplete(rfcommChannel, refcon: refcon, status: error)
    }
    // macOS may call the legacy three-argument delegate selector even though the
    // newer four-argument variant appears in the same SDK. Support both.
    func rfcommChannelWriteComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn) {
        guard rfcommChannel === channel, writeBuffer != nil,
              pendingWrite == Int(bitPattern: refcon) else { return }
        writeBuffer = nil; pendingWrite = nil
        guard error == kIOReturnSuccess else { fail("蓝牙写入失败（\(error)），请重试"); return }
        if phase == .sending {
            uploaded += 1
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastProgress >= 0.1 {
                lastProgress = now
                status = "正在发送\(uploadMode.title)画面 · \(min(99, uploaded * 100 / max(1, packets.count - 1)))%"
            }
        }
        if !outgoing.isEmpty {
            pacing?.invalidate()
            // Give the display time to wake before announcing a new animation.
            let delay = phase == .waiting && outgoing.count == 1 && !screenAwake ? 0.5 : chunkDelay
            pacing = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.writeNext() }
        } else if phase == .sending {
            phase = .confirming; status = "发送完成，等待设备确认…"
            if confirmed { finishUpload() }
            else { armTimeout(8, "数据已发送，但设备未确认；请检查屏幕，必要时重试") }
        }
    }
    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data pointer: UnsafeMutableRawPointer!, length count: Int) {
        guard rfcommChannel === channel, let pointer, count > 0 else { return }
        for frame in decoder.append(Data(bytes: pointer, count: count)) {
            if frame == Data([4, 0x8b, 0x55, 0, 1]), phase == .waiting {
                phase = .sending; uploaded = 0
                // Do not send until the device requests data. Chunk size must be 256.
                outgoing.append(contentsOf: packets.dropFirst())
                armTimeout(max(20, Double(packets.count) * 0.15), "传输超时，请检查设备距离后重试")
                writeNext()
            } else if frame == Data([4, 0xbd, 0x55, 0x13, 1, 5, 0]), phase == .sending || phase == .confirming {
                confirmed = true
                if phase == .confirming { finishUpload() }
            } else if frame.starts(with: [4, 0xbd, 0x55, 0x2f]), phase == .stopping {
                resetTransport(closeChannel: false); phase = .idle; status = "已关闭 · MiniToo 屏幕已熄灭"
                lastSentKey = nil; pump()
            }
        }
    }
    private func finishUpload() {
        deadline?.invalidate(); deadline = nil
        screenAwake = true
        lastSentKey = uploadKey
        let detail: String
        switch uploadMode {
        case .aquarium: detail = "鱼缸动画循环展示"
        case .codex: detail = "Codex 状态展示"
        case .work: detail = "工作角色动画"
        case .chat: detail = "闲聊固定画面"
        }
        phase = .displaying; status = "设备已接收 · " + detail
        DispatchQueue.main.async { [weak self] in self?.pump() }
        let now = ProcessInfo.processInfo.systemUptime
        NSLog("MiniToo metrics mode=%@ bytes=%d packets=%d gap_ms=%.0f prepare_ms=%.1f transfer_ms=%.1f total_ms=%.1f ACK=1", uploadMode.rawValue, payloadBytes, packets.count, chunkDelay * 1000, preparedMS, (now - transferStarted) * 1000, (now - prepareStarted) * 1000)
    }
    private func stopDisplay() {
        screenAwake = false
        // Finish only the in-flight write; discard all queued animation chunks.
        let wasOpen = channel?.isOpen() == true
        if wasOpen {
            generation += 1; deadline?.invalidate(); pacing?.invalidate()
            outgoing = [MiniTooProtocol.screen(false)]
            phase = .stopping; status = "正在关闭 MiniToo 展示…"
            armTimeout(4, "已停止连接；熄屏未确认，可按设备键切换画面")
            writeNext()
        } else {
            resetTransport(); phase = .idle
            status = "已停止连接；如设备仍有画面，可按设备键切换"
        }
    }
    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        guard rfcommChannel === channel else { return }
        fail(enabled ? "MiniToo 已断开，重新连接蓝牙后点重试" : "已停止连接；可按设备键切换画面")
    }
    private func armTimeout(_ seconds: Double, _ message: String) {
        deadline?.invalidate()
        deadline = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            // A just-opened control channel can miss the first announce. Retry only
            // the idempotent announce, once, before sending any animation chunks.
            if self.phase == .waiting, self.writeBuffer == nil, self.outgoing.isEmpty, self.handshakeAttempts == 1 {
                self.handshakeAttempts = 2
                self.status = "正在等待 MiniToo 就绪，重新请求接收…"
                self.outgoing = [self.packets[0]]
                self.armTimeout(8, message); self.writeNext()
                return
            }
            // MiniToo 2.4.0 visibly turns the backlight off but may send no reply.
            // A completed write proves dispatch, not remote display state.
            if self.phase == .stopping, self.writeBuffer == nil, self.outgoing.isEmpty {
                self.resetTransport(closeChannel: false); self.phase = .idle
                self.status = "已关闭 · 已发送熄屏指令"
                self.lastSentKey = nil; self.pump()
            } else { self.fail(message) }
        }
    }
    private func fail(_ message: String) {
        resetTransport(); phase = .failed; status = message
        NSLog("MiniToo aquarium: %@", message)
    }
    private func resetTransport(closeChannel: Bool = true) {
        generation += 1
        deadline?.invalidate(); deadline = nil
        pacing?.invalidate(); pacing = nil
        if closeChannel {
            screenAwake = false
            let old = channel; channel = nil
            old?.setDelegate(nil); old?.close()
        }
        writeBuffer = nil; pendingWrite = nil; outgoing = []; decoder = MiniTooProtocol.Decoder()
        pendingPayload = nil
        confirmed = false; uploaded = 0
    }
    func shutdown() {
        started = false; contentTimer?.invalidate(); contentTimer = nil
        resetTransport()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
    }
}
