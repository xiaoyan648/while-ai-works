import Foundation

/// The commands a client's hooks run, and the adapter commands that install them without starting the application:
/// short-lived processes that leave what a client sent for the running application, or hand it over and wait for the
/// answer, and quit. None of them starts the interface, queries an account or holds up the client. A host runs them
/// first thing at launch.
public enum HookEntry {
    /// Runs the command `arguments` name — the process's arguments, its executable first — and returns its exit status;
    /// nil when they name none, and the application starts.
    public static func handle(arguments: [String]) -> Int32? {
        if arguments.contains("--install-pi-observer") {
            do {
                try PiSessionObserver.configure(enabled: true)
                print("Pi session observer installed. Run /reload in existing Pi sessions.")
                return 0
            } catch {
                FileHandle.standardError.write(Data("Could not install Pi session observer: \(error.localizedDescription)\n".utf8))
                return 1
            }
        }
        guard arguments.count == 3 else { return nil }
        let name = arguments[2]
        switch arguments[1] {
        case "--session-origin-hook":
            switch name {
            case "codex": try? CodexSessionOrigins.record(data: input())
            case "claude": try? ClaudeSessionOrigins.record(data: input())
            default: return nil
            }
            print("{}")
            return 0
        case "--completion-hook":
            guard let source = CompletionHooks.Source(rawValue: name) else { return nil }
            // Local status tracking must not affect the agent's execution.
            try? CompletionHooks.record(source: source, data: input())
            print(source == .antigravity ? #"{"decision":"stop"}"# : "{}")
            return 0
        case "--attention-hook":
            guard let source = AttentionHooks.Source(rawValue: name) else { return nil }
            try? AttentionHooks.record(source: source, data: input())
            print("{}")
            return 0
        case "--permission-hook":
            // The client waits on this one: it holds the request open until the user answers on the HUD, and prints
            // nothing when it cannot be answered, which leaves the client's own permission prompt exactly as it was.
            guard let source = PermissionHooks.Source(rawValue: name) else { return nil }
            guard source.usesHook else { return 0 }
            PermissionHookClient.run(source: source)
            return 0
        case "--install-completion-hook":
            guard let source = CompletionHooks.Source(rawValue: name) else { return nil }
            do {
                try CompletionHooks.configure(source, enabled: true, executable: URL(fileURLWithPath: arguments[0]).standardizedFileURL)
                print("Completion hook installed: \(source.rawValue)")
                return 0
            } catch {
                FileHandle.standardError.write(Data("Could not install completion hook: \(error.localizedDescription)\n".utf8))
                return 1
            }
        default:
            return nil
        }
    }

    /// Standard input, read until it ends or grows past the largest payload a record is made from.
    static func input() throws -> Data {
        var data = Data()
        while let chunk = try FileHandle.standardInput.read(upToCount: 64 * 1024), !chunk.isEmpty {
            data.append(chunk)
            if data.count > HookInbox.payloadLimit { break }
        }
        return data
    }
}
