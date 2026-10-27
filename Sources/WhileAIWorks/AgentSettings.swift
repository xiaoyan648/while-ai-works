import AppKit
import SwiftUI
import WhileCore
import AgentHUDCore
import AgentHUDSupport

/// Local configuration evidence only. Reading settings never installs or enables a hook.
struct AgentSettingsSnapshot {
    var loaded = false
    var hooks: [WorkSource: HookInstallation.Status] = [:]
    var hookEvents: [WorkSource: Date] = [:]
    var interactions = Set<WorkSource>()
    var exported = Set<WorkSource>()
    var pluginFiles = Set<WorkSource>()
    var localRecords = Set<WorkSource>()
    var bridgeEvents: [WorkSource: Date] = [:]

    static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        var value = Self(loaded: true)
        let fm = FileManager.default
        let integrationRoot = home.appendingPathComponent("Library/Application Support/While AI Works/Integrations")
        let hookRoot = home.appendingPathComponent("Library/Application Support/While AI Works/Hooks")
        for source in WorkSource.allCases {
            if let provider = source.hookProvider {
                value.hooks[source] = HookInstallation.status(provider: provider, home: home)
                value.hookEvents[source] = HookBridge.sessions(provider: provider, directory: hookRoot).values.map(\.updatedAt).max()
            }
        }
        for (source, variable, directory, filename) in [(WorkSource.codex, "CODEX_HOME", ".codex", "hooks.json"), (.claude, "CLAUDE_CONFIG_DIR", ".claude", "settings.json")] {
            let root = environment[variable].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(directory)
            if AgentInteractionHookInstallation.isInstalled(at: root.appendingPathComponent(filename), source: source) {
                value.interactions.insert(source)
            }
        }
        let hermes = environment["HERMES_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".hermes")
        let dsh = DeepSeekLocator.dataDirectory(environment: environment, home: home)
        for (source, root) in [(WorkSource.hermes, hermes), (.dsh, dsh)] {
            if fm.fileExists(atPath: integrationRoot.appendingPathComponent(source.rawValue).path) { value.exported.insert(source) }
            let roots = source == .hermes ? HermesLocalData.roots(root) : [root]
            for profile in roots {
                let records = profile.appendingPathComponent(source == .hermes ? "state.db" : "sessions")
                if fm.fileExists(atPath: records.path) { value.localRecords.insert(source) }
                if source == .hermes {
                    let plugin = profile.appendingPathComponent("plugins/while-ai-works")
                    if ["__init__.py", "plugin.yaml"].allSatisfy({ fm.fileExists(atPath: plugin.appendingPathComponent($0).path) }) {
                        value.pluginFiles.insert(source)
                    }
                }
                let folder = profile.appendingPathComponent("while-ai-works")
                let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
                // Inspect a bounded set of recent lifecycle records, never transcripts or credentials.
                let recent = files.filter { $0.pathExtension == "json" }.sorted {
                    ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                        > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                }.prefix(32)
                for file in recent {
                    guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 16_384,
                          let data = try? Data(contentsOf: file),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let id = object["session_id"] as? String,
                          let record = LocalAgentBridgeRecord.read(source: source, rawID: id, root: profile, now: Date()) else { continue }
                    value.bridgeEvents[source] = max(value.bridgeEvents[source] ?? .distantPast, record.at)
                }
            }
        }
        return value
    }

    func statusSummary(for source: WorkSource) -> String {
        guard loaded else { return "正在检测本机接入配置…" }
        if source == .codex { return "自动读取本地会话" }
        if source.isLocalAgent {
            return bridgeEvents[source] == nil ? "自动读取本地会话" : "本地会话 · 已收到增强监听事件"
        }
        switch hooks[source] ?? .absent {
        case .absent: return "工作状态监听未配置"
        case .partial: return "工作状态监听配置不完整"
        case .disabled: return "原客户端已禁用 Hooks"
        case .missingHelper: return "监听组件缺失 · 需要重新安装"
        case .unreadable: return "无法读取监听配置"
        case .configured: return hookEvents[source] == nil ? "配置已写入 · 待客户端验证" : "最近已收到工作状态事件"
        }
    }
}

struct AgentSettingsSections: View {
    @ObservedObject var state: AppState
    @State private var configuring: WorkSource?
    @State private var snapshot = AgentSettingsSnapshot()
    @State private var refreshID = 0
    var fixture: AgentSettingsSnapshot? = nil

    var body: some View {
        Group {
            Section {
                Picker("启动方式", selection: $state.followAI) {
                    Text("随时开启").tag(false)
                    Text("跟随 AI 工作").tag(true)
                }.pickerStyle(.segmented).accessibilityIdentifier("work-source")
            } header: { Text("小游戏启动时机") } footer: {
                footer("只影响小游戏；猫条始终使用下方的关注列表。")
            }
            .sheet(item: $configuring) { source in
                AgentConfigurationView(state: state, source: source, snapshot: fixture ?? snapshot,
                                       refresh: { refreshID += 1 }, dismiss: { configuring = nil })
            }
            .task(id: refreshID) {
                guard fixture == nil else { return }
                let result = await Task.detached(priority: .utility) { AgentSettingsSnapshot.read() }.value
                guard !Task.isCancelled else { return }
                snapshot = result
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshID += 1 }
            Section {
                ForEach(WorkSource.dockOrder) { source in
                    AgentSettingsRow(state: state, source: source,
                                     summary: (fixture ?? snapshot).statusSummary(for: source)) { configuring = source }
                }
                if state.selectedSources.contains(.claude) && state.claudeSubscriptionConnection != .signedIn && state.claudeSubscriptionConnection != .inactive {
                    ClaudeSubscriptionConnectionView(state: state)
                }
            } header: { Text("关注的 Agent") } footer: {
                footer("关注开关控制猫条和工作状态检测，不会安装或移除接入配置。")
            }
            Section {
                Toggle("在猫条接收授权与提问", isOn: $state.agentInteractionsEnabled)
                    .accessibilityIdentifier("agent-interactions-enabled")
                if let message = state.agentInteractionSetupMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: { Text("授权与提问") } footer: {
                footer("需要开启桌面陪伴，并在对应 Agent 的配置中完成接入。仅接收已关注且支持交互的 Agent；关闭或超时后回到原客户端，不会自动批准。")
            }
        }
    }
    private func footer(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct AgentSettingsRow: View {
    @ObservedObject var state: AppState
    let source: WorkSource
    let summary: String
    var configure: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            AgentMark(source: source, size: 24).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(source.clientName).font(.body)
                Text(summary).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("配置…", action: configure)
                .controlSize(.small).fixedSize()
                .accessibilityLabel("配置 " + source.clientName)
                .accessibilityIdentifier("agent-configure-" + source.rawValue)
            Toggle("关注 " + source.clientName,
                   isOn: Binding(get: { state.selectedSources.contains(source) }, set: { state.setSource(source, selected: $0) }))
                .toggleStyle(.switch).labelsHidden().fixedSize()
                .accessibilityLabel("关注 " + source.clientName)
                .accessibilityIdentifier("agent-follow-" + source.rawValue)
        }.padding(.vertical, 3)
    }
}

struct AgentConfigurationView: View {
    @ObservedObject var state: AppState
    let source: WorkSource
    let snapshot: AgentSettingsSnapshot
    var refresh: () -> Void
    var dismiss: () -> Void
    @State private var feedback: String?
    private var interactionInstalled: Bool { snapshot.interactions.contains(source) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                AgentMark(source: source, size: 28)
                Text(source.clientName + " 接入配置").font(.title3.weight(.semibold))
                Spacer()
                Button("完成", action: dismiss).keyboardShortcut(.defaultAction)
            }.padding(20)
            Form {
                if source == .claude {
                    Section("订阅额度") { ClaudeSubscriptionConnectionView(state: state) }
                }
                Section("工作状态") {
                    if source == .codex || source.isLocalAgent {
                        Text("自动读取本地会话，无需安装状态监听。")
                        if source.isLocalAgent {
                            Text(snapshot.localRecords.contains(source) ? "已找到本地记录。增强监听可补充准确状态和完成提醒。" : "尚未找到本地记录；请在原客户端开始一次会话。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else if let provider = source.hookProvider {
                        Text(snapshot.statusSummary(for: source))
                        if let date = snapshot.hookEvents[source] { eventDate("最近状态事件", date: date) }
                        HStack {
                            Button(snapshot.hooks[source]?.hasConfiguration == true ? "重新安装状态监听" : "安装状态监听") {
                                state.installHooks(provider); feedback = state.hookSetupMessage; refresh()
                                if source == .claude { state.checkClaudeSubscription() }
                            }.accessibilityIdentifier("status-install-" + source.rawValue)
                            if snapshot.hooks[source]?.hasConfiguration == true {
                                Button("移除状态监听") {
                                    state.installHooks(provider, remove: true); feedback = state.hookSetupMessage; refresh()
                                    if source == .claude { state.checkClaudeSubscription() }
                                }.accessibilityIdentifier("status-remove-" + source.rawValue)
                            }
                        }.disabled(!snapshot.loaded)
                        Text("安装后重启原客户端；若有 Hooks 审核提示，请在客户端启用。配置写入成功不代表已收到事件。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if source.isLocalAgent {
                    Section("增强监听") {
                        if let date = snapshot.bridgeEvents[source] {
                            Text("已收到增强监听事件")
                            eventDate("最近一次", date: date)
                            Text("这是事件接收记录，不代表当前客户端正在运行。授权与提问仍取决于原客户端的配置和能力。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(snapshot.pluginFiles.contains(source) ? "插件文件已放置 · 尚未验证" : snapshot.exported.contains(source) ? "插件已导出 · 尚未验证安装" : "尚未检测到增强监听事件")
                        }
                        Button("导出插件与接入说明") {
                            state.installLocalAgentBridge(source); feedback = state.agentInteractionSetupMessage; state.agentInteractionSetupMessage = nil; refresh()
                        }.accessibilityIdentifier("bridge-setup-" + source.rawValue)
                        Text("按说明在实际使用的客户端或 profile 中安装、重新安装或移除本应用插件。导出文件不会自动启用插件；开始一次会话后点“重新检测”。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("授权与提问") {
                    if source == .codex || source == .claude {
                        Text(source == .codex ? "Codex 桌面问题卡自动接入；人工审核工具授权需安装交互监听。" : "授权请求需要交互监听；它与上方的工作状态监听分别配置。")
                        Text(interactionInstalled ? "交互监听配置已写入 · 是否生效以实际请求为准" : "交互监听未配置")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(interactionInstalled ? "重新安装交互监听" : "安装交互监听") { installInteraction(remove: false) }
                                .accessibilityIdentifier(source.rawValue + "-interaction-install")
                            if interactionInstalled {
                                Button("移除交互监听") { installInteraction(remove: true) }
                                    .accessibilityIdentifier(source.rawValue + "-interaction-remove")
                            }
                        }.disabled(!snapshot.loaded)
                    } else if source == .hermes {
                        Text("工具授权需在 Hermes 配置 approval transport；原生提问仍在 Hermes 处理。具体步骤见增强监听说明。")
                    } else if source == .dsh {
                        Text("增强监听可接收工具授权与提问；请在实际使用的 DSH profile 中启用插件和相应工具。")
                    } else {
                        Text("当前仅支持工作状态，授权与提问请在原客户端处理。")
                    }
                }
                if let feedback { Section("操作结果") { Text(feedback).font(.callout).textSelection(.enabled) } }
            }.formStyle(.grouped)
            HStack {
                Button("重新检测") {
                    refresh()
                    if source == .claude { state.checkClaudeSubscription() }
                }.accessibilityIdentifier("agent-setup-refresh")
                Spacer()
                Text("仅管理本应用的接入配置").font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }
        .frame(width: 500, height: 580)
        .tint(Theme.accent)
    }
    private func eventDate(_ title: String, date: Date) -> some View {
        HStack { Text(title); Text(date, format: .dateTime.month().day().hour().minute()) }
            .font(.caption).foregroundStyle(.secondary)
    }
    private func installInteraction(remove: Bool) {
        if source == .codex { state.installCodexInteraction(remove) } else { state.installClaudeInteraction(remove) }
        if source == .claude { state.checkClaudeSubscription() }
        feedback = state.agentInteractionSetupMessage; state.agentInteractionSetupMessage = nil; refresh()
    }
}
