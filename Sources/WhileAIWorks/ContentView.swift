import SwiftUI
import WhileCore

private let ink = Color(nsColor: .playInk)
private let mint = Color(nsColor: .playMint)
private let paper = Color(red: 0.976, green: 0.969, blue: 0.949)

struct ContentView: View {
    @ObservedObject var state: AppState
    @State private var showingConnections = false
    var body: some View {
        HStack(spacing: 0) {
            controls
            if state.settingsSection == .desktop && state.mode == .fishing { FishingGuide(state: state) }
        }.preferredColorScheme(.light)
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("WHILE AI WORKS").font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(2.7).foregroundStyle(mint).padding(.bottom, 9)
                Text("AI 干活时我们干什么")
                    .font(.system(size: 23, weight: .semibold)).tracking(-0.8).padding(.bottom, 18)
                HStack(spacing: 8) {
                    ForEach(SettingsSection.allCases, id: \.self) { section in
                        Button { state.settingsSection = section } label: {
                            Label(section.title, systemImage: section == .desktop ? "gamecontroller" : "display")
                                .font(.system(size: 12, weight: .medium))
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .foregroundStyle(state.settingsSection == section ? mint : ink.opacity(0.5))
                                .background(state.settingsSection == section ? mint.opacity(0.10) : ink.opacity(0.025),
                                            in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("settings-\(section.rawValue)")
                            .accessibilityAddTraits(state.settingsSection == section ? .isSelected : [])
                    }
                }
            }.padding(.horizontal, 28).padding(.top, 32).padding(.bottom, 20)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if state.settingsSection == .desktop {
                        gameControls
                    } else {
                        MiniTooSettingsView()
                    }
                }.padding(.horizontal, 28).padding(.bottom, 20).frame(maxWidth: .infinity, alignment: .topLeading)
            }.id(state.settingsSection)
        }
        .frame(width: 438, height: 688)
        .foregroundStyle(ink).background(paper).preferredColorScheme(.light)
    }
    private var gameControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(state.desktopEnabled ? mint : ink.opacity(0.22)).frame(width: 5, height: 5)
                Text(state.status).font(.system(size: 11)).foregroundStyle(ink.opacity(0.55))
            }.padding(.bottom, 16)

            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(state.desktopEnabled ? "回去工作" : "开始玩").font(.system(size: 15, weight: .medium))
                    Text("开启就能玩，关闭后收起桌面效果")
                        .font(.system(size: 10)).foregroundStyle(ink.opacity(0.48))
                }
                Spacer()
                Toggle("开始玩", isOn: $state.desktopEnabled).labelsHidden().toggleStyle(.switch)
                    .tint(mint).accessibilityIdentifier("desktop-toggle")
            }
            HStack(spacing: 6) {
                Text("切换快捷键").font(.system(size: 10)).foregroundStyle(ink.opacity(0.48))
                Spacer()
                Picker("组合键", selection: $state.shortcutModifiers) {
                    Text("⌘ ⇧").tag(0); Text("⌃ ⌥").tag(1); Text("⌃ ⇧").tag(2)
                }.labelsHidden().frame(width: 82)
                Picker("按键", selection: $state.shortcutKey) {
                    ForEach(AppState.shortcutKeys, id: \.code) { key in Text(key.name).tag(key.code) }
                }.labelsHidden().frame(width: 76)
            }.padding(.top, 7)
            if let error = state.shortcutError {
                Text(error).font(.system(size: 10)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            divider
            Text("玩什么").font(.system(size: 11)).foregroundStyle(ink.opacity(0.48)).padding(.bottom, 10)
            HStack(spacing: 8) {
                ForEach(PlayMode.allCases) { mode in
                    Button { state.mode = mode } label: {
                        VStack(spacing: 9) {
                            Image(systemName: mode.symbol).font(.system(size: 19, weight: .regular))
                            Text(mode.title).font(.system(size: 12, weight: .medium))
                            Text(state.countLabel(for: mode)).font(.system(size: 10)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity).frame(height: 88)
                        .foregroundStyle(state.mode == mode ? mint : ink.opacity(0.50))
                        .background(state.mode == mode ? mint.opacity(0.10) : ink.opacity(0.025),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(state.mode == mode ? mint.opacity(0.25) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("mode-\(mode.rawValue)")
                }
            }.padding(.bottom, 16)
            HStack {
                Toggle("自动切换", isOn: $state.autoSwitch).toggleStyle(.switch).controlSize(.mini)
                    .font(.system(size: 12)).tint(mint).fixedSize().accessibilityIdentifier("auto-switch")
                Spacer()
                Picker("切换间隔", selection: $state.switchInterval) {
                    Text("每 30 秒").tag(30.0)
                    Text("每 1 分钟").tag(60.0)
                    Text("每 2 分钟").tag(120.0)
                    Text("每 5 分钟").tag(300.0)
                }.labelsHidden().frame(width: 110).disabled(!state.autoSwitch)
                    .accessibilityIdentifier("switch-interval")
            }
            divider
            if state.availableScreens.count>1 || !state.targetScreenID.isEmpty {
                settingRow("显示屏幕") {
                    Picker("显示屏幕",selection:$state.targetScreenID) {
                        Text("主显示器（自动）").tag("")
                        ForEach(state.availableScreens) { screen in Text(screen.title).tag(screen.id) }
                        if state.selectedScreenUnavailable {Text("所选屏幕未连接 · 暂用主屏幕").tag(state.targetScreenID)}
                    }.labelsHidden().frame(width:220).accessibilityIdentifier("desktop-screen")
                }.padding(.bottom,12)
            }
            settingRow("出现范围") {
                Picker("出现范围", selection: $state.area) {
                    ForEach(PlayArea.allCases) { area in Text(state.mode == .fishing ? (area == .edges ? "小角落" : "大角落") : area.title).tag(area) }
                }.labelsHidden().pickerStyle(.segmented).frame(width: 220)
                    .accessibilityIdentifier("play-area")
            }.padding(.bottom, 12)
            settingRow("什么时候") {
                Menu {
                    Picker("工作方式", selection: $state.followAI) {
                        Text("随时开启").tag(false)
                        Text("跟随 AI 工作").tag(true)
                    }
                    Divider()
                    ForEach(WorkSource.allCases) { source in
                        Toggle(source.clientName, isOn: Binding(
                            get: { state.selectedSources.contains(source) },
                            set: { state.setSource(source, selected: $0) }
                        )).disabled(!state.followAI)
                    }
                    Button("全选") { state.selectedSources = Set(WorkSource.allCases); state.followAI = true }
                } label: {
                    Text(state.followAI ? "跟随 \(state.selectedClientsLabel)" : "随时开启")
                }.frame(width: 220).accessibilityIdentifier("work-source")
            }
            if state.followAI {
                HStack {
                    Text("AI 工作时补充、轮换；结束后可继续玩。")
                    Spacer(minLength: 4)
                    Button("连接管理") { showingConnections = true }
                        .buttonStyle(.plain).foregroundStyle(mint)
                        .accessibilityIdentifier("manage-connections")
                        .popover(isPresented: $showingConnections) { connections }
                }.font(.system(size: 10)).foregroundStyle(ink.opacity(0.45)).padding(.top, 10)
            }
            divider
            HStack(spacing: 12) {
                Button { state.soundEnabled.toggle() } label: {
                    Image(systemName: state.soundEnabled ? "speaker.wave.2" : "speaker.slash")
                        .font(.system(size: 13)).frame(width: 22)
                }.buttonStyle(.plain).accessibilityLabel(state.soundEnabled ? "静音" : "打开声音")
                    .accessibilityIdentifier("sound-toggle")
                Slider(value: $state.volume, in: 0...1).tint(mint).controlSize(.small)
                    .disabled(!state.soundEnabled).accessibilityLabel("音量")
                Text("\(Int(state.volume * 100))%")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(ink.opacity(0.45)).frame(width: 34)
            }
            divider
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(state.mode == .woodfish ? "木鱼当前值" : state.mode == .wipe ? "累计擦净" : state.mode == .fishing ? "总鱼获" : "累计捏破").font(.system(size: 10)).foregroundStyle(ink.opacity(0.45))
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text((state.mode == .woodfish ? state.woodBalance : state.total(for: state.mode)).formatted()).font(.system(size: 24, weight: .medium, design: .rounded)).monospacedDigit()
                        Text(state.mode == .wipe ? "处" : state.mode == .bubbles ? "颗" : state.mode == .fishing ? "件" : "").font(.system(size: 10)).foregroundStyle(ink.opacity(0.45))
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 9) {
                    Text("本次 \(state.session(for: state.mode).formatted()) \(state.mode == .wipe ? "处" : state.mode == .bubbles ? "颗" : state.mode == .fishing ? "件" : "次")")
                        .font(.system(size: 10)).foregroundStyle(ink.opacity(0.45))
                    Button { state.reset() } label: {
                        Label(state.mode == .fishing ? "收竿重来" : "重新铺满", systemImage: "arrow.clockwise").font(.system(size: 11))
                    }.buttonStyle(.plain).foregroundStyle(mint)
                        .disabled(state.mode == .woodfish || !state.desktopEnabled)
                        .accessibilityIdentifier("reset-surface")
                }
            }
            if state.mode == .fishing {
                Text(state.fishingActivityLabel).font(.system(size: 10)).foregroundStyle(mint).padding(.top, 12)
            }
            if state.mode == .woodfish {
                Text(state.followAI ? "AI 工作时每 5 秒 −1，敲击 +1" : "开启时每 5 秒 −1，敲击 +1")
                    .font(.system(size: 10)).foregroundStyle(ink.opacity(0.45)).padding(.top, 12)
            }
            Spacer(minLength: 0)
        }
    }
    private var connections: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("连接管理").font(.system(size: 15, weight: .medium))
            Text("Codex 自动读取本地会话，无需安装。")
            ForEach(HookProvider.allCases, id: \.rawValue) { provider in
                HStack {
                    Text(provider.title)
                    Spacer()
                    Button("安装监听") { state.installHooks(provider) }
                    Button("移除") { state.installHooks(provider, remove: true) }
                }
            }
            Text("Qoder / WorkBuddy 首次使用需安装监听并重启客户端；如有 Hooks 审核提示，请在客户端启用。取消勾选仅停止跟随，移除会删除本应用的监听配置。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let message = state.hookSetupMessage {
                Text(message).foregroundStyle(mint).fixedSize(horizontal: false, vertical: true)
            }
        }.font(.system(size: 11)).padding(20).frame(width: 350)
    }
    private var divider: some View {
        Rectangle().fill(ink.opacity(0.085)).frame(height: 1).padding(.vertical, 12)
    }
    private func settingRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label).font(.system(size: 12))
            Spacer()
            content()
        }
    }
}

@MainActor private struct MiniTooSettingsView: View {
    @ObservedObject private var display = MiniTooAquarium.shared
    @ObservedObject private var agent = MiniTooAgent.shared
    @ObservedObject private var voiceShortcut = MiniTooVoiceShortcut.shared
    @State private var showingAgent = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("MiniToo 展示").font(.system(size: 18, weight: .semibold))
                    Text("选择设备屏幕上显示的内容")
                        .font(.system(size: 11)).foregroundStyle(ink.opacity(0.5))
                }
                Spacer()
                Toggle("启用 MiniToo", isOn: Binding(get: { display.enabled }, set: { display.setEnabled($0) }))
                    .labelsHidden().toggleStyle(.switch).tint(mint)
                    .accessibilityIdentifier("minitoo-aquarium-toggle")
            }
            Picker("显示内容", selection: Binding(get: { display.mode }, set: { display.setMode($0) })) {
                ForEach(MiniTooAquarium.Mode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
            }
            .pickerStyle(.segmented).accessibilityIdentifier("minitoo-mode")
            VStack(alignment: .leading, spacing: 14) {
                preview
                if display.mode == .work {
                    Picker("说话快捷键", selection: $voiceShortcut.selection) {
                        ForEach(0..<MiniTooVoiceShortcut.labels.count, id: \.self) { Text(MiniTooVoiceShortcut.labels[$0]).tag($0) }
                    }.accessibilityIdentifier("voice-shortcut")
                    Text(voiceShortcut.error ?? "按一次开始说话，再按发送；处理或播报时再按可停止。无需打开工作台。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Button("打开 Agent 工作台") { showingAgent = true }
                        .accessibilityIdentifier("minitoo-agent-open")
                        .sheet(isPresented: $showingAgent) { MiniTooAgentView() }
                    DisclosureGroup("预览角色动作") {
                        Picker("预览角色动作", selection: Binding(get: { display.companionPreviewState }, set: { display.setCompanionPreview($0) })) {
                            ForEach(MiniTooCompanionArtwork.State.allCases, id: \.self) { state in
                                Text(state.title).tag(state)
                            }
                        }.labelsHidden().pickerStyle(.segmented).accessibilityIdentifier("minitoo-companion-preview")
                            .disabled(agent.running)
                    }.font(.system(size: 11))
                }
                if display.mode == .chat { MiniTooRealtimeView() }
                VStack(alignment: .leading, spacing: 6) {
                    Text(display.contentDetail).font(.system(size: 10)).foregroundStyle(ink.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                    if display.mode == .codex && display.pageCount > 1 {
                        HStack(spacing: 8) {
                            Button("上一页") { display.changePage(-1) }.disabled(display.page == 0)
                            Text("\(display.page + 1)/\(display.pageCount)").monospacedDigit()
                            Button("下一页") { display.changePage(1) }.disabled(display.page + 1 >= display.pageCount)
                        }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(mint)
                    }
                    Text(display.status).font(.system(size: 10))
                        .foregroundStyle(display.phase == .failed ? Color.orange : ink.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("minitoo-status")
                    if display.canRetry {
                        Button(display.phase == .displaying ? "重新发送" : "重试连接") { display.retry() }
                            .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(mint)
                            .accessibilityIdentifier("minitoo-retry")
                    }
                }
            }
            Text("手动选择展示内容，关闭时熄屏。独立于桌面游戏开关。\n预览随数据更新，设备收到后生效。")
                .font(.system(size: 9)).foregroundStyle(ink.opacity(0.4))

        }
    }
    @ViewBuilder private var preview: some View {
        if display.mode == .work {
            // Only this small view ticks; frames are cached and never re-uploaded per tick.
            TimelineView(.animation(minimumInterval: Double(MiniTooCompanionArtwork.milliseconds) / 1000)) { context in
                let index = Int(context.date.timeIntervalSinceReferenceDate * 1000 / Double(MiniTooCompanionArtwork.milliseconds))
                previewImage(MiniTooCompanionArtwork.frame(display.companionPreviewState, index: index))
            }
        } else {
            previewImage(display.preview)
        }
    }
    private func previewImage(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1).resizable().interpolation(.high)
            .frame(width: 240, height: 192).clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity).padding(.vertical, 4)
            .accessibilityLabel("MiniToo 待显示内容预览")
    }
}
