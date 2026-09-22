import SwiftUI
import WhileCore

@MainActor struct MiniTooVoiceSettingsView: View {
    @ObservedObject private var voice = MiniTooVoice.shared
    @ObservedObject private var agent = MiniTooAgent.shared
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var resource = "seed-tts-2.0"
    @State private var speaker = "zh_female_vv_uranus_bigtts"
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("语音与音频设备").font(.system(size: 20, weight: .semibold))
                Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("点击说话 → 豆包识别 → Agent → 豆包语音回复。录音最长 30 秒，播放时不收音。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            GroupBox("收音与播放") {
                VStack(alignment: .leading, spacing: 10) {
                    devicePicker("麦克风", selection: $voice.inputUID, choices: voice.inputs).accessibilityIdentifier("voice-input-device")
                    devicePicker("扬声器", selection: $voice.outputUID, choices: voice.outputs).accessibilityIdentifier("voice-output-device")
                    HStack {
                        Button("刷新设备") { voice.refreshDevices() }
                        Button("测试麦克风") { voice.startRecording(testOnly: true) }.accessibilityIdentifier("voice-test-mic")
                        Button("测试扬声器") { voice.testSpeaker(cloud: false) }.accessibilityIdentifier("voice-test-speaker")
                    }
                    Text("仅选择本应用使用的设备，不修改 Mac 默认音频设备。麦克风测试持续 5 秒，仅显示音量，不上传。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(6).disabled(voice.busy || agent.running)
            }
            GroupBox("豆包语音配置") {
                VStack(alignment: .leading, spacing: 10) {
                    SecureField(voice.hasKey ? "新语音 API Key（留空保留）" : "豆包语音 API Key", text: $apiKey)
                        .accessibilityIdentifier("voice-api-key")
                    Picker("合成模型", selection: $resource) {
                        Text("语音合成 2.0").tag("seed-tts-2.0")
                        Text("语音合成 1.0 字符版").tag("seed-tts-1.0")
                        Text("语音合成 1.0 并发版").tag("seed-tts-1.0-concurr")
                    }
                    TextField("音色 ID", text: $speaker).accessibilityIdentifier("voice-speaker-id")
                    Text("需要开通录音极速识别和所选语音合成服务。语音 Key 与模型 Key 分开保存在本机钥匙串；录音和回答会发送至豆包语音。")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("保存语音配置") {
                            do { try voice.configure(resource: resource, speaker: speaker, newKey: apiKey); apiKey = ""; message = voice.status }
                            catch { message = error.localizedDescription }
                        }.accessibilityIdentifier("voice-save")
                        Button("试听音色") {
                            do { try voice.configure(resource: resource, speaker: speaker, newKey: apiKey); apiKey = ""; voice.testSpeaker(cloud: true) }
                            catch { message = error.localizedDescription }
                        }.disabled(!voice.hasKey && apiKey.isEmpty).accessibilityIdentifier("voice-preview")
                        Spacer()
                        Button("移除语音 Key") {
                            do { try voice.removeKey(); apiKey = ""; message = voice.status }
                            catch { message = error.localizedDescription }
                        }.disabled(!voice.hasKey).accessibilityIdentifier("voice-remove-key")
                    }
                    if !message.isEmpty { Text(message).font(.system(size: 10)).foregroundStyle(.secondary) }
                }.textFieldStyle(.roundedBorder).padding(6).disabled(voice.busy || agent.running)
            }
            Toggle("朗读文字任务的回复", isOn: $voice.readReplies).disabled(!voice.hasKey || voice.busy || agent.running)
                .font(.system(size: 12)).accessibilityIdentifier("voice-read-replies")
            Text("语音任务默认会朗读回复；文字任务可单独开启朗读。音频只保存在内存，不保存录音文件。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if voice.phase == .recording {
                ProgressView(value: Double(voice.level)).accessibilityLabel("麦克风音量")
                Text(String(format: "收音 %.1f 秒", voice.seconds)).font(.system(size: 11))
            }
            HStack {
                Text(voice.status).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("voice-status")
                Spacer()
                if voice.busy { Button("停止") { voice.cancel() }.accessibilityIdentifier("voice-stop") }
            }
            Spacer(minLength: 0)
        }.padding(24).frame(width: 560, height: 610).preferredColorScheme(.light)
            .onAppear { resource = voice.configuration.resource; speaker = voice.configuration.speaker; voice.refreshDevices() }
            .onChange(of: resource) { _, value in
                if value == "seed-tts-2.0" { speaker = "zh_female_vv_uranus_bigtts" }
                else if speaker == "zh_female_vv_uranus_bigtts" { speaker = "zh_female_shuangkuaisisi_moon_bigtts" }
            }
            .onDisappear { apiKey = ""; if voice.busy { voice.cancel() } }
    }
    private func devicePicker(_ name: String, selection: Binding<String>, choices: [MiniTooAudioDevice]) -> some View {
        Picker(name, selection: selection) {
            Text("MiniToo（自动寻找）").tag(MiniTooAudioDevices.miniToo)
            Text("跟随系统默认").tag(MiniTooAudioDevices.systemDefault)
            ForEach(choices) { Text($0.name).tag($0.id) }
            if ![MiniTooAudioDevices.miniToo, MiniTooAudioDevices.systemDefault].contains(selection.wrappedValue), !choices.contains(where: { $0.id == selection.wrappedValue }) {
                Text("已保存的设备（未连接）").tag(selection.wrappedValue)
            }
        }
    }
}
