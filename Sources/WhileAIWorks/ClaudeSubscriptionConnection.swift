import AppKit
import Combine
import SwiftUI
import AgentHUDCore

enum ClaudeSubscriptionConnection: Equatable {
    case inactive, checking, needsLogin, signedIn, otherLogin, engineMissing, checkFailed
    case signingIn, loginFailed, loginTimedOut
    case needsDesktopAccess, connectingDesktop, desktopExpired

    var message: String {
        switch self {
        case .inactive: return "开启 Claude 关注后自动检查订阅登录。"
        case .checking: return "正在检查 Claude 订阅登录…"
        case .needsLogin: return "尚未找到可复用的 Claude 订阅登录，可在这里手动登录。"
        case .signedIn: return "正在复用已有的 Claude 登录查询订阅额度。"
        case .needsDesktopAccess: return "发现 Claude 桌面端保存的登录。授权读取系统钥匙串后可检查并复用，无需重复登录。"
        case .connectingDesktop: return "请在系统钥匙串提示中允许读取 Claude 登录，以便复用现有订阅。"
        case .desktopExpired: return "Claude 桌面端的订阅凭据需要刷新，请打开 Claude 后重新检测。"
        case .otherLogin: return "已检测到命令行登录，但未确认订阅；API 或中转站登录可能无法提供订阅额度。"
        case .engineMissing: return "未找到可用的桌面订阅登录或 Claude Code，可先打开 Claude 登录。"
        case .checkFailed: return "暂时无法检查 Claude 登录，可以重新检测。"
        case .signingIn: return "请在浏览器完成 Claude 授权，完成后自动刷新额度。"
        case .loginFailed: return "登录未完成，请重试；也可复制命令到终端登录。"
        case .loginTimedOut: return "等待登录已超时，可以重试或在终端登录后重新检测。"
        }
    }

    var offersLogin: Bool {
        switch self {
        case .needsLogin, .otherLogin, .loginFailed, .loginTimedOut: return true
        default: return false
        }
    }

    static func reading(_ status: ClaudeEngineAuthStatus?) -> Self {
        guard let status else { return .checkFailed }
        switch status.authMethod {
        case "desktop_locked": return .needsDesktopAccess
        case "desktop_expired": return .desktopExpired
        case "engine_missing": return .engineMissing
        default: break
        }
        guard status.loggedIn else { return .needsLogin }
        return status.subscriptionType?.isEmpty == false ? .signedIn : .otherLogin
    }
}

/// Checks are automatic; browser authorization starts only from the login button.
/// Uses the same executable, working directory and environment as the quota reader.
@MainActor
final class ClaudeSubscriptionController {
    struct Client {
        var check: () async -> ClaudeEngineAuthStatus?
        var login: () async throws -> ClaudeEngineLoginResult
        var connectDesktop: (() async -> ClaudeEngineAuthStatus?)? = nil
    }

    private let state: AppState
    private let locate: () -> Client?
    private let authenticated: () -> Void
    private var subscriptions = Set<AnyCancellable>()
    private var checkTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var lastAuth: ClaudeEngineAuthStatus?
    private var hasChecked = false
    private var following = false
    private var generation = 0
    private var lastCheck = Date.distantPast

    init(state: AppState, locate: @escaping () -> Client? = ClaudeSubscriptionController.standardClient,
         authenticated: @escaping () -> Void) {
        self.state = state
        self.locate = locate
        self.authenticated = authenticated
        state.checkClaudeSubscription = { [weak self] in self?.check() }
        state.loginClaudeSubscription = { [weak self] in self?.login() }
        state.connectClaudeDesktop = { [weak self] in self?.connectDesktop() }
        state.cancelClaudeSubscriptionLogin = { [weak self] in self?.cancelLogin() }
        state.$selectedSources.map { $0.contains(.claude) }.removeDuplicates()
            .combineLatest(state.$desktopPetEnabled.removeDuplicates(), state.$agentInteractionsEnabled.removeDuplicates())
            .sink { [weak self] value in self?.synchronize(following: value.0) }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self, Date().timeIntervalSince(self.lastCheck) >= 15 else { return }
                self.check()
            }.store(in: &subscriptions)
    }

    nonisolated static func standardClient() -> Client? {
        let engine = ClaudeEngineLocator.find().map {
            ClaudeEngineUsageClient(executable: $0, workingDirectory: ClaudeEngineUsageClient.defaultWorkingDirectory)
        }
        return Client(check: {
            await existingLogin(desktop: .shared, engine: engine, refresh: true)
        }, login: {
            guard let engine else { return .failed }
            return try await engine.signInToSubscription()
        }, connectDesktop: {
            await withTaskCancellationHandler {
                _ = await ClaudeDesktopUsageClient.shared.fetch(authorize: true)
                return await existingLogin(desktop: .shared, engine: engine)
            } onCancel: {
                Task { await ClaudeDesktopUsageClient.shared.invalidate() }
            }
        })
    }

    nonisolated static func existingLogin(desktop: ClaudeDesktopUsageClient, engine: ClaudeEngineUsageClient?, refresh: Bool = false) async -> ClaudeEngineAuthStatus? {
        let reply = await desktop.fetch(refresh: refresh)
        if reply.status == .available { return .init(loggedIn: true, authMethod: "desktop", subscriptionType: reply.plan ?? "subscription") }
        let status = await engine?.authStatus()
        if status?.loggedIn == true, status?.subscriptionType?.isEmpty == false { return status }
        switch reply.status {
        case .locked: return .init(loggedIn: false, authMethod: "desktop_locked", subscriptionType: nil)
        case .expired: return .init(loggedIn: false, authMethod: "desktop_expired", subscriptionType: nil)
        case .failed, .accountChanged: return nil // A network or schema failure is not evidence of logout.
        default: return status ?? (engine == nil ? .init(loggedIn: false, authMethod: "engine_missing", subscriptionType: nil) : nil)
        }
    }

    nonisolated static func terminalLoginCommand(executable: URL? = ClaudeEngineLocator.find(),
                                                 environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        // Use the same configuration home as the app, even if the user's interactive shell chooses another.
        // Explicitly unsetting the variable also preserves Claude's default ~/.claude.json profile location.
        let directory = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let prefix = directory.map { "/usr/bin/env " + quote("CLAUDE_CONFIG_DIR=" + $0) }
            ?? "/usr/bin/env -u CLAUDE_CONFIG_DIR"
        return prefix + " " + quote(executable?.path ?? "claude") + " auth login --claudeai"
    }

    private func synchronize(following: Bool) {
        self.following = following
        guard following else {
            cancelTasks(); lastAuth = nil; hasChecked = false
            state.claudeSubscriptionConnection = .inactive
            return
        }
        check()
    }

    func check() {
        guard following, checkTask == nil, loginTask == nil else { return }
        guard let client = locate() else { hasChecked = true; state.claudeSubscriptionConnection = .engineMissing; return }
        let generation = self.generation
        state.claudeSubscriptionConnection = .checking
        lastCheck = Date()
        checkTask = Task { [weak self] in
            let status = await client.check()
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.checkTask = nil
            self.apply(status)
        }
    }

    private func apply(_ status: ClaudeEngineAuthStatus?, afterLogin: Bool = false) {
        let changed = hasChecked && lastAuth != status
        hasChecked = true
        state.claudeSubscriptionConnection = ClaudeSubscriptionConnection.reading(status)
        // Unknown or transient failures are not a logout and must not erase the last known identity metadata.
        if let status { lastAuth = status }
        if status?.loggedIn == true, afterLogin || changed { authenticated() }
    }

    func login() {
        guard following, loginTask == nil else { return }
        guard let client = locate() else { state.claudeSubscriptionConnection = .engineMissing; return }
        cancelTasks()
        let generation = self.generation
        state.claudeSubscriptionConnection = .signingIn
        loginTask = Task { [weak self] in
            let result: ClaudeEngineLoginResult
            do { result = try await client.login() }
            catch { result = .failed }
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            switch result {
            case .completed:
                let status = await client.check()
                guard !Task.isCancelled, self.generation == generation else { return }
                self.apply(status, afterLogin: true)
            case .failed: self.state.claudeSubscriptionConnection = .loginFailed
            case .timedOut: self.state.claudeSubscriptionConnection = .loginTimedOut
            }
            self.loginTask = nil
        }
    }

    func cancelLogin() { cancelTasks(); check() }

    func connectDesktop() {
        guard following, loginTask == nil, let connect = locate()?.connectDesktop else { return }
        cancelTasks()
        let generation = self.generation
        state.claudeSubscriptionConnection = .connectingDesktop
        loginTask = Task { [weak self] in
            let status = await connect()
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.apply(status, afterLogin: true)
            self.loginTask = nil
        }
    }

    private func cancelTasks() {
        generation += 1
        checkTask?.cancel(); checkTask = nil
        loginTask?.cancel(); loginTask = nil
    }

    func stop() {
        following = false
        cancelTasks(); subscriptions.removeAll()
    }
}

struct ClaudeSubscriptionConnectionView: View {
    @ObservedObject var state: AppState
    var compact = false
    @State private var copied = false
    private var connection: ClaudeSubscriptionConnection { state.claudeSubscriptionConnection }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(connection.message).font(compact ? .system(size: 11) : .callout)
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("claude-subscription-status")
            HStack(spacing: 12) {
                if connection == .needsDesktopAccess {
                    Button("复用 Claude 桌面登录", action: state.connectClaudeDesktop)
                        .accessibilityIdentifier("claude-desktop-connect")
                } else if connection.offersLogin {
                    Button("登录 Claude 订阅", action: state.loginClaudeSubscription)
                        .accessibilityIdentifier("claude-subscription-login")
                    Button(copied ? "已复制" : "复制登录命令") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ClaudeSubscriptionController.terminalLoginCommand(), forType: .string)
                        copied = true
                    }.accessibilityIdentifier("claude-subscription-copy-command")
                } else if connection == .signingIn || connection == .connectingDesktop {
                    ProgressView().controlSize(.small)
                    Button("取消", action: state.cancelClaudeSubscriptionLogin)
                        .accessibilityIdentifier("claude-subscription-cancel")
                } else if connection == .engineMissing {
                    Link("安装 Claude Code", destination: URL(string: "https://code.claude.com/docs/en/setup")!)
                }
                if connection == .desktopExpired || connection == .engineMissing {
                    Button("打开 Claude") {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
                            NSWorkspace.shared.openApplication(at: url, configuration: .init())
                        }
                    }
                }
                if connection != .inactive && connection != .checking && connection != .signingIn && connection != .connectingDesktop {
                    Button("重新检测", action: state.checkClaudeSubscription)
                        .accessibilityIdentifier("claude-subscription-check")
                }
            }.controlSize(.small).font(compact ? .system(size: 10) : .caption)
            if !compact {
                Text("优先复用 Claude 桌面端，其次复用 Claude Code。启动和监听开关只做静默检测；钥匙串授权或登录仅在手动点击后进行。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.onChange(of: connection) { _, _ in copied = false }
    }
}
