import SwiftUI
import WhileCore

/// The settings window: one grouped form, in the style of System Settings.
struct SettingsView: View {
    @ObservedObject var state: AppState
    let preview: MascotController
    static let projectURL = URL(string: "https://github.com/xiaoyan648/while-ai-works")!

    var body: some View {
        Form {
            companion
            Section("AI 工作台") {
                Toggle("在工作卡片预览回复", isOn: $state.agentReplyPreviews)
                    .accessibilityIdentifier("agent-reply-previews")
                Text("用量由已登录客户端读取。回复仅在本机内存展示；关闭后隐藏正文。消息通过原会话发送，Claude 可回到客户端或复制恢复命令继续。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("刷新用量", action: state.refreshAgentData)
            }
            controls
            desktop
            ai
            appearance
            sound
            about
        }
        .formStyle(.grouped)
        .scrollContentBackground(state.panelMaterial == .solid ? .hidden : .automatic)
        .background { if state.panelMaterial == .solid { Theme.surface.ignoresSafeArea() } }
        .tint(Theme.accent)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 420, idealHeight: 660)
        .onAppear { preview.set(mood: .idle, coat: state.mascotCoat) }
        .onChange(of: state.mascotCoat) { _, coat in preview.set(mood: .idle, coat: coat) }
    }

    private var companion: some View {
        Section {
            HStack(spacing: 14) {
                MascotView(controller: preview)
                    .frame(width: 92, height: 92)
                    .background(ForestBackdrop(cornerRadius: 16, focus: 0.5))
                VStack(alignment: .leading, spacing: 6) {
                    Text("你的猫").font(.headline)
                    Text("可以住在桌面上陪你。点它会蹭蹭你，钓到鱼会跳起来。")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Picker("毛色", selection: $state.mascotCoat) {
                        ForEach(MascotCoat.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                    .accessibilityIdentifier("mascot-coat")
                }
            }
            .padding(.vertical, 4)
            Toggle("在桌面显示陪伴", isOn: $state.desktopPetEnabled)
                .accessibilityIdentifier("desktop-pet-toggle")
            if state.desktopPetEnabled {
                Picker("展现形态", selection: $state.desktopPetPresentation) {
                    ForEach(DesktopPetPresentation.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("desktop-pet-presentation")
                if state.desktopPetPresentation == .dock {
                    Picker("猫条方向", selection: $state.desktopDockOrientation) {
                        ForEach(DesktopDockOrientation.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("cat-dock-orientation")
                    Picker("边缘形态", selection: $state.desktopDockAttachment) {
                        ForEach(DesktopDockAttachment.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("cat-dock-attachment")
                    Picker("停靠边缘", selection: $state.desktopDockEdge) {
                        ForEach(DesktopDockEdge.allCases.filter { $0.orientation == state.desktopDockOrientation }) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("cat-dock-edge")
                } else {
                    Picker("桌面小猫大小", selection: $state.desktopPetSize) {
                        ForEach(DesktopPetSize.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("desktop-pet-size")
                }
                Picker("陪伴外观", selection: $state.desktopCompanionAppearance) {
                    ForEach(DesktopCompanionAppearance.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("cat-dock-appearance")
                Toggle("展开 AI 工作详情", isOn: $state.desktopPetShowsStatus)
                    .accessibilityIdentifier("desktop-pet-status")
                LabeledContent("位置") {
                    Button(state.desktopPetPresentation == .dock ? "回到边缘中央" : "回到屏幕角落") { state.resetDesktopPetPosition() }
                        .accessibilityIdentifier("desktop-pet-reset")
                }
                Text(state.desktopPetPresentation == .dock
                     ? "悬停预览，点击固定工作卡片。拖动猫头可移动、换边；横竖方向可在猫条菜单里切换。"
                     : "数字气泡显示运行中的会话数，点开查看详情。拖动小猫可移动，右键可切换为猫条。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var controls: some View {
        Section("开关") {
            LabeledContent("开始 / 收起") {
                HStack(spacing: 6) {
                    Picker("组合键", selection: $state.shortcutModifiers) {
                        Text("⌘ ⇧").tag(0); Text("⌃ ⌥").tag(1); Text("⌃ ⇧").tag(2)
                    }.labelsHidden().fixedSize()
                    Picker("按键", selection: $state.shortcutKey) {
                        ForEach(AppState.shortcutKeys, id: \.code) { key in Text(key.name).tag(key.code) }
                    }.labelsHidden().fixedSize()
                }
            }
            if let error = state.shortcutError {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("自动切换玩法", isOn: $state.autoSwitch).accessibilityIdentifier("auto-switch")
            Picker("切换间隔", selection: $state.switchInterval) {
                Text("每 30 秒").tag(30.0); Text("每 1 分钟").tag(60.0)
                Text("每 2 分钟").tag(120.0); Text("每 5 分钟").tag(300.0)
            }
            .disabled(!state.autoSwitch)
            .accessibilityIdentifier("switch-interval")
        }
    }

    private var desktop: some View {
        Section("桌面") {
            if state.availableScreens.count > 1 || !state.targetScreenID.isEmpty {
                Picker("显示屏幕", selection: $state.targetScreenID) {
                    Text("主显示器（自动）").tag("")
                    ForEach(state.availableScreens) { screen in Text(screen.title).tag(screen.id) }
                    if state.selectedScreenUnavailable { Text("所选屏幕未连接 · 暂用主屏幕").tag(state.targetScreenID) }
                }
                .accessibilityIdentifier("desktop-screen")
            }
            Picker("出现范围", selection: $state.area) {
                ForEach(PlayArea.allCases) { area in
                    Text(state.mode == .fishing ? (area == .edges ? "小角落" : "大角落") : area.title).tag(area)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("play-area")
        }
    }

    private var ai: some View {
        Section {
            Picker("什么时候", selection: $state.followAI) {
                Text("随时开启").tag(false)
                Text("跟随 AI 工作").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("work-source")
            ForEach(WorkSource.allCases) { source in
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(get: { state.selectedSources.contains(source) },
                                         set: { state.setSource(source, selected: $0) })) {
                        HStack(spacing: 6) {
                            Text(source.clientName)
                            if (state.activeSessionCounts[source] ?? 0) > 0 {
                                ActivityDot(active: true)
                                Text("\(state.activeSessionCounts[source] ?? 0) 个会话").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(!state.followAI && !state.desktopPetEnabled)
                    Spacer()
                    if source.isLocalAgent {
                        Button("接入增强监听") { state.installLocalAgentBridge(source) }.controlSize(.small)
                    } else if let provider = source.hookProvider {
                        Button("安装监听") { state.installHooks(provider) }.controlSize(.small)
                        Button("移除") { state.installHooks(provider, remove: true) }.controlSize(.small)
                    } else {
                        Text("自动读取本地会话").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let message = state.hookSetupMessage {
                Label(message, systemImage: "checkmark.circle")
                    .font(.callout).foregroundStyle(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Toggle("在猫条接收授权与提问", isOn: $state.agentInteractionsEnabled)
                .accessibilityIdentifier("agent-interactions-enabled")
            ForEach([WorkSource.codex, .claude]) { source in
            HStack {
                Text(source.clientName + " 工具交互").font(.callout)
                Spacer()
                let installed = source == .codex ? state.codexInteractionInstalled : state.claudeInteractionInstalled
                Button(installed ? "重新安装" : "安装交互监听") {
                    if source == .codex { state.installCodexInteraction(false) } else { state.installClaudeInteraction(false) }
                }.controlSize(.small).accessibilityIdentifier(source.rawValue + "-interaction-install")
                if installed {
                    Button("移除") {
                        if source == .codex { state.installCodexInteraction(true) } else { state.installClaudeInteraction(true) }
                    }.controlSize(.small)
                }
            }
            }
            Text("Hermes / DSH 自动读取本地记录；增强监听用于准确状态和交互，按安装说明在原客户端启用。Codex 桌面问题卡自动接入。工具授权需安装对应交互监听并重启会话；Codex 只接收人工审核请求。关闭小猫或超时后回到原客户端处理，不会自动批准。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let message = state.agentInteractionSetupMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("跟随 AI")
        } footer: {
            Text("AI 工作时鱼群更活跃、污渍会冒出来；它歇下时水面也安静。桌面小猫也会关注这里勾选的工具，不受小游戏开关影响。Claude Code / Qoder / WorkBuddy 首次使用需安装监听并重启客户端，如有 Hooks 审核提示请在客户端启用。取消勾选停止关注，移除会删除本应用的监听配置。")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var appearance: some View {
        Section("外观") {
            Picker("面板材质", selection: $state.panelMaterial) {
                ForEach(PanelMaterial.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).accessibilityIdentifier("panel-material")
            Text("实色与猫条一致；毛玻璃透出桌面颜色。").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var sound: some View {
        Section("声音") {
            Toggle("音效", isOn: $state.soundEnabled)
            LabeledContent("音量") {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary).font(.caption)
                    Slider(value: $state.volume, in: 0...1).frame(width: 180).accessibilityLabel("音量")
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).font(.caption)
                    Text("\(Int(state.volume * 100))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
                }
            }
            .disabled(!state.soundEnabled)
        }
    }

    private var about: some View {
        Section("关于") {
            LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")
            LabeledContent("软件更新") {
                Button("检查更新…", action: state.checkForUpdates)
                    .disabled(!state.canCheckForUpdates)
                    .accessibilityIdentifier("check-for-updates")
            }
            Toggle("自动检查更新", isOn: Binding(get: { state.automaticallyChecksForUpdates },
                                                   set: { state.setAutomaticUpdateChecks($0) }))
                .accessibilityIdentifier("automatically-checks-for-updates")
            if let date = state.lastUpdateCheck {
                LabeledContent("上次检查") { Text(date, format: .dateTime.month().day().hour().minute()).foregroundStyle(.secondary) }
            }
            LabeledContent("项目主页") {
                Link("GitHub", destination: Self.projectURL)
            }
            Text("AI 负责写代码，人负责不闲着。擦污渍、捏气泡、敲木鱼、钓鱼，主打一个人和 AI 都有事做。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
