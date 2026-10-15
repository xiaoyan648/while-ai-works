import Foundation

/// Files whose last read failed. Each is tried again only after a pause that doubles with every failure in a row, from
/// half a minute up to the interval at which every source is read anyway, whether or not the file changed meanwhile: a
/// database too large to read in time grows with each write, and a log that cannot be opened stays that way. What was
/// read from the file before stays in place, so one broken file costs an attempt now and then instead of every pass.
struct FailedReads {
    static let firstPause: TimeInterval = 30
    static let longestPause = UsageRefresh.accountInterval

    private var failures: [String: (count: Int, retryAt: Date)] = [:]

    /// Whether the file is still waiting out the pause after its last failure.
    func isPausing(_ path: String, at now: Date) -> Bool {
        failures[path].map { now < $0.retryAt } ?? false
    }

    mutating func failed(_ path: String, at now: Date) {
        let count = (failures[path]?.count ?? 0) + 1
        let pause = min(Self.longestPause, Self.firstPause * Double(1 << min(count - 1, 16)))
        failures[path] = (count, now.addingTimeInterval(pause))
    }

    mutating func succeeded(_ path: String) { failures[path] = nil }

    /// Forgets the files that are no longer listed.
    mutating func keep(_ paths: Set<String>) {
        if failures.keys.contains(where: { !paths.contains($0) }) { failures = failures.filter { paths.contains($0.key) } }
    }
}
