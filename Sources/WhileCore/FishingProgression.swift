import Foundation

public enum FishingRod: String, CaseIterable, Identifiable {
    case bamboo, rain, wave, ocean
    public var id: String { rawValue }
    public var title: String {
        switch self { case .bamboo: return "青竹竿"; case .rain: return "听雨竿"; case .wave: return "逐浪竿"; case .ocean: return "沧澜竿" }
    }
    public var bonus: Double {
        switch self { case .bamboo: return 0; case .rain: return 0.05; case .wave: return 0.10; case .ocean: return 0.20 }
    }
    public var requiredCatches: Int {
        switch self { case .bamboo: return 0; case .rain: return 10; case .wave: return 50; case .ocean: return 100 }
    }
    public var requiredSpecies: Int { self == .ocean ? 10 : 0 }
    public var appearance: String {
        switch self { case .bamboo: return "青竹竹节 · 素色握柄"; case .rain: return "温润木纹 · 细绳缠线"; case .wave: return "深色竿身 · 金属导环"; case .ocean: return "深蓝漆面 · 银色饰环" }
    }
    public func isUnlocked(in book: FishingBook) -> Bool {
        book.total >= requiredCatches && book.discoveredFish >= requiredSpecies
    }
    public func requirement(in book: FishingBook) -> String {
        guard self != .bamboo else { return "初始拥有" }
        let count = "累计钓获 \(min(book.total, requiredCatches))/\(requiredCatches)"
        return requiredSpecies == 0 ? count : count + " · 鱼种 \(min(book.discoveredFish, requiredSpecies))/\(requiredSpecies)"
    }
}

public enum FishingMedal: String {
    case normal, silver, gold
    public var title: String { self == .gold ? "金牌" : self == .silver ? "银牌" : "普通" }
}

extension CatchSpecies {
    // Sizes are stored at 0.1 cm precision. Round thresholds UP so display and awards agree.
    public func medalThreshold(_ medal: FishingMedal) -> Double {
        let fraction = medal == .gold ? 0.9 : medal == .silver ? 0.7 : 0
        return ceil((minCM + (maxCM - minCM) * fraction) * 10 - 1e-9) / 10
    }
    public func medal(for sizeCM: Double) -> FishingMedal? {
        guard isFish else { return nil }
        return sizeCM >= medalThreshold(.gold) ? .gold : sizeCM >= medalThreshold(.silver) ? .silver : .normal
    }
}

extension FishingCatch {
    public var medal: FishingMedal? { species.medal(for: sizeCM) }
}

extension FishingBook {
    public var goldSpeciesCount: Int {
        CatchSpecies.catalog.filter { species in
            records[species.id].map { species.medal(for: $0.largestCM) == .gold } ?? false
        }.count
    }
}

public enum FishingAchievement: String, CaseIterable, Identifiable {
    case firstFish, catches10, catches50, catches100, species5, species10, allFish, allItems, secret, firstGold, allGold
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .firstFish: return "初次相遇"
        case .catches10: return "河畔新手"
        case .catches50: return "垂钓常客"
        case .catches100: return "百次收获"
        case .species5: return "五彩鱼篮"
        case .species10: return "见多识鱼"
        case .allFish: return "满满的图鉴"
        case .allItems: return "水底寻宝家"
        case .secret: return "未知巨物"
        case .firstGold: return "第一尾金牌"
        case .allGold: return "金牌满图鉴"
        }
    }
    public var detail: String {
        switch self {
        case .firstFish: return "首次钓到鱼"
        case .catches10: return "累计钓获 10 次（含杂物）"
        case .catches50: return "累计钓获 50 次（含杂物）"
        case .catches100: return "累计钓获 100 次（含杂物）"
        case .species5: return "发现 5 种鱼"
        case .species10: return "发现 10 种鱼"
        case .allFish: return "发现全部鱼种，包含未知巨物"
        case .allItems: return "集齐全部水底杂物"
        case .secret: return "钓获后揭晓"
        case .firstGold: return "钓获任意一尾金牌鱼"
        case .allGold: return "全部鱼种均获得金牌，包含未知巨物"
        }
    }
    public func progress(in book: FishingBook) -> (current: Int, target: Int) {
        let fishTotal = CatchSpecies.catalog.filter(\.isFish).count
        switch self {
        case .firstFish: return (min(book.fishCount, 1), 1)
        case .catches10: return (min(book.total, 10), 10)
        case .catches50: return (min(book.total, 50), 50)
        case .catches100: return (min(book.total, 100), 100)
        case .species5: return (min(book.discoveredFish, 5), 5)
        case .species10: return (min(book.discoveredFish, 10), 10)
        case .allFish: return (book.discoveredFish, fishTotal)
        case .allItems:
            let items = CatchSpecies.catalog.filter { !$0.isFish }
            return (items.filter { book.records[$0.id] != nil }.count, items.count)
        case .secret: return (CatchSpecies.catalog.contains { $0.isSecret && book.records[$0.id] != nil } ? 1 : 0, 1)
        case .firstGold: return (min(book.goldSpeciesCount, 1), 1)
        case .allGold: return (book.goldSpeciesCount, fishTotal)
        }
    }
}

/// Separate keys preserve the existing book schema and permanently earned achievements.
public struct FishingProgression {
    public private(set) var selectedRod: FishingRod
    public private(set) var earned: Set<String>
    public init(defaults: UserDefaults, book: FishingBook) {
        let saved = defaults.string(forKey: "fishing.rod.v1").flatMap(FishingRod.init(rawValue:))
        selectedRod = saved.flatMap { $0.isUnlocked(in: book) ? $0 : nil }
            ?? FishingRod.allCases.last(where: { $0.isUnlocked(in: book) }) ?? .bamboo
        earned = Set(defaults.stringArray(forKey: "fishing.achievements.v1") ?? [])
        _ = reconcile(book: book) // Historical awards are backfilled silently.
    }
    @discardableResult public mutating func equip(_ rod: FishingRod, book: FishingBook) -> Bool {
        guard rod.isUnlocked(in: book) else { return false }
        selectedRod = rod
        return true
    }
    @discardableResult public mutating func reconcile(book: FishingBook) -> [FishingAchievement] {
        let newlyEarned = FishingAchievement.allCases.filter {
            let progress = $0.progress(in: book)
            return progress.current >= progress.target && !earned.contains($0.id)
        }
        earned.formUnion(newlyEarned.map(\.id))
        return newlyEarned
    }
    public func save(defaults: UserDefaults) {
        defaults.set(selectedRod.rawValue, forKey: "fishing.rod.v1")
        defaults.set(earned.sorted(), forKey: "fishing.achievements.v1")
    }
}
