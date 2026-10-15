import Foundation

/// The time the demo is built from. It is the wall clock, unless the launch says when the demo starts with
/// `--demo-clock 2026-10-12T09:41`: the demo's time then runs on from that moment, so a take or a set of stills made
/// at any hour shows the same sample day, the one the iPhone and the watch show for the same time.
public enum DemoClock {
    /// How far this launch's demo is from the wall clock, measured when the demo first asks the time.
    private static let offset: TimeInterval = offset(arguments: ProcessInfo.processInfo.arguments, now: Date())

    public static var now: Date { Date().addingTimeInterval(offset) }

    /// The wall-clock moment of a time in the demo, for a view that counts real seconds from it.
    public static func wallTime(of date: Date) -> Date { date.addingTimeInterval(-offset) }

    /// Nothing without the argument, or when what follows it does not read as a time: the wall clock then stays.
    static func offset(arguments: [String], now: Date, timeZone: TimeZone = .current) -> TimeInterval {
        guard let index = arguments.firstIndex(of: "--demo-clock"), arguments.indices.contains(index + 1) else { return 0 }
        guard let start = parse(arguments[index + 1], timeZone: timeZone) else {
            NSLog("[AgentHUD] --demo-clock %@ is not an ISO 8601 date and time: the wall clock stays", arguments[index + 1])
            return 0
        }
        return start.timeIntervalSince(now)
    }

    /// An ISO 8601 date and time, with or without seconds. One that names no offset is local time, read in `timeZone`.
    public static func parse(_ text: String, timeZone: TimeZone = .current) -> Date? {
        if let date = try? Date(text, strategy: .iso8601) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
