// The request/response flow follows Agent HUD Open (Apache-2.0); its SDK remains unchanged.
import Foundation
import Darwin
import AgentHUDCore
import AgentHUDSupport

@main enum CatInteractionHook {
    static func main() {
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--cat-interaction-hook",
              let source = PermissionHooks.Source(rawValue: CommandLine.arguments[2]), source == .claude || source == .codex else { return }
        signal(SIGPIPE, SIG_IGN); signal(SIGALRM) { _ in _exit(0) }
        alarm(5)
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard data.count <= 1024 * 1024, var object = (try? JSONValue.parse(data))?.catObject,
              object["hook_event_name"]?.catString == "PermissionRequest" else { return }
        if source == .codex {
            guard CatHookReviewer.isUser(.object(object)) else { return }
            object["_catReviewer"] = .string("user")
        }
        object["_catHubSource"] = .string(source.rawValue)
        let path = ProcessInfo.processInfo.environment["WHILE_AI_WORKS_INTERACTION_SOCKET"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".while-ai-works/interactions.sock").path
        // Begin following before the request can become visible on the hub.
        let watch = source == .claude ? TranscriptWatch(payload: .object(object)) { _exit(0) } : nil
        defer { watch?.stop() }
        guard let bytes = try? RecordCoding.encoder().encode(JSONValue.object(object)), let socket = UnixSocket.connect(to: path) else { return }
        defer { close(socket) }
        guard UnixSocket.send(socket, bytes) else { return }
        shutdown(socket, SHUT_WR); alarm(0)
        let response = UnixSocket.readToEnd(socket, limit: 1024 * 1024)
        guard !response.isEmpty, response.count <= 1024 * 1024 else { return }
        FileHandle.standardOutput.write(response)
    }
}

/// Codex invokes hooks before choosing a reviewer. Only its matching persisted
/// turn context can establish that this is an actual user approval request.
enum CatHookReviewer {
    static func isUser(_ payload: JSONValue) -> Bool {
        guard let path = payload[cat: "transcript_path"].catString, let turn = payload[cat: "turn_id"].catString,
              let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        var buffer = Data(), reviewer: String?
        do {
            while let bytes = try handle.read(upToCount: 65536), !bytes.isEmpty {
                buffer.append(bytes)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                    guard line.range(of: Data("turn_context".utf8)) != nil,
                          let record = try? JSONValue.parse(line), record[cat: "type"].catString == "turn_context",
                          record[cat: "payload"][cat: "turn_id"].catString == turn else { continue }
                    reviewer = record[cat: "payload"][cat: "approvals_reviewer"].catString
                }
                guard buffer.count <= 4 * 1024 * 1024 else { return false }
            }
        } catch { return false }
        return reviewer == "user"
    }
}

/// No polling of a whole transcript: read a bounded tail, then only appended bytes.
private final class TranscriptWatch: @unchecked Sendable {
    private let handle: FileHandle
    private let source: DispatchSourceFileSystemObject
    private let queue = DispatchQueue(label: "while-ai-works.question-watch")
    private let tool: String
    private let input: JSONValue
    private let settled: @Sendable () -> Void
    private var calls = Set<String>()
    private var partial = Data()
    private var done = false
    init?(payload: JSONValue, settled: @escaping @Sendable () -> Void) {
        guard let path = payload[cat: "transcript_path"].catString, let tool = payload[cat: "tool_name"].catString,
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        self.handle = handle; self.tool = tool; input = payload[cat: "tool_input"]; self.settled = settled
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: handle.fileDescriptor, eventMask: [.extend, .write], queue: queue)
        let end = (try? handle.seekToEnd()) ?? 0
        let offset = end > 4 * 1024 * 1024 ? end - 4 * 1024 * 1024 : 0
        try? handle.seek(toOffset: offset)
        var initial = (try? handle.readToEnd()) ?? Data()
        if offset > 0, let newline = initial.firstIndex(of: 10) { initial = Data(initial[initial.index(after: newline)...]) }
        _ = read(initial)
        source.setEventHandler { [weak self] in self?.follow() }; source.resume()
        queue.async { [weak self] in self?.follow() }
    }
    func stop() { queue.sync { done = true; source.cancel() } }
    deinit { source.cancel() }
    private func follow() {
        guard !done else { return }
        if read(handle.availableData) { done = true; source.cancel(); settled() }
    }
    private func read(_ data: Data) -> Bool {
        partial.append(data); var ended = false
        while let newline = partial.firstIndex(of: 10) {
            let line = Data(partial[..<newline]); partial.removeSubrange(...newline)
            guard let blocks = (try? JSONValue.parse(line))?[cat: "message"][cat: "content"].catArray else { continue }
            for block in blocks {
                if block[cat: "type"].catString == "tool_use", block[cat: "name"].catString == tool, let id = block[cat: "id"].catString {
                    var fields = block[cat: "input"].catObject ?? [:]
                    let answer = fields.removeValue(forKey: "answers")
                    if block[cat: "input"] == input || (tool == "AskUserQuestion" && .object(fields) == input) {
                        calls.insert(id)
                        if tool == "AskUserQuestion", answer?.catObject?.isEmpty == false { ended = true }
                    }
                }
                if block[cat: "type"].catString == "tool_result", let id = block[cat: "tool_use_id"].catString,
                   calls.remove(id) != nil { ended = true }
            }
        }
        if partial.count > 4 * 1024 * 1024 { partial.removeAll() }
        return ended
    }
}
