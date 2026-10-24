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
                Text("会话用量从本机记录读取；账户额度仅在客户端支持时显示。回复仅在本机内存展示，关闭后隐藏正文。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("刷新用量", action: state.refreshAgentData)
            }
            controls
            desktop
            AgentSettingsSections(state: state)
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
