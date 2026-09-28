import Foundation
import CryptoKit
import Darwin

public enum HookProvider: String, CaseIterable {
    case qoder, workbuddy, claude
    public var title: String {
        switch self {
        case .qoder: return "Qoder"
        case .workbuddy: return "WorkBuddy"
        case .claude: return "Claude Code"
        }
    }
    public var events: [String] {
        ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"]
            + (self == .claude ? ["PostToolUseFailure", "StopFailure"] : [])
    }
}

/// Only hashed identifiers, lifecycle state and counters cross the hook boundary.
public struct HookSession: Codable {
    public var working: Bool
    public var updatedAt: Date
    public var generation: String?
    public var count: Int
    public var phase: WorkPhase?
}

public enum HookBridge {
    /// Fall back to idle after five minutes without an accepted lifecycle event.
    public static let inactivityTimeout: TimeInterval = 5 * 60
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/While AI Works/Hooks")
    }
    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func record(_ input: Data, provider: HookProvider, directory: URL = directory,
                              now: Date = Date()) throws {
        guard input.count <= 1_048_576,
              let json = try JSONSerialization.jsonObject(with: input) as? [String: Any],
              let event = json["hook_event_name"] as? String, provider.events.contains(event),
              let id = json["session_id"] as? String, !id.isEmpty, id.count <= 4096 else { return }
        let fm = FileManager.default
        let folder = directory.appendingPathComponent(provider.rawValue)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = open(folder.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { return }
        defer { flock(lock, LOCK_UN); close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { return }
        let path = folder.appendingPathComponent(digest(id) + ".json")
        let previous = (try? Data(contentsOf: path)).flatMap { try? JSONDecoder().decode(HookSession.self, from: $0) }
        // WorkBuddy's generation_id is session.messageId: it changes after tool calls
        // within one user turn. Its lifecycle is tracked by the stable session_id.
        // Claude Code also tracks turns by session_id; no generation field is required.
        let generation = provider != .qoder ? nil
            : (json["generation_id"] as? String ?? json["turn_id"] as? String).map(digest)
        if event != "UserPromptSubmit", event != "SessionEnd",
           let old = previous?.generation, let generation, old != generation { return }
        let working = !["Stop", "StopFailure", "SessionEnd"].contains(event)
        let state = HookSession(working: working, updatedAt: now,
                                generation: provider != .qoder ? nil : generation ?? previous?.generation,
                                count: min(previous?.count ?? 0, 1_000_000_000) + 1,
                                phase: event == "PreToolUse" ? .tool : .running)
        try JSONEncoder().encode(state).write(to: path, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        // Keep no history beyond one day, and avoid an ever-growing event log.
        if let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for file in files where file.pathExtension == "json" && file != path {
                if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   date < now.addingTimeInterval(-86400) { try? fm.removeItem(at: file) }
            }
        }
    }

    public static func sessions(provider: HookProvider, directory: URL = directory, now: Date = Date()) -> [String: HookSession] {
        let folder = directory.appendingPathComponent(provider.rawValue)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var result: [String: HookSession] = [:]
        for file in files where file.pathExtension == "json" {
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4096,
                  let data = try? Data(contentsOf: file),
                  let state = try? JSONDecoder().decode(HookSession.self, from: data),
                  now.timeIntervalSince(state.updatedAt) >= -2,
                  now.timeIntervalSince(state.updatedAt) < inactivityTimeout else { continue }
            result[file.lastPathComponent] = state
        }
        return result
    }
}

public enum HookInstallation {
    public enum Failure: LocalizedError {
        case invalidConfig, missingHelper
        public var errorDescription: String? {
            switch self {
            case .invalidConfig: return "现有 Hooks 配置格式无法安全合并，原文件未修改。"
            case .missingHelper: return "安装包缺少监听组件，请重新下载。"
            }
        }
    }
    private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Appends our own hooks; preserves unrelated hooks and settings. Never enables disabled hooks.
    public static func install(provider: HookProvider, helper: URL,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser, remove: Bool = false) throws {
        let fm = FileManager.default
        guard remove || fm.isExecutableFile(atPath: helper.path) else { throw Failure.missingHelper }
        let config = home.appendingPathComponent(".\(provider.rawValue)/settings.json")
        let original = fm.fileExists(atPath: config.path) ? try Data(contentsOf: config) : nil
        if remove && original == nil { return }
        var settings: [String: Any] = [:]
        if let original {
            guard let parsed = try JSONSerialization.jsonObject(with: original) as? [String: Any] else { throw Failure.invalidConfig }
            settings = parsed
        }
        if let hooks = settings["hooks"], !(hooks is [String: Any]) { throw Failure.invalidConfig }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let target = home.appendingPathComponent("Library/Application Support/While AI Works/Hooks/while-ai-works-hook")
        let command = "\(quote(target.path)) \(provider.rawValue)"
        for event in provider.events {
            if let value = hooks[event], !(value is [[String: Any]]) { throw Failure.invalidConfig }
            var groups = hooks[event] as? [[String: Any]] ?? []
            for group in groups {
                guard group["hooks"] is [[String: Any]] else { throw Failure.invalidConfig }
            }
            if remove {
                groups = groups.compactMap { group in
                    let entries = group["hooks"] as! [[String: Any]]
                    let remaining = entries.filter { $0["command"] as? String != command }
                    if remaining.count == entries.count { return group }
                    if remaining.isEmpty { return nil }
                    var copy = group; copy["hooks"] = remaining; return copy
                }
                if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
                continue
            }
            let present = groups.contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { $0["command"] as? String == command }
            }
            if !present { groups.append(["hooks": [["type": "command", "command": command, "timeout": 3]]]) }
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        let result = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !remove {
            try Data(contentsOf: helper).write(to: target, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
        }
        try fm.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let original {
            let backup = config.appendingPathExtension("while-ai-works-\(UUID().uuidString).bak")
            guard fm.createFile(atPath: backup.path, contents: original, attributes: [.posixPermissions: 0o600]) else {
                throw Failure.invalidConfig
            }
            guard try Data(contentsOf: config) == original else { throw Failure.invalidConfig }
        }
        try result.write(to: config, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
    }
}
