import Foundation

public enum FishingTimeMode: String, CaseIterable, Identifiable {
    case system, day, night
    public var id: String { rawValue }
    public var title: String {
        switch self { case .system: return "跟随时间"; case .day: return "白天"; case .night: return "夜晚" }
    }
}

public enum FishingPeriod: String { case day, night }

/// Wall time chooses scenery and the next cast's pool. Gameplay uses monotonic time.
public struct FishingEnvironment: Equatable {
    public let hour: Double
    public let period: FishingPeriod
    public let nightAmount: Double
    public let warmth: Double
    public let title: String
    public init(hour: Double) {
        let hour = hour.isFinite ? (hour.truncatingRemainder(dividingBy: 24) + 24).truncatingRemainder(dividingBy: 24) : 12
        self.hour = hour
        period = hour >= 6 && hour < 18 ? .day : .night
        func smooth(_ t: Double) -> Double { let t = min(1, max(0, t)); return t * t * (3 - 2 * t) }
        nightAmount = hour < 12 ? 1 - smooth(hour - 5.5) : smooth(hour - 17.5)
        warmth = max(0, 1 - min(abs(hour - 6), abs(hour - 18)) / 1.5)
        title = (5.5..<7).contains(hour) ? "晨光" : (17..<18.5).contains(hour) ? "暮色" : period == .night ? "月夜" : "日间"
    }
    public static func resolve(mode: FishingTimeMode, date: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> Self {
        if mode == .day { return Self(hour: 12) }
        if mode == .night { return Self(hour: 22) }
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Self(hour: Double(parts.hour ?? 12) + Double(parts.minute ?? 0) / 60 + Double(parts.second ?? 0) / 3600)
    }
}

extension CatchSpecies {
    public var nightFavored: Bool { ["eel", "oarfish", "moonfish"].contains(id) }
    public var timeHint: String {
        if isSecret { return "全天可遇 · 深水更常见" }
        if nightFavored { return id == "eel" ? "夜间多见 · 水草石隙" : "夜间多见 · 中央深水" }
        if id == "catfish" { return "全天 · 夜间更常见" }
        if ["sardine", "trout", "salmon", "puffer", "koi", "tuna"].contains(id) { return "全天 · 白天更常见" }
        return "全天可遇"
    }
    public func timeMultiplier(in period: FishingPeriod) -> Double {
        if nightFavored { return period == .night ? 1 : 0.18 }
        if id == "catfish" { return period == .night ? 1.8 : 1 }
        if ["sardine", "trout", "salmon", "puffer", "koi", "tuna"].contains(id) { return period == .day ? 1.5 : 0.75 }
        return 1
    }
}
