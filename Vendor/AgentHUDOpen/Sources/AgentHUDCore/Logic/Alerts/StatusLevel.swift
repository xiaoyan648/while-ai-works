import Foundation

public enum StatusLevel: String, Codable, Sendable, CaseIterable {
    case ok
    case warning
    case critical

    /// Green above `warnPct`, yellow in (crit, warn], red at or below `critPct`.
    public static func resolve(remainingPct: Double, warnPct: Double, critPct: Double) -> StatusLevel {
        if remainingPct <= critPct { return .critical }
        if remainingPct <= warnPct { return .warning }
        return .ok
    }
}
