import Foundation

/// Hook files that follow Claude Code's settings layout: `hooks.<Event>` is a list of matcher groups, each with a
/// `hooks` list of command handlers. Agent HUD adds a group whose only handler runs its command, and afterwards changes
/// nothing in it but the command.
enum ClaudeStyleHooks {
    /// The commands of the handlers `owns` names under `hooks.<event>`.
    static func commands(in configuration: [String: ProviderJSON], event: String, owns: (String?) -> Bool) -> [String] {
        (configuration["hooks"]?[event].arrayValue ?? []).flatMap { $0["hooks"].arrayValue ?? [] }
            .compactMap { $0["command"].stringValue }.filter(owns)
    }

    /// The configuration with the handlers `owns` names under `hooks.<event>` set to `command`, or taken out for nil:
    /// the first one takes the command and keeps the matcher, timeout and anything else the user set, and without one
    /// `group` makes a matcher group for it. An unrecognized layout throws.
    static func updating(_ configuration: [String: ProviderJSON], event: String, owns: (String?) -> Bool, command: String?,
                         group: (String) -> ProviderJSON) throws -> [String: ProviderJSON] {
        var object = configuration
        guard object["hooks"] == nil || object["hooks"]?.objectValue != nil else { throw ProviderFailure.format }
        var hooks = object["hooks"]?.objectValue ?? [:]
        guard hooks[event] == nil || hooks[event]?.arrayValue != nil else { throw ProviderFailure.format }
        let groups = setting(command, in: hooks[event]?.arrayValue ?? [], owns: owns, group: group)
        hooks[event] = groups.isEmpty ? nil : .array(groups)
        object["hooks"] = hooks.isEmpty && configuration["hooks"] == nil ? nil : .object(hooks)
        return object
    }

    /// A matcher group of Agent HUD's alone: one command handler with `timeout`, in the client's own unit (seconds for
    /// Claude Code's forks, milliseconds for Qwen Code).
    static func group(timeout: Int) -> (String) -> ProviderJSON {
        { command in .object(["hooks": .array([.object(["type": .string("command"), "command": .string(command), "timeout": .integer(Int64(timeout))])])]) }
    }

    /// Agent HUD's handlers among `handlers`, whichever copy wrote them, set to `command`: the first one `owns` names
    /// takes the command under `key` and keeps everything else in it, such as a timeout the user changed; the others go,
    /// and with no command all of them go. `placed` turns true once a handler has taken the command.
    static func setting(_ command: String?, in handlers: [ProviderJSON], key: String = "command",
                        owns: (String?) -> Bool, placed: inout Bool) -> [ProviderJSON] {
        handlers.compactMap { handler in
            guard owns(handler[key].stringValue) else { return handler }
            guard let command, !placed, var fields = handler.objectValue else { return nil }
            placed = true
            fields[key] = .string(command)
            return .object(fields)
        }
    }

    /// The same across matcher groups: the group holding the handler keeps its matcher and every other key, a group
    /// Agent HUD's handlers leave empty goes, and `group` makes a new one when no handler took the command.
    static func setting(_ command: String?, in groups: [ProviderJSON], owns: (String?) -> Bool,
                        group: (String) -> ProviderJSON) -> [ProviderJSON] {
        var placed = false
        var result = groups.compactMap { group -> ProviderJSON? in
            guard var fields = group.objectValue, let handlers = fields["hooks"]?.arrayValue else { return group }
            let kept = setting(command, in: handlers, owns: owns, placed: &placed)
            if kept == handlers { return group }
            if kept.isEmpty { return nil }
            fields["hooks"] = .array(kept)
            return .object(fields)
        }
        if let command, !placed { result.append(group(command)) }
        return result
    }
}
