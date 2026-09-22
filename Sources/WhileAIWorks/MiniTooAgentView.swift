import SwiftUI
import WhileCore

@MainActor struct MiniTooAgentView: View {
    @ObservedObject private var agent = MiniTooAgent.shared
    @ObservedObject private var voice = MiniTooVoice.shared
    @State private var showVoiceSettings = false
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var service = ArkAgentConfiguration.Service.inference
    @State private var model = ""
    @State private var apiKey = ""
    @State private var showConfiguration = false
    @State private var configurationMessage = ""
    private let mint = Color(nsColor: .playMint)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("MiniToo 工作台").font(.system(size: 20, weight: .semibold))
                    Text("工作语音快捷键 " + MiniTooVoiceShortcut.shared.label).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            DisclosureGroup("火山引擎配置 · \(agent.hasKey ? "已保存密钥" : "未配置密钥")", isExpanded: $showConfiguration) {
                VStack(alignment: .leading, spacing: 9) {
                    Picker("接口类型", selection: $service) {
                        ForEach(ArkAgentConfiguration.Service.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("agent-service")
                    TextField("模型 ID 或推理接入点 ID", text: $model).accessibilityIdentifier("agent-model")
                    SecureField(agent.hasKey ? "新的 API Key（留空保留现有密钥）" : "API Key", text: $apiKey)
                        .accessibilityIdentifier("agent-api-key")
                    Text(service == .inference ? "普通推理按账户开通情况计费，不使用 Coding Plan 额度。" : "使用 Coding Plan 专用接口，需要对应套餐与模型权限。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("密钥仅存本机钥匙串，不随应用分发。任务文本及工具结果会发送至火山引擎。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    HStack {
                        Button("保存配置") {
                            do {
                                try agent.configure(service: service, model: model, newKey: apiKey)
                                apiKey = ""; configurationMessage = agent.status
                            } catch { configurationMessage = error.localizedDescription }
                        }.accessibilityIdentifier("agent-save-config")
                        Button("测试连接") {
                            showConfiguration = false
                            agent.send("请只回复：连接成功。", allowTools: false)
                        }.disabled(!agent.hasKey).accessibilityIdentifier("agent-test-connection")
                        Spacer()
                        Button("移除密钥") {
                            do { try agent.removeKey(); apiKey = ""; configurationMessage = agent.status }
                            catch { configurationMessage = error.localizedDescription }
                        }.disabled(!agent.hasKey).accessibilityIdentifier("agent-remove-key")
                    }
                    if !configurationMessage.isEmpty { Text(configurationMessage).font(.system(size: 10)).foregroundStyle(.secondary) }
                }.textFieldStyle(.roundedBorder).padding(.top, 8).disabled(agent.running || voice.busy)
            }.font(.system(size: 12))
            Toggle("允许打开应用和网页", isOn: $agent.allowMacActions)
                .font(.system(size: 11)).toggleStyle(.switch).controlSize(.mini).tint(mint)
                .accessibilityIdentifier("agent-allow-mac")
            Text("可查应用与 Codex 状态、控制展示和桌面开关；开启上方选项后可打开 Safari、备忘录、计算器、日历、访达及 HTTPS 网页。")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("语音与音频设备") { showVoiceSettings = true }
                    .disabled(agent.running || voice.busy).accessibilityIdentifier("voice-settings")
                Spacer()
                if voice.phase == .recording {
                    Text(String(format: "%.1f 秒", voice.seconds)).monospacedDigit()
                    Button("结束并发送") { voice.finishRecording() }.accessibilityIdentifier("voice-finish")
                } else if voice.busy && !agent.running {
                    Button("停止语音") { voice.cancel() }.accessibilityIdentifier("voice-stop")
                } else {
                    Button("开始说话") { voice.startRecording() }
                        .disabled(agent.running || voice.busy || !voice.hasKey || !agent.hasKey)
                        .accessibilityIdentifier("voice-start")
                }
            }.font(.system(size: 12))
            if voice.phase == .recording { ProgressView(value: Double(voice.level)).accessibilityLabel("麦克风音量") }
            if voice.busy || voice.status != "点击开始说话，结束后发送" {
                Text(voice.status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if agent.messages.isEmpty {
                            Text("试试：当前有几个 Codex 任务在运行？\n或：请打开计算器。")
                                .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 16)
                        }
                        ForEach(agent.messages) { message in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(message.role).font(.system(size: 10, weight: .semibold)).foregroundStyle(mint)
                                Text(verbatim: message.text).font(.system(size: message.role == "工具" ? 11 : 13))
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, alignment: .leading).id(message.id)
                        }
                    }.padding(12)
                }.background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                    .onChange(of: agent.messages.count) { _, _ in
                        if let id = agent.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
            }
            Text(agent.status).font(.system(size: 11)).foregroundStyle(.secondary)
                .accessibilityIdentifier("agent-status")
            HStack(alignment: .bottom) {
                TextField("输入任务…", text: $input, axis: .vertical).lineLimit(1...4)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("agent-input")
                    .onSubmit { send() }.disabled(agent.running || voice.busy)
                if agent.running {
                    Button("停止") { agent.cancel() }.accessibilityIdentifier("agent-stop")
                } else {
                    Button("发送") { send() }.disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !agent.hasKey || voice.busy)
                        .accessibilityIdentifier("agent-send")
                }
            }
            HStack {
                Button("新对话") { agent.reset() }.buttonStyle(.plain).foregroundStyle(mint)
                Spacer()
                Text("对话仅保留在本次应用内存中").foregroundStyle(.secondary)
            }.font(.system(size: 10))
        }.padding(24).frame(width: 560, height: 690).preferredColorScheme(.light)
            .onAppear { service = agent.service; model = agent.model; showConfiguration = !agent.hasKey }
            .onChange(of: service) { _, selected in model = selected.defaultModel }
            .sheet(isPresented: $showVoiceSettings) { MiniTooVoiceSettingsView() }
            .onDisappear { apiKey = "" }
    }
    private func send() {
        guard !agent.running, !voice.busy, agent.hasKey else { return }
        let text = input; input = ""; agent.send(text, speakReply: voice.readReplies)
    }
}
