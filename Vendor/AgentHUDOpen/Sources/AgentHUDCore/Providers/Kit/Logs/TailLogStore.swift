import Foundation

/// An append-only log format: what a client supplies to `TailLogStore`. Sendable, so its decoding can run off the
/// store's actor.
protocol TailLog: Sendable {
    /// What the store keeps of one log between reads, such as counters and turn state; never conversation text.
    associatedtype Summary: Codable & Sendable
    /// The ledger source that owns the logs' contributions and stored states.
    static var source: String { get }
    /// The summary's key in the stored JSON state, and that state's version; a log whose state has another version is
    /// read again from the start and replaces what it recorded.
    static var summaryKey: String { get }
    static var version: Int { get }
    static func summary(for url: URL) -> Summary
    /// The name that copies of one log share in several places, of which only the most recently modified is read and
    /// the others are treated as missing from the listing; nil for a log that is never copied whole.
    static func copyName(_ path: String) -> String?
    /// The decoded log from `start`, for a format that cannot be read from an offset, with the places a later read can
    /// start from; nil reads the file itself from where the last read stopped.
    static func contents(of url: URL, from start: DecodedPosition) async throws -> DecodedLog?
    /// Reads one or more complete lines, each ending in a newline, and returns the usage they added.
    static func ingest(_ lines: Data, into summary: inout Summary) throws -> [UsageLedger.Event]
    /// The prompts and compactions read since the last call.
    static func drainMarks(_ summary: inout Summary) -> [UsageLedger.Mark]
    /// Runs once a read of the log ends.
    static func finishRead(_ summary: inout Summary, now: Date)
    /// The session of a log that can be copied to several places, where only the newest copy counts; "" for such a log
    /// without a session. Nil for a format whose logs all count.
    static func group(_ summary: Summary) -> String?
}

extension TailLog {
    static func copyName(_ path: String) -> String? { nil }
    static func contents(of url: URL, from start: DecodedPosition) async throws -> DecodedLog? { nil }
    static func drainMarks(_ summary: inout Summary) -> [UsageLedger.Mark] { [] }
    static func finishRead(_ summary: inout Summary, now: Date) {}
    static func group(_ summary: Summary) -> String? { nil }
}

/// A place a log that has to be decoded can be read from: the byte of the file and the byte of the decoded text it
/// starts at, such as the start of a compressed frame.
struct DecodedPosition: Codable, Hashable, Sendable {
    var stored = 0
    var decoded = 0
}

/// Part of a decoded log: its text from `start` on, and the places inside it a later read can start from, in order.
struct DecodedLog: Sendable {
    let start: DecodedPosition
    let data: Data
    let restarts: [DecodedPosition]
}

/// Reads append-only logs into the usage ledger, one contribution per log. A poll lists the logs, reads what changed
/// newest first from each saved position while its time budget lasts, and writes usage, positions and summaries in one
/// ledger write; a partially written final line is read once it is complete. A log that shrank, or changed without
/// growing, is read again from the start and replaces what it recorded, and so is one whose stored state has another
/// version, even when it is older than the cutoff, while the ledger still holds its usage. A stored log missing from the
/// listing leaves the ledger; one that is listed keeps its contribution even when it cannot be read, and is tried again
/// once its pause is over (`FailedReads`).
final class TailLogStore<Log: TailLog> {
    struct Entry {
        var modified: Date
        var size: Int
        /// Just past the last line read.
        var offset = 0
        /// Just past the last complete line the last read saw; beyond `offset` while complete lines wait.
        var committed = 0
        var summary: Log.Summary
        /// Where decoding can start again without losing the line at `offset`, for a log that has to be decoded.
        var restart: DecodedPosition?
    }

    /// One poll's work.
    struct Pass {
        /// Logs modified since the cutoff.
        var logs: [(path: String, file: LogFiles.File)] = []
        /// Logs whose entries this pass changed or dropped; after a rolled-back pass every entry was reloaded.
        var changed: [String] = [], removed: [String] = [], reloaded = false
        /// Logs the budget did not reach or finish, and changes the ledger did not take.
        var pending = 0
        /// Why logs could not be read, at this poll or at their last attempt; each is read again once its pause is over.
        var failures: [any Error] = []
        var gaps = LogFiles.Gaps()
        var filesRead = 0, bytesRead = 0
    }

    static var chunkSize: Int { 4 << 20 }

    private let ledger: UsageLedger
    private let files: LogFiles
    private var entries: [String: Entry] = [:]
    /// Stored states not decoded yet; most logs are older than the cutoff and never need it.
    private var stored: [String: UsageLedger.FileState] = [:]
    /// Logs whose stored state has another version or cannot be decoded, to read again from the start.
    private var outdated: Set<String> = []
    /// Sessions and modification times of grouped logs, for choosing the copy that counts.
    private var groups: [String: String] = [:]
    private var modified: [String: Date] = [:]
    private var loadedGeneration: Int?
    private var failed = FailedReads()
    private var failureReasons: [String: any Error] = [:]

    /// - watchesChanges: after the first listing, polls look only at logs a directory watch reports changed.
    init(roots: [URL], ledger: UsageLedger, watchesChanges: Bool, accepts: @escaping (URL) -> Bool) {
        self.ledger = ledger
        files = LogFiles(roots: roots, watchesChanges: watchesChanges, accepts: accepts)
    }

    func noteChanges(_ paths: Set<String>?) { files.noteChanges(paths) }

    func entry(_ path: String) -> Entry? {
        if let entry = entries[path] { return entry }
        guard let file = stored.removeValue(forKey: path) else { return nil }
        guard let entry = Self.entry(file) else {
            outdated.insert(path)
            return nil
        }
        entries[path] = entry
        return entry
    }

    func index(since cutoff: Date, timeBudget: TimeInterval, isolation: isolated (any Actor)? = #isolation) async -> Pass {
        var pass = Pass()
        let started = Date(), deadline = started.addingTimeInterval(timeBudget)
        // Logs modified since then can hold usage the ledger keeps.
        let retained = started.addingTimeInterval(-UsageLedger.retention)
        // Stored states are read once, and again after a failed pass rolled back what this store had written.
        let generation = await ledger.generation
        if loadedGeneration != generation {
            stored = (try? await ledger.fileStates(source: Log.source)) ?? [:]
            entries = [:]
            // Only the version is decoded, and only of logs recent enough to matter.
            outdated = Set(stored.filter {
                (LedgerCopies.signature($0.value.signature)?.modified ?? .distantPast) >= retained && !Self.isCurrent($0.value)
            }.keys)
            groups = stored.compactMapValues(\.group)
            modified = stored.compactMapValues { $0.group == nil ? nil : LedgerCopies.signature($0.signature)?.modified }
            loadedGeneration = generation
            pass.reloaded = true
        }
        pass.gaps = files.refresh(now: started)
        let listing = Self.counting(files.files)
        var changing: [(path: String, file: LogFiles.File)] = []
        for (path, file) in listing where file.modified >= cutoff {
            pass.logs.append((path, file))
            if let entry = entry(path), entry.size == file.size, LedgerCopies.same(entry.modified, file.modified), entry.offset >= entry.committed { continue }
            changing.append((path, file))
        }
        // An older log whose state another version wrote may hold usage that version counted differently.
        for path in outdated {
            if let file = listing[path], file.modified < cutoff, file.modified >= retained { changing.append((path, file)) }
        }

        // A log that could not be read waits out its pause, and is neither read nor waited for meanwhile.
        failed.keep(Set(listing.keys))
        failureReasons = failureReasons.filter { listing[$0.key] != nil }
        let pausing = changing.filter { failed.isPausing($0.path, at: started) }
        pass.failures = pausing.compactMap { failureReasons[$0.path] }
        let reading = changing.filter { !failed.isPausing($0.path, at: started) }
        // Always make progress on the newest log, then keep going while the budget lasts.
        var updates: [String: (entry: Entry, events: [UsageLedger.Event], marks: [UsageLedger.Mark], reset: Bool)] = [:]
        for (index, log) in reading.sorted(by: { $0.file.modified > $1.file.modified }).enumerated() {
            if index > 0, Date() >= deadline {
                pass.pending += reading.count - index
                break
            }
            do {
                let update = try await read(log.path, file: log.file, deadline: deadline, pass: &pass)
                updates[log.path] = update
                failed.succeeded(log.path)
                failureReasons[log.path] = nil
                if update.entry.offset < update.entry.committed { pass.pending += 1 }
            } catch {
                if !Task.isCancelled { failed.failed(log.path, at: Date()) }
                failureReasons[log.path] = error
                pass.failures.append(error)
            }
        }

        let removed = Set(entries.keys).union(stored.keys).union(outdated).filter { listing[$0] == nil }
        guard !updates.isEmpty || !removed.isEmpty else { return pass }
        var nextGroups = groups, nextModified = modified
        for (path, update) in updates {
            nextGroups[path] = Log.group(update.entry.summary)
            nextModified[path] = nextGroups[path] == nil ? nil : update.entry.modified
        }
        for path in removed { nextGroups[path] = nil; nextModified[path] = nil }
        let counted = LedgerCopies.counted(touched: Set(updates.keys).union(removed), previous: groups, members: nextGroups, modified: nextModified)
        let writes = updates.map { path, update in
            (path: path, reset: update.reset, events: update.events, marks: update.marks,
             counted: nextGroups[path].map { _ in counted[path] ?? false }, state: Self.state(update.entry))
        }
        let source = Log.source, written = Set(updates.keys)
        do {
            try await ledger.write { writer in
                for write in writes {
                    if write.reset { try writer.remove(source: source, contribution: write.path) }
                    try writer.upsert(source: source, contribution: write.path, counted: write.counted, events: write.events)
                    try writer.addMarks(source: source, contribution: write.path, marks: write.marks)
                    try writer.setFile(source: source, path: write.path, state: write.state)
                }
                for path in removed {
                    try writer.remove(source: source, contribution: path)
                    try writer.removeFile(source: source, path: path)
                }
                for (path, value) in counted where !written.contains(path) {
                    try writer.setCounted(source: source, contribution: path, counted: value)
                }
            }
            for (path, update) in updates { entries[path] = update.entry }
            for path in removed { entries[path] = nil; stored[path] = nil }
            outdated.subtract(written.union(removed))
            groups = nextGroups
            modified = nextModified
            pass.changed = Array(updates.keys)
            pass.removed = Array(removed)
        } catch {
            // Positions stay where the ledger has them, so the next poll reads the same bytes again.
            pass.pending += updates.count
        }
        return pass
    }

    /// Reads what the log gained since its entry, or all of it once rewritten. Each read ingests at least one chunk.
    private func read(_ path: String, file: LogFiles.File, deadline: Date, pass: inout Pass,
                      isolation: isolated (any Actor)? = #isolation) async throws
        -> (entry: Entry, events: [UsageLedger.Event], marks: [UsageLedger.Mark], reset: Bool) {
        let url = URL(fileURLWithPath: path), previous = entry(path)
        var entry = Entry(modified: file.modified, size: file.size, summary: Log.summary(for: url))
        var events: [UsageLedger.Event] = [], marks: [UsageLedger.Mark] = []
        var reset = outdated.contains(path) || previous.map { file.size < $0.size
            || (file.size == $0.size && !LedgerCopies.same($0.modified, file.modified)) } == true
        // A log that has to be decoded is decoded from the last place before the first line not read yet.
        var contents = try await Log.contents(of: url, from: reset ? DecodedPosition() : previous?.restart ?? DecodedPosition())
        if let previous, !reset, (contents.map { $0.start.decoded + $0.data.count } ?? file.size) < previous.offset {
            // What was read before is no longer there: the log was rewritten.
            reset = true
            if contents != nil { contents = try await Log.contents(of: url, from: DecodedPosition()) }
        }
        if let previous, !reset {
            entry.offset = previous.offset
            entry.summary = previous.summary
            entry.restart = previous.restart
        }
        pass.filesRead += 1
        if let contents {
            // Offsets in the decoded text; the data holds it from its start's decoded byte.
            let base = contents.start.decoded, data = contents.data
            pass.bytesRead += base + data.count - entry.offset
            entry.committed = max(entry.offset, base + (data.lastIndex(of: 0x0A).map { $0 - data.startIndex + 1 } ?? 0))
            repeat {
                guard entry.offset < entry.committed else { break }
                let limit = min(entry.committed, entry.offset + Self.chunkSize)
                let end = data[(data.startIndex + limit - base - 1)..<(data.startIndex + entry.committed - base)].firstIndex(of: 0x0A)! + 1
                events += try Log.ingest(data[(data.startIndex + entry.offset - base)..<end], into: &entry.summary)
                marks += Log.drainMarks(&entry.summary)
                entry.offset = base + end - data.startIndex
            } while Date() < deadline
            entry.restart = contents.restarts.last { $0.decoded <= entry.offset } ?? contents.start
        } else {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(entry.offset))
            var carry = Data()
            repeat {
                guard let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty else { break }
                pass.bytesRead += chunk.count
                carry.append(chunk)
                guard let newline = carry.lastIndex(of: 0x0A) else { continue }
                events += try Log.ingest(carry[...newline], into: &entry.summary)
                marks += Log.drainMarks(&entry.summary)
                entry.offset += newline + 1
                carry = Data(carry[(newline + 1)...])
            } while Date() < deadline
            // A read the budget stopped before the listed size leaves the rest of the file for the next poll.
            entry.committed = entry.offset + carry.count >= file.size ? entry.offset : file.size
        }
        Log.finishRead(&entry.summary, now: Date())
        return (entry, events, marks, reset)
    }

    /// The listed logs that count: of the copies sharing a `Log.copyName`, the most recently modified.
    private static func counting(_ files: [String: LogFiles.File]) -> [String: LogFiles.File] {
        var result: [String: LogFiles.File] = [:], newest: [String: String] = [:]
        for (path, file) in files {
            guard let name = Log.copyName(path) else {
                result[path] = file
                continue
            }
            if let other = newest[name], let kept = result[other] {
                guard (file.modified, path) > (kept.modified, other) else { continue }
                result[other] = nil
            }
            newest[name] = path
            result[path] = file
        }
        return result
    }

    private static func isCurrent(_ file: UsageLedger.FileState) -> Bool {
        file.state.flatMap { try? JSONDecoder().decode(StoredVersion.self, from: $0) }?.version == Log.version
    }

    private static func state(_ entry: Entry) -> UsageLedger.FileState {
        let data = try? JSONEncoder().encode(StoredState(offset: entry.offset, committed: entry.committed, summary: entry.summary,
                                                         restart: entry.restart))
        return UsageLedger.FileState(signature: LedgerCopies.signature(modified: entry.modified, size: entry.size), state: data,
                                     group: Log.group(entry.summary))
    }

    private static func entry(_ file: UsageLedger.FileState) -> Entry? {
        guard let parts = LedgerCopies.signature(file.signature), let data = file.state,
              let state = try? JSONDecoder().decode(StoredState.self, from: data) else { return nil }
        return Entry(modified: parts.modified, size: parts.size, offset: state.offset, committed: state.committed ?? parts.size, summary: state.summary,
                     restart: state.restart)
    }

    /// `{"version", "offset", "committedSize", <summaryKey>, "restart"}`. A state without `committedSize` has complete lines
    /// waiting unless its log was read to the end; one without `restart` decodes its log from the start.
    private struct StoredState: Codable {
        let offset: Int
        let committed: Int?
        let summary: Log.Summary
        let restart: DecodedPosition?

        private struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init(_ stringValue: String) { self.stringValue = stringValue }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        init(offset: Int, committed: Int?, summary: Log.Summary, restart: DecodedPosition?) {
            self.offset = offset; self.committed = committed; self.summary = summary; self.restart = restart
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            guard try container.decode(Int.self, forKey: Key("version")) == Log.version else {
                throw DecodingError.dataCorruptedError(forKey: Key("version"), in: container, debugDescription: "Another state version")
            }
            offset = try container.decode(Int.self, forKey: Key("offset"))
            committed = try container.decodeIfPresent(Int.self, forKey: Key("committedSize"))
            summary = try container.decode(Log.Summary.self, forKey: Key(Log.summaryKey))
            restart = try container.decodeIfPresent(DecodedPosition.self, forKey: Key("restart"))
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            try container.encode(Log.version, forKey: Key("version"))
            try container.encode(offset, forKey: Key("offset"))
            try container.encodeIfPresent(committed, forKey: Key("committedSize"))
            try container.encode(summary, forKey: Key(Log.summaryKey))
            try container.encodeIfPresent(restart, forKey: Key("restart"))
        }
    }
}

/// The version of a stored state, read without its summary.
private struct StoredVersion: Decodable {
    let version: Int
}
