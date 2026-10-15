import Foundation

/// Something that costs a process listing to find, kept for a few seconds so the polls that follow each other reuse it.
///
/// An observer asks every couple of seconds what a client's local service is waiting for. Where that service is —
/// which process, on which port — changes only when the client starts or quits, and finding it means listing every
/// process this user runs: half a megabyte of text on a busy Mac. The answer is found once per `lifetime`, readers
/// that ask meanwhile get the same one, and a reader whose answer just failed asks for a fresh one.
actor Remembered<Value: Sendable> {
    private let lifetime: TimeInterval
    private let find: @Sendable () async throws -> Value
    private let clock: @Sendable () -> Date
    private var found: (value: Value, at: Date)?
    private var finding: (id: Int, task: Task<Value, Error>)?
    private var searches = 0

    init(lifetime: TimeInterval, clock: @escaping @Sendable () -> Date = { Date() },
         find: @escaping @Sendable () async throws -> Value) {
        self.lifetime = lifetime
        self.clock = clock
        self.find = find
    }

    /// The remembered value while it is younger than `lifetime`, and a new one otherwise or when `fresh` asks for it.
    /// A search that fails is remembered by nobody: the next reader searches again.
    func value(fresh: Bool = false) async throws -> Value {
        if !fresh, let found, clock().timeIntervalSince(found.at) < lifetime { return found.value }
        // Readers that arrive during a search wait for it instead of starting another.
        if let finding { return try await finding.task.value }
        searches += 1
        let id = searches, task = Task { [find] in try await find() }
        finding = (id, task)
        defer { if finding?.id == id { finding = nil } }
        let value = try await task.value
        found = (value, clock())
        return value
    }
}
