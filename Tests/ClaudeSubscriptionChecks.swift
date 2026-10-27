import AppKit
import Foundation
import AgentHUDCore
import AgentHUDSupport
import WhileCore

@main enum ClaudeSubscriptionChecks {
    @MainActor static func eventually(_ condition: () -> Bool, _ message: String) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        fatalError(message)
    }

    static func status(_ json: String) -> ClaudeEngineAuthStatus {
        try! JSONDecoder().decode(ClaudeEngineAuthStatus.self, from: Data(json.utf8))
    }

    @MainActor static func main() async throws {
        _ = NSApplication.shared
        L10n.setLanguage(.zhHans)
        AgentCommandEnvironment.configure()
        if CommandLine.arguments.contains("--live-auth-probe") {
            let client = ClaudeSubscriptionController.standardClient()
            let connection: ClaudeSubscriptionConnection
            if let client { connection = .reading(await client.check()) } else { connection = .engineMissing }
            print("Claude authentication check: \(connection.message)")
            return
        }

        let signedOut = status(#"{"loggedIn":false,"authMethod":"none"}"#)
        let signedIn = status(#"{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"pro","apiProvider":"firstParty"}"#)
        let token = status(#"{"loggedIn":true,"authMethod":"oauth_token","subscriptionType":null}"#)
        precondition(ClaudeSubscriptionConnection.reading(token) == .otherLogin,
                     "a terminal token must not be mistaken for a subscription")
        precondition(ClaudeSubscriptionConnection.reading(nil) == .checkFailed,
                     "a failed check must not claim logout")
        precondition(!ClaudeDataError.signedOut.localizedDescription.contains("已退出登录"))
        let command = ClaudeSubscriptionController.terminalLoginCommand(executable: URL(fileURLWithPath: "/fixture/User's tools/claude"), environment: [:])
        precondition(command == "/usr/bin/env -u CLAUDE_CONFIG_DIR '/fixture/User'\"'\"'s tools/claude' auth login --claudeai")
        let profileCommand = ClaudeSubscriptionController.terminalLoginCommand(executable: URL(fileURLWithPath: "/fixture/claude"), environment: ["CLAUDE_CONFIG_DIR": "/fixture/work profile"])
        precondition(profileCommand.contains("'CLAUDE_CONFIG_DIR=/fixture/work profile'"))

        let suite = "WhileAIWorks.ClaudeSubscriptionChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(defaults: defaults)
        state.selectedSources = [.claude]
        var reading: ClaudeEngineAuthStatus? = signedOut
        var checks = 0, logins = 0, refreshed = 0, cancelled = 0
        var holdCheck = false, holdLogin = false
        var result = ClaudeEngineLoginResult.completed
        var available = true
        let controller = ClaudeSubscriptionController(state: state, locate: {
            guard available else { return nil }
            return .init(check: {
                checks += 1
                let captured = reading
                while holdCheck { try? await Task.sleep(for: .milliseconds(10)); if Task.isCancelled { break } }
                return captured
            }, login: {
                logins += 1
                do { while holdLogin { try await Task.sleep(for: .milliseconds(10)) } }
                catch { cancelled += 1; throw error }
                return result
            })
        }, authenticated: { refreshed += 1 })
        defer { controller.stop() }
        await eventually({ state.claudeSubscriptionConnection == .needsLogin }, "startup must check login")
        precondition(checks == 1 && logins == 0 && refreshed == 0, "startup never launches authorization")

        holdCheck = true
        state.checkClaudeSubscription(); state.checkClaudeSubscription(); state.checkClaudeSubscription()
        await eventually({ checks == 2 }, "manual check started")
        state.selectedSources = []
        holdCheck = false
        try await Task.sleep(for: .milliseconds(30))
        precondition(state.claudeSubscriptionConnection == .inactive, "disabled source ignores an in-flight result")
        state.selectedSources = [.claude]
        await eventually({ state.claudeSubscriptionConnection == .needsLogin }, "enabling Claude rechecks")
        let before = checks
        state.desktopPetEnabled.toggle()
        await eventually({ checks > before && state.claudeSubscriptionConnection == .needsLogin }, "starting the cat bar rechecks")
        let beforeToggle = checks
        state.agentInteractionsEnabled.toggle()
        await eventually({ checks > beforeToggle && state.claudeSubscriptionConnection == .needsLogin }, "listener switch rechecks")

        holdLogin = true
        state.loginClaudeSubscription(); state.loginClaudeSubscription()
        await eventually({ logins == 1 }, "login started once")
        precondition(state.claudeSubscriptionConnection == .signingIn)
        state.cancelClaudeSubscriptionLogin()
        await eventually({ cancelled == 1 && state.claudeSubscriptionConnection == .needsLogin }, "cancel stops login and rechecks")
        holdLogin = false
        result = .timedOut
        state.loginClaudeSubscription()
        await eventually({ state.claudeSubscriptionConnection == .loginTimedOut }, "timeout is visible and retryable")
        precondition(refreshed == 0)
        result = .failed
        state.loginClaudeSubscription()
        await eventually({ state.claudeSubscriptionConnection == .loginFailed }, "failure is visible")
        result = .completed
        state.loginClaudeSubscription()
        await eventually({ state.claudeSubscriptionConnection == .needsLogin }, "exit success alone is not proof of sign-in")
        precondition(refreshed == 0)

        reading = signedIn
        state.loginClaudeSubscription()
        await eventually({ state.claudeSubscriptionConnection == .signedIn }, "successful login is verified")
        precondition(refreshed == 1, "successful login refreshes quota immediately")
        state.checkClaudeSubscription()
        await eventually({ state.claudeSubscriptionConnection == .signedIn }, "repeat check completes")
        precondition(refreshed == 1, "focus and repeated checks cannot repeatedly reset quota collection")
        reading = nil; state.checkClaudeSubscription()
        await eventually({ state.claudeSubscriptionConnection == .checkFailed }, "unknown is not logout")
        reading = signedIn; state.checkClaudeSubscription()
        await eventually({ state.claudeSubscriptionConnection == .signedIn }, "transient failure recovers")
        precondition(refreshed == 1)
        reading = signedOut; state.checkClaudeSubscription()
        await eventually({ state.claudeSubscriptionConnection == .needsLogin }, "external sign-out detected")
        reading = signedIn; state.checkClaudeSubscription()
        await eventually({ refreshed == 2 }, "external terminal login also refreshes quota")

        holdLogin = true; state.loginClaudeSubscription()
        await eventually({ logins == 6 }, "second pending login started")
        state.selectedSources = []
        await eventually({ cancelled == 2 }, "disabling listener stops pending login")
        precondition(state.claudeSubscriptionConnection == .inactive && refreshed == 2)
        available = false; state.selectedSources = [.claude]
        precondition(state.claudeSubscriptionConnection == .engineMissing)
        available = true; state.checkClaudeSubscription()
        await eventually({ refreshed == 3 }, "installing and logging into a previously missing CLI refreshes the provider")
        controller.stop()

        // Exercise the actual process adapter against an isolated fake CLI, including no trailing newline,
        // signed-out exit 1, malformed output, login exit codes, timeout and process cancellation.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Claude Check ' " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("claude")
        let mode = root.appendingPathComponent("mode")
        try """
        #!/bin/sh
        mode=$(/bin/cat mode)
        if [ "$1 $2" = 'auth status' ]; then
          case "$mode" in
            out) printf '%s' '{"loggedIn":false}'; exit 1 ;;
            in) printf '%s' '{"loggedIn":true,"subscriptionType":"pro"}'; exit 0 ;;
            bad) printf '%s' 'not json'; exit 0 ;;
            error) printf '%s' '{"loggedIn":false}'; exit 2 ;;
          esac
        elif [ "$1 $2 $3" = 'auth login --claudeai' ]; then
          case "$mode" in
            in) exit 0 ;;
            bad) exit 2 ;;
            wait) echo $$ > login.pid; exec /bin/sleep 30 ;;
          esac
        fi
        exit 3
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let engine = ClaudeEngineUsageClient(executable: executable, workingDirectory: root)
        func setMode(_ value: String) throws { try value.write(to: mode, atomically: true, encoding: .utf8) }
        try setMode("out")
        let out = await engine.authStatus(); precondition(out?.loggedIn == false)
        try setMode("in")
        let connected = await engine.authStatus(); precondition(connected?.subscriptionType == "pro")
        let success = try await engine.signInToSubscription(); precondition(success == .completed)
        try setMode("bad")
        let malformed = await engine.authStatus(); precondition(malformed == nil)
        let failure = try await engine.signInToSubscription(); precondition(failure == .failed)
        try setMode("error")
        let error = await engine.authStatus(); precondition(error == nil)
        try setMode("wait")
        let timeout = try await engine.signInToSubscription(timeout: 0.1); precondition(timeout == .timedOut)
        let timedOutPID = pid_t(try String(contentsOf: root.appendingPathComponent("login.pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        await eventually({ kill(timedOutPID, 0) != 0 }, "timed-out login process must stop")
        try FileManager.default.removeItem(at: root.appendingPathComponent("login.pid"))
        let pending = Task { try await engine.signInToSubscription() }
        await eventually({ FileManager.default.fileExists(atPath: root.appendingPathComponent("login.pid").path) }, "child process starts")
        let cancelledPID = pid_t(try String(contentsOf: root.appendingPathComponent("login.pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        pending.cancel()
        do { _ = try await pending.value; fatalError("cancellation must propagate") } catch is CancellationError { }
        await eventually({ kill(cancelledPID, 0) != 0 }, "cancelled login process must stop")
        print("ClaudeSubscriptionChecks: startup, switches, deduplication, verified refresh, failures and subprocess cleanup passed")
    }
}
