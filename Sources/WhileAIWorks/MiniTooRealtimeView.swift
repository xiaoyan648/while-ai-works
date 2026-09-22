import SwiftUI

@MainActor struct MiniTooRealtimeView: View {
    @ObservedObject private var chat = MiniTooRealtime.shared
    @ObservedObject private var voice = MiniTooVoice.shared
    @ObservedObject private var display = MiniTooAquarium.shared
    @State private var apiKey = ""
    @State private var message = ""
    @State private var settings = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(chat.active ? "结束闲聊" : "开始闲聊") { if chat.active { chat.stop() } else { chat.start() } }
                    .disabled(chat.closing || !display.enabled || (!chat.active && display.busy)).accessibilityIdentifier("realtime-toggle")
                if chat.active { Button("打断回复") { chat.interrupt() }.accessibilityIdentifier("realtime-interrupt") }
                Spacer()
                Button("音频设备") { settings = true }.disabled(chat.active || chat.closing)
            }.font(.system(size: 12))
            if !chat.active && display.busy {
                Text("正在发送固定画面，完成后即可开始闲聊").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(chat.status).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("realtime-status")
            if !chat.audioRoute.isEmpty { Text(chat.audioRoute).font(.system(size: 10)).foregroundStyle(.secondary) }
            if chat.active { ProgressView(value: Double(chat.level)).accessibilityLabel("闲聊麦克风音量") }
            if !chat.heard.isEmpty { Text("你：" + chat.heard).font(.system(size: 12)).textSelection(.enabled) }
            if !chat.reply.isEmpty { Text("MiniToo：" + chat.reply).font(.system(size: 12)).textSelection(.enabled) }
            DisclosureGroup("实时语音配置") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("豆包实时语音 3.0 · 开启后持续向豆包发送收音，结束或切换模式后停止。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    SecureField(chat.hasOwnKey ? "新的实时语音 Key（留空保留）" : "实时语音 Key（可留空，使用已有语音 Key）", text: $apiKey)
                        .accessibilityIdentifier("realtime-api-key")
                    TextField("实时语音音色 ID", text: $chat.voiceID).accessibilityIdentifier("realtime-voice")
                    Toggle("允许语音打断（建议搭配耳机）", isOn: $chat.allowInterruption).font(.system(size: 11))
                    Text("默认播报时暂停上传收音，播报结束自动继续，避免 MiniToo 收到自己的声音。可随时点“打断回复”。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    HStack {
                        Button("保存闲聊配置") {
                            do { try chat.saveKey(apiKey); apiKey = ""; message = chat.status }
                            catch { message = error.localizedDescription }
                        }.accessibilityIdentifier("realtime-save")
                        if chat.hasOwnKey { Button("使用已有语音 Key") {
                            do { try chat.removeKey(); message = chat.status } catch { message = error.localizedDescription }
                        } }
                    }
                    if !message.isEmpty { Text(message).font(.system(size: 10)).foregroundStyle(.secondary) }
                }.padding(.top, 8).textFieldStyle(.roundedBorder).disabled(chat.active || chat.closing)
            }.font(.system(size: 11))
        }.sheet(isPresented: $settings) { MiniTooVoiceSettingsView() }
            .onDisappear { apiKey = "" }
    }
}
