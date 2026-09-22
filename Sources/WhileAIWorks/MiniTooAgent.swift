import AppKit
import Combine
import Security
import LocalAuthentication
import WhileCore

enum MiniTooAgentKeychain {
    private static let service = "local.whileaiworks.mac.ark-agent"
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    static func exists(account: String = "api-key") -> Bool {
        let context = LAContext(); context.interactionNotAllowed = true
        var q = query(account); q[kSecReturnAttributes as String] = true; q[kSecUseAuthenticationContext as String] = context
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }
    static func read(account: String = "api-key") throws -> String {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let code = SecItemCopyMatching(q as CFDictionary, &result)
        guard code == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw WorkAgentError.message(code == errSecItemNotFound ? "请先配置 API Key。" : "无法读取钥匙串中的 API Key（\(code)）。")
        }
        return value
    }
    static func save(_ value: String, account: String = "api-key") throws {
        guard value.count >= 8, value.count <= 512, !value.contains(where: { $0.isWhitespace }) else {
            throw WorkAgentError.message("API Key 格式不正确，请检查空格或换行。")
        }
        let data = Data(value.utf8)
        var code = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if code == errSecItemNotFound {
            var q = query(account); q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            code = SecItemAdd(q as CFDictionary, nil)
        }
        guard code == errSecSuccess else { throw WorkAgentError.message("API Key 保存失败（\(code)）。") }
    }
    static func remove(account: String = "api-key") throws {
        let code = SecItemDelete(query(account) as CFDictionary)
        guard code == errSecSuccess || code == errSecItemNotFound else { throw WorkAgentError.message("API Key 移除失败（\(code)）。") }
    }
}

@MainActor final class MiniTooAgent: ObservableObject {
    static let shared = MiniTooAgent()
    struct Message: Identifiable {
        let id = UUID()
        let role: String
        let text: String
    }
    @Published private(set) var service: ArkAgentConfiguration.Service
    @Published private(set) var model: String
    @Published private(set) var hasKey: Bool
    @Published private(set) var running = false
    @Published private(set) var status = "输入任务，开始工作"
    @Published private(set) var messages: [Message] = []
    @Published var allowMacActions: Bool { didSet { defaults.set(allowMacActions, forKey: "minitoo.agent.allowMacActions") } }
    private let defaults: UserDefaults
    private let client = ArkAgentClient()
    private let runner = WorkAgentRunner()
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var appStatus: (() -> String)?
    private var codexStatus: (() -> String)?
    private var desktop: ((Bool) -> String)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let selected = ArkAgentConfiguration.Service(rawValue: defaults.string(forKey: "minitoo.agent.service") ?? "") ?? .inference
        service = selected
        model = defaults.string(forKey: "minitoo.agent.model") ?? selected.defaultModel
        hasKey = MiniTooAgentKeychain.exists()
        allowMacActions = defaults.bool(forKey: "minitoo.agent.allowMacActions")
    }
    func attach(appStatus: @escaping () -> String, codexStatus: @escaping () -> String, desktop: @escaping (Bool) -> String) {
        self.appStatus = appStatus; self.codexStatus = codexStatus; self.desktop = desktop
    }
    func configure(service: ArkAgentConfiguration.Service, model: String, newKey: String) throws {
        guard !running, !MiniTooVoice.shared.busy, !MiniTooRealtime.shared.active, !MiniTooRealtime.shared.closing else { throw WorkAgentError.message("请先停止当前任务。") }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        try ArkAgentConfiguration(service: service, model: model).validate()
        if !newKey.isEmpty { try MiniTooAgentKeychain.save(newKey.trimmingCharacters(in: .whitespacesAndNewlines)) }
        self.service = service; self.model = model
        defaults.set(service.rawValue, forKey: "minitoo.agent.service")
        defaults.set(model, forKey: "minitoo.agent.model")
        hasKey = MiniTooAgentKeychain.exists()
        runner.reset(); messages.removeAll()
        status = hasKey ? "配置已保存，密钥保存在本机钥匙串" : "模型配置已保存，请填写 API Key"
    }
    func removeKey() throws {
        MiniTooVoice.shared.cancel(); try MiniTooAgentKeychain.remove(); hasKey = false
        runner.reset(); messages.removeAll(); status = "已移除本机 API Key"
    }
    func reset() {
        MiniTooVoice.shared.cancel(); runner.reset(); messages.removeAll(); status = "新对话"
    }
    private func append(_ role: String, _ text: String) {
        messages.append(Message(role: role, text: text))
        if messages.count > 80 { messages.removeFirst(messages.count - 80) }
    }
    @discardableResult func send(_ input: String, allowTools: Bool = true, speakReply: Bool = false, fromVoice: Bool = false) -> Bool {
        guard !running, !MiniTooVoice.shared.busy, !MiniTooRealtime.shared.active, !MiniTooRealtime.shared.closing else { return false }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        guard text.count <= 4000 else { status = "任务最多 4000 字"; return false }
        let key: String
        do { key = try MiniTooAgentKeychain.read() }
        catch { status = error.localizedDescription; return false }
        append(fromVoice ? "你 · 语音识别" : "你", text)
        if speakReply { MiniTooVoice.shared.beginAnswer() }
        running = true; status = "正在思考…"
        MiniTooAquarium.shared.setAgentActivity(.thinking, detail: "Agent 正在处理任务")
        let ticket = UUID(); generation = ticket
        let configuration = ArkAgentConfiguration(service: service, model: model)
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == ticket { self.running = false; self.task = nil } }
            do {
                let answer = try await self.runner.run(text, voiceInput: fromVoice, complete: { messages in
                    try await self.client.complete(configuration: configuration, key: key, messages: messages, useTools: allowTools)
                }, execute: { action in
                    guard allowTools else { throw WorkAgentError.message("连接测试不执行工具。") }
                    return try await self.execute(action)
                }, event: { event in
                    if self.generation == ticket { self.append("工具", event); self.status = "正在处理工具结果…" }
                })
                guard self.generation == ticket, !Task.isCancelled else { return }
                self.append("MiniToo", answer)
                if speakReply {
                    self.status = "文字已完成，正在准备语音回复…"
                    do { try await MiniTooVoice.shared.speak(answer) }
                    catch {
                        if Task.isCancelled { throw CancellationError() }
                        guard self.generation == ticket else { return }
                        MiniTooVoice.shared.fail(error)
                        self.status = "文字已完成；语音回复失败：" + error.localizedDescription
                        self.append("提示", self.status); return
                    }
                }
                guard self.generation == ticket, !Task.isCancelled else { return }
                self.status = speakReply ? "本轮完成 · 语音已播放" : "本轮完成"
                MiniTooAquarium.shared.setAgentActivity(.complete, detail: self.status)
            } catch {
                guard self.generation == ticket else { return }
                let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
                self.status = cancelled ? "已停止；已执行的操作请查看记录" : error.localizedDescription
                self.append("提示", self.status)
                if speakReply { MiniTooVoice.shared.stopAudio() }
                MiniTooAquarium.shared.setAgentActivity(.idle, detail: cancelled ? "Agent 已停止" : "Agent 请求失败，请查看 Mac 上的提示")
            }
        }
        return true
    }
    func cancel() {
        guard running else { return }
        MiniTooVoice.shared.stopAudio()
        task?.cancel(); generation = UUID(); task = nil; running = false
        status = "已停止；已执行的操作请查看记录"; append("提示", status)
        MiniTooAquarium.shared.setAgentActivity(.idle, detail: "Agent 已停止")
    }
    private func execute(_ action: WorkAgentAction) async throws -> String {
        try Task.checkCancellation()
        switch action {
        case .appStatus: return appStatus?() ?? "应用状态暂不可用。"
        case .codexStatus: return codexStatus?() ?? "Codex 状态暂不可用。"
        case .desktop(let enabled): return desktop?(enabled) ?? "未执行：桌面游戏未初始化。"
        case .display(let mode, let enabled):
            guard let selected = MiniTooAquarium.Mode(rawValue: mode) else { throw WorkAgentError.message("无效展示模式。") }
            let display = MiniTooAquarium.shared
            display.setMode(selected); display.setEnabled(enabled)
            return "已更新展示设置：\(selected.title)，开关\(enabled ? "开" : "关")。设备状态：\(display.status)。这不代表设备已收到新画面。"
        case .openApp(let name):
            guard allowMacActions else { throw WorkAgentError.message("尚未开启“允许打开应用和网页”，没有操作 Mac。") }
            let ids = ["Safari": "com.apple.Safari", "Notes": "com.apple.Notes", "Calculator": "com.apple.calculator",
                       "Calendar": "com.apple.iCal", "Finder": "com.apple.finder"]
            guard let id = ids[name], let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
                throw WorkAgentError.message("未找到这个应用。")
            }
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return "已打开应用：" + name
        case .openWeb(let url):
            guard allowMacActions else { throw WorkAgentError.message("尚未开启“允许打开应用和网页”，没有操作 Mac。") }
            guard NSWorkspace.shared.open(url) else { throw WorkAgentError.message("浏览器未能接受打开请求。") }
            return "已将网页交给默认浏览器打开：\(url.absoluteString)。未读取或验证网页内容。"
        }
    }
}
