import AgentHUDSupport
import Foundation

/// Every ISO 8601 date a provider reads as text is parsed here (Claude writes `2026-09-07T05:41:44.123Z` or
/// `…00.182540+00:00`); `ISO8601Fast` is the hand-rolled path for the shapes read most.
public enum DateParsing {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()

    public static func iso8601(_ string: String) -> Date? {
        if let date = try? fractional.parse(string) { return date }
        if let date = try? whole.parse(string) { return date }
        // Trim sub-millisecond digits (e.g. microseconds) that the format style rejects.
        if let dot = string.firstIndex(of: "."),
           let end = string[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) {
            let fraction = string[string.index(after: dot)..<end]
            if fraction.count > 3 {
                let trimmed = String(string[..<dot]) + "." + fraction.prefix(3) + String(string[end...])
                return try? fractional.parse(trimmed)
            }
        }
        return nil
    }

    /// An internet date-time, read as `ISO8601DateFormatter` reads it with or without fractional seconds: only the first
    /// three fractional digits count. The usual shape is parsed by hand; other text goes to the formatters, which cost
    /// far more to create than to use.
    static func internet(_ text: String?) -> Date? {
        guard let text else { return nil }
        if let milliseconds = ISO8601Fast.internetMilliseconds(text) { return RecordCoding.date(milliseconds) }
        return Formatters.shared.date(text)
    }

    /// A date without a time, such as `2026-09-30`, at its midnight in UTC.
    static func day(_ text: String?) -> Date? {
        text.flatMap(Formatters.shared.day)
    }

    /// Formatters are not Sendable, so every reader shares these under a lock.
    private final class Formatters: @unchecked Sendable {
        static let shared = Formatters()
        private let lock = NSLock()
        private let fractional = ISO8601DateFormatter(), whole = ISO8601DateFormatter(), fullDate = ISO8601DateFormatter()

        private init() {
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            whole.formatOptions = [.withInternetDateTime]
            fullDate.formatOptions = [.withFullDate]
        }

        func date(_ text: String) -> Date? { lock.withLock { fractional.date(from: text) ?? whole.date(from: text) } }
        func day(_ text: String) -> Date? { lock.withLock { fullDate.date(from: text) } }
    }
}

/// Hand-rolled parser for the fixed `YYYY-MM-DDTHH:MM:SS[.fff…](Z|±HH:MM)` shape Claude Code writes;
/// about two orders of magnitude cheaper than `ISO8601FormatStyle`. Anything else falls back to `DateParsing`.
public enum ISO8601Fast {
    public static func parse(_ text: String) -> Date? {
        let bytes = Array(text.utf8)
        guard bytes.count >= 20,
              let year = digits(bytes, 0, 4), bytes[4] == UInt8(ascii: "-"),
              let month = digits(bytes, 5, 2), bytes[7] == UInt8(ascii: "-"),
              let day = digits(bytes, 8, 2), bytes[10] == UInt8(ascii: "T"),
              let hour = digits(bytes, 11, 2), bytes[13] == UInt8(ascii: ":"),
              let minute = digits(bytes, 14, 2), bytes[16] == UInt8(ascii: ":"),
              let second = digits(bytes, 17, 2)
        else { return DateParsing.iso8601(text) }
        var index = 19
        var fraction = 0.0
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            var scale = 0.1
            while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 {
                fraction += Double(bytes[index] - 48) * scale
                scale /= 10
                index += 1
            }
        }
        var offsetSeconds = 0
        guard index < bytes.count else { return DateParsing.iso8601(text) }
        switch bytes[index] {
        case UInt8(ascii: "Z"):
            break
        case UInt8(ascii: "+"), UInt8(ascii: "-"):
            guard let offsetHour = digits(bytes, index + 1, 2) else { return DateParsing.iso8601(text) }
            let offsetMinute = (index + 5 < bytes.count) ? (digits(bytes, index + 4, 2) ?? 0) : 0
            offsetSeconds = (offsetHour * 3600 + offsetMinute * 60) * (bytes[index] == UInt8(ascii: "+") ? 1 : -1)
        default:
            return DateParsing.iso8601(text)
        }
        guard (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61 else { return nil }
        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = Double(days * 86400 + hour * 3600 + minute * 60 + second - offsetSeconds) + fraction
        return Date(timeIntervalSince1970: seconds)
    }

    /// Milliseconds since 1970 of a `YYYY-MM-DDTHH:MM:SS[.f…](Z|±HH:MM)` time, the value `ISO8601DateFormatter` reads
    /// from it as an internet date-time: only the first three fractional digits count, the rest are dropped. Nil for any
    /// other text, including the looser shapes and out-of-range fields the formatter still accepts in its own way, and
    /// for dates before 1970.
    static func internetMilliseconds(_ text: String) -> Int64? {
        let bytes = Array(text.utf8)
        guard bytes.count >= 20,
              let year = digits(bytes, 0, 4), bytes[4] == UInt8(ascii: "-"),
              let month = digits(bytes, 5, 2), bytes[7] == UInt8(ascii: "-"),
              let day = digits(bytes, 8, 2), bytes[10] == UInt8(ascii: "T"),
              let hour = digits(bytes, 11, 2), bytes[13] == UInt8(ascii: ":"),
              let minute = digits(bytes, 14, 2), bytes[16] == UInt8(ascii: ":"),
              let second = digits(bytes, 17, 2) else { return nil }
        var index = 19, fraction = 0, places = 0
        if bytes[index] == UInt8(ascii: ".") {
            index += 1
            while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 {
                if places < 3 { fraction = fraction * 10 + Int(bytes[index] - 48) }
                places += 1
                index += 1
            }
            guard (1...9).contains(places) else { return nil }
        }
        let offsetSeconds: Int
        if index == bytes.count - 1, bytes[index] == UInt8(ascii: "Z") {
            offsetSeconds = 0
        } else if index == bytes.count - 6, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-"),
                  let offsetHour = digits(bytes, index + 1, 2), bytes[index + 3] == UInt8(ascii: ":"),
                  let offsetMinute = digits(bytes, index + 4, 2), offsetHour <= 18, offsetMinute < 60 {
            offsetSeconds = (offsetHour * 3600 + offsetMinute * 60) * (bytes[index] == UInt8(ascii: "+") ? 1 : -1)
        } else { return nil }
        guard year >= 1970, (1...12).contains(month), day >= 1, day <= daysInMonth(month, year: year),
              hour < 24, minute < 60, second < 60 else { return nil }
        let seconds = daysFromCivil(year: year, month: month, day: day) * 86400 + hour * 3600 + minute * 60 + second - offsetSeconds
        return Int64(seconds) * 1000 + Int64(places == 1 ? fraction * 100 : places == 2 ? fraction * 10 : fraction)
    }

    private static func daysInMonth(_ month: Int, year: Int) -> Int {
        switch month {
        case 2: year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    private static func digits(_ bytes: [UInt8], _ start: Int, _ count: Int) -> Int? {
        guard start + count <= bytes.count else { return nil }
        var value = 0
        for index in start..<(start + count) {
            let byte = bytes[index]
            guard byte >= 48, byte <= 57 else { return nil }
            value = value * 10 + Int(byte - 48)
        }
        return value
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
