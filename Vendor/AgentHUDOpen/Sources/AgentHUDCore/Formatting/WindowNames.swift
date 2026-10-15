import Foundation

/// How quota windows are named. A window's full name is in its vendor's own words, built by its provider; its short name,
/// for tight places such as a Watch row or a small widget, keeps only what tells the window apart from the account's
/// other windows, with one set of period words for every provider. A window without a short name shows its full name.
public enum WindowNames {
    /// A window's length as the vendors' clients name it: 5 hours, a day, a week, 30 days and 365 days within 5 %, as
    /// Codex's own client reads them, else whole days, hours or minutes.
    public enum Period: Hashable, Sendable {
        case fiveHours, day, week, month, year
        case days(Int), hours(Int), minutes(Int)

        /// nil for a window without a length, or one shorter than a minute.
        public init?(seconds: TimeInterval?) {
            guard let seconds, seconds.isFinite, seconds >= 60 else { return nil }
            let minutes = (seconds / 60).rounded()
            func near(_ expected: Double) -> Bool { minutes >= expected * 0.95 && minutes <= expected * 1.05 }
            if near(300) { self = .fiveHours }
            else if near(1440) { self = .day }
            else if near(10080) { self = .week }
            else if near(43200) { self = .month }
            else if near(525_600) { self = .year }
            else if minutes.truncatingRemainder(dividingBy: 1440) == 0 { self = .days(Int(minutes / 1440)) }
            else if minutes.truncatingRemainder(dividingBy: 60) == 0 { self = .hours(Int(minutes / 60)) }
            else { self = .minutes(Int(minutes)) }
        }

        /// The short name of a window that is only its period: 5h in both languages, Daily, Weekly, Monthly and Annual
        /// (每日, 每周, 每月, 每年), and any other length as its unit (3h, 30m, 3d).
        public var shortName: String {
            switch self {
            case .fiveHours: "5h"
            case .day: L10n.text("每日", "Daily")
            case .week: L10n.text("每周", "Weekly")
            case .month: L10n.text("每月", "Monthly")
            case .year: L10n.text("每年", "Annual")
            case .days(let count): "\(count)d"
            case .hours(let count): "\(count)h"
            case .minutes(let count): "\(count)m"
            }
        }

        /// The period after a word that names a bucket or group: in English the week is 7d, Anthropic's compact form, since
        /// a word and Weekly would no longer fit.
        public var afterWord: String { self == .week ? L10n.text("每周", "7d") : shortName }
    }

    /// The word a long service name is known by where no catalog names it: without its version numbers and the vendor
    /// and product words GPT, Codex and Claude, the last word left (GPT-5.3-Codex-Spark → Spark, Luna Reserve → Reserve);
    /// the name itself when nothing is left.
    public static func word(_ name: String) -> String {
        let words = name.split { $0 == " " || $0 == "-" || $0 == "_" }.map(String.init).filter { word in
            !["gpt", "codex", "claude"].contains(word.lowercased())
                && word.range(of: #"^[vV]?[0-9]+(\.[0-9]+)*$"#, options: .regularExpression) == nil
        }
        return words.last ?? name
    }

    /// The short names of one account's windows, with nil for any two that would read alike, which then show their
    /// full names.
    public static func distinct(_ names: [String?]) -> [String?] {
        var counts: [String: Int] = [:]
        for name in names.compactMap({ $0 }) { counts[name, default: 0] += 1 }
        return names.map { name in name.flatMap { counts[$0] == 1 ? $0 : nil } }
    }

    /// A name kept whole with at most eight characters, else its first word.
    public static func leading(_ name: String) -> String {
        name.count <= 8 ? name : name.split(separator: " ").first.map(String.init) ?? name
    }
}
