import AgentHUDSupport
import Foundation

/// Logs that can exist in several places for one session: only the newest copy of each session counts.
enum LedgerCopies {
    /// Counting flags for every copy of the sessions that `touched` files belong to, before or after this pass.
    /// A file without a session id never counts.
    static func counted(touched: Set<String>, previous: [String: String], members: [String: String],
                        modified: [String: Date]) -> [String: Bool] {
        var result: [String: Bool] = [:]
        let affected = Set(touched.compactMap { members[$0] } + touched.compactMap { previous[$0] }).subtracting([""])
        for group in affected {
            let paths = members.filter { $0.value == group }.map(\.key)
            let newest = paths.max { (modified[$0] ?? .distantPast, $1) < (modified[$1] ?? .distantPast, $0) }
            for path in paths { result[path] = path == newest }
        }
        for path in touched where members[path]?.isEmpty == true { result[path] = false }
        return result
    }

    /// Modification times persist in milliseconds, so a restart compares them to the millisecond.
    static func signature(modified: Date, size: Int) -> String { "\(RecordCoding.milliseconds(modified)):\(size)" }

    static func signature(_ text: String) -> (modified: Date, size: Int)? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let milliseconds = Int64(parts[0]), let size = Int(parts[1]) else { return nil }
        return (RecordCoding.date(milliseconds), size)
    }

    static func same(_ stored: Date, _ current: Date) -> Bool { abs(stored.timeIntervalSince(current)) < 0.001 }
}
