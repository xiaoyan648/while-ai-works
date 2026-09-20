import Foundation

public struct CatchSpecies: Identifiable, Equatable {
    public enum Motion: String { case calm, float, dart, sink, wild }
    public let id: String
    public let name: String
    public let isFish: Bool
    public let minCM: Double
    public let maxCM: Double
    public let weight: Double
    public let difficulty: Double
    public let motion: Motion
    public let hue: Double
    public let symbol: String
    public var isSecret: Bool { id == "arapaima" }
    public func isHidden(in book: FishingBook) -> Bool { isSecret && book.records[id] == nil }
    public func guideName(in book: FishingBook) -> String { isHidden(in:book) ? "未知巨物" : name }
    public func displayLength(for sizeCM:Double)->Double { isSecret ? min(1.95,max(1.75,1.6+sizeCM/1000)) : min(1.50,max(0.85,0.55+sqrt(sizeCM)*0.10)) }
    public var discoveryNote: String? { isSecret ? "亚马孙的巨型淡水鱼，拥有厚鳞与红尾，会上浮呼吸空气。" : nil }
    public var rarity: String { weight >= 9 ? "常见" : weight >= 4 ? "少见" : weight >= 1.5 ? "稀有" : "传说" }
    public var difficultyLabel: String { difficulty < 0.25 ? "轻松" : difficulty < 0.5 ? "普通" : difficulty < 0.75 ? "棘手" : "高手" }
    public var probability: Double { weight / Self.catalog.reduce(0) { $0 + $1.weight } }
    public static let catalog: [CatchSpecies] = [
        .init(id: "crucian", name: "鲫鱼", isFish: true, minCM: 8, maxCM: 32, weight: 15, difficulty: 0.10, motion: .calm, hue: 0.13, symbol: "fish.fill"),
        .init(id: "carp", name: "鲤鱼", isFish: true, minCM: 20, maxCM: 85, weight: 12, difficulty: 0.23, motion: .sink, hue: 0.08, symbol: "fish.fill"),
        .init(id: "sardine", name: "沙丁鱼", isFish: true, minCM: 9, maxCM: 26, weight: 13, difficulty: 0.16, motion: .float, hue: 0.53, symbol: "fish.fill"),
        .init(id: "perch", name: "河鲈", isFish: true, minCM: 12, maxCM: 48, weight: 10, difficulty: 0.34, motion: .dart, hue: 0.26, symbol: "fish.fill"),
        .init(id: "trout", name: "虹鳟", isFish: true, minCM: 18, maxCM: 75, weight: 8, difficulty: 0.43, motion: .float, hue: 0.92, symbol: "fish.fill"),
        .init(id: "catfish", name: "鲶鱼", isFish: true, minCM: 25, maxCM: 135, weight: 6, difficulty: 0.55, motion: .sink, hue: 0.59, symbol: "fish.fill"),
        .init(id: "salmon", name: "三文鱼", isFish: true, minCM: 35, maxCM: 110, weight: 7, difficulty: 0.48, motion: .dart, hue: 0.03, symbol: "fish.fill"),
        .init(id: "eel", name: "鳗鱼", isFish: true, minCM: 30, maxCM: 150, weight: 4, difficulty: 0.65, motion: .wild, hue: 0.29, symbol: "fish.fill"),
        .init(id: "puffer", name: "河豚", isFish: true, minCM: 10, maxCM: 42, weight: 5, difficulty: 0.51, motion: .float, hue: 0.14, symbol: "fish.fill"),
        .init(id: "koi", name: "锦鲤", isFish: true, minCM: 18, maxCM: 95, weight: 3, difficulty: 0.58, motion: .calm, hue: 0.01, symbol: "fish.fill"),
        .init(id: "tuna", name: "金枪鱼", isFish: true, minCM: 70, maxCM: 260, weight: 2.5, difficulty: 0.68, motion: .dart, hue: 0.61, symbol: "fish.fill"),
        .init(id: "oarfish", name: "皇带鱼", isFish: true, minCM: 120, maxCM: 600, weight: 1.625, difficulty: 0.72, motion: .wild, hue: 0.96, symbol: "fish.fill"),
        .init(id: "moonfish", name: "月光鱼", isFish: true, minCM: 15, maxCM: 55, weight: 1.25, difficulty: 0.65, motion: .float, hue: 0.73, symbol: "fish.fill"),
        .init(id: "dragon", name: "比特龙鱼", isFish: true, minCM: 42, maxCM: 180, weight: 0.78, difficulty: 0.78, motion: .wild, hue: 0.44, symbol: "fish.fill"),
        .init(id: "arapaima", name: "巨骨舌鱼", isFish: true, minCM: 180, maxCM: 300, weight: 0.25, difficulty: 0.70, motion: .sink, hue: 0.08, symbol: "fish.fill"),
        .init(id: "weed", name: "水草", isFish: false, minCM: 5, maxCM: 65, weight: 9, difficulty: 0.04, motion: .calm, hue: 0.32, symbol: "leaf.fill"),
        .init(id: "can", name: "空罐头", isFish: false, minCM: 6, maxCM: 16, weight: 7, difficulty: 0.08, motion: .sink, hue: 0.55, symbol: "trash.fill"),
        .init(id: "disc", name: "神秘光盘", isFish: false, minCM: 8, maxCM: 12, weight: 5, difficulty: 0.30, motion: .float, hue: 0.75, symbol: "opticaldisc"),
        .init(id: "computer", name: "古董电脑", isFish: false, minCM: 24, maxCM: 58, weight: 1.6, difficulty: 0.73, motion: .sink, hue: 0.12, symbol: "desktopcomputer"),
        .init(id: "key", name: "不知谁的钥匙", isFish: false, minCM: 3, maxCM: 14, weight: 4, difficulty: 0.25, motion: .dart, hue: 0.12, symbol: "key.fill"),
        .init(id: "box", name: "快递盲盒", isFish: false, minCM: 10, maxCM: 70, weight: 2, difficulty: 0.42, motion: .float, hue: 0.07, symbol: "shippingbox.fill"),
        .init(id: "bug", name: "实体化的 Bug", isFish: false, minCM: 0.5, maxCM: 8, weight: 0.8, difficulty: 0.91, motion: .wild, hue: 0.93, symbol: "ladybug.fill")
    ]
    public static func pick(unit: Double) -> Self {
        let total = catalog.reduce(0) { $0 + $1.weight }
        var cursor = min(0.999999999, max(0, unit)) * total
        for species in catalog { cursor -= species.weight; if cursor < 0 { return species } }
        return catalog.last!
    }
}

public struct FishingCatch: Equatable {
    public let species: CatchSpecies
    public let sizeCM: Double
    public init(species: CatchSpecies, sizeCM: Double) {
        self.species = species
        self.sizeCM = (min(species.maxCM, max(species.minCM, sizeCM)) * 10).rounded() / 10
    }
}

public struct FishingBook: Codable, Equatable {
    public struct Record: Codable, Equatable {
        public var count: Int
        public var largestCM: Double
    }
    public private(set) var records: [String: Record] = [:]
    public init() {}
    public var fishCount: Int { CatchSpecies.catalog.filter(\.isFish).reduce(0) { $0 + (records[$1.id]?.count ?? 0) } }
    public var itemCount: Int { CatchSpecies.catalog.filter { !$0.isFish }.reduce(0) { $0 + (records[$1.id]?.count ?? 0) } }
    public var total: Int { fishCount + itemCount }
    public var discoveredFish: Int { CatchSpecies.catalog.filter { $0.isFish && records[$0.id] != nil }.count }
    @discardableResult public mutating func record(_ catchResult: FishingCatch) -> Bool {
        let old = records[catchResult.species.id]
        let newRecord = old == nil || catchResult.sizeCM > old!.largestCM
        records[catchResult.species.id] = Record(count: (old?.count ?? 0) + 1,
                                                largestCM: max(old?.largestCM ?? 0, catchResult.sizeCM))
        return newRecord
    }
    public static func load(defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: "fishing.book.v1"), let book = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return book
    }
    public func save(defaults: UserDefaults) { if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: "fishing.book.v1") } }
}

/// Recent event cadence, not tokens/sec. Bootstrap and old log records are ignored.
public struct WorkPace {
    private var events: [Date] = []
    public init() {}
    public mutating func consume(line: Data, fresh: Bool, now: Date) {
        guard fresh, let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = root["type"] as? String, type == "event_msg" || type == "response_item",
              let timestamp = root["timestamp"] as? String else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp),
              now.timeIntervalSince(date) >= -2, now.timeIntervalSince(date) <= 10 else { return }
        if let payload = root["payload"] as? [String: Any], let event = payload["type"] as? String,
           ["user_message", "task_started", "task_complete", "turn_started", "turn_complete", "turn_aborted"].contains(event) { return }
        events.append(date)
        if events.count > 240 { events.removeFirst(events.count - 240) }
    }
    public mutating func intensity(now: Date) -> Double {
        events.removeAll { now.timeIntervalSince($0) > 15 }
        return min(1, events.reduce(0.0) { $0 + exp(-max(0, now.timeIntervalSince($1)) / 5) } / 12)
    }
}

public enum FishingWater: String, CaseIterable {
    case shallow, reeds, deep
    public var title: String { self == .shallow ? "近岸浅水" : self == .reeds ? "荷叶水域" : "中央深水" }
    public func multiplier(for species: CatchSpecies) -> Double {
        switch self {
        case .shallow: return ["crucian", "sardine", "weed"].contains(species.id) ? 2.8 : species.maxCM > 100 ? 0.5 : 1
        case .reeds: return ["perch", "catfish", "eel", "weed", "can", "computer"].contains(species.id) ? 3 : 0.8
        case .deep: return species.isFish && (species.maxCM > 100 || species.weight < 4) ? 3.8 : species.isFish ? 0.8 : 0.45
        }
    }
    public func pick(unit: Double, period: FishingPeriod? = nil) -> CatchSpecies {
        func weight(_ species: CatchSpecies) -> Double {
            species.weight * multiplier(for: species) * (period.map { species.timeMultiplier(in: $0) } ?? 1)
        }
        let candidates = CatchSpecies.catalog.filter { weight($0) > 0 }
        let total = candidates.reduce(0) { $0 + weight($1) }
        var cursor = min(0.999999999, max(0, unit)) * total
        for species in candidates {
            cursor -= weight(species)
            if cursor < 0 { return species }
        }
        return candidates.last!
    }
}

public struct FishingGame {
    public enum Phase: Equatable { case ready, waiting, bite, fighting, landed, escaped }
    public private(set) var phase = Phase.ready
    public private(set) var catchResult: FishingCatch?
    public private(set) var bar = 0.35
    public private(set) var fish = 0.4
    public private(set) var progress = 0.45
    public private(set) var pressed = false
    public private(set) var elapsed = 0.0
    private var velocity = 0.0
    private var target = 0.4
    private var changeIn = 0.0
    private var waitAge = 0.0
    public private(set) var water: FishingWater?
    public private(set) var period: FishingPeriod?
    public private(set) var perfect = true
    public init() {}
    public var engaged: Bool { phase == .bite || phase == .fighting }
    public var challenge: Double {
        guard let result = catchResult else { return 0 }
        let species = result.species
        let size = (result.sizeCM - species.minCM) / (species.maxCM - species.minCM)
        return min(1, species.difficulty + size * 0.08)
    }
    public var barHeight: Double { 0.34 - challenge * 0.15 }
    public var inRange: Bool { abs(fish - bar) <= barHeight / 2 }
    public static func biteProbability(delta: Double, intensity: Double) -> Double {
        1 - exp(-(0.045 + 0.19 * min(1, max(0, intensity))) * max(0, delta))
    }
    public mutating func reset() { self = Self() }
    public mutating func press() {
        pressed = true
        switch phase {
        case .ready, .landed, .escaped:
            reset(); phase = .waiting
        case .waiting: reset()
        case .bite:
            phase = .fighting; elapsed = 0; pressed = true; velocity = 0.2
        case .fighting: velocity = min(0.85, velocity + 0.10)
        }
    }
    public mutating func cast(into water: FishingWater, period: FishingPeriod? = nil) {
        reset(); self.water = water; self.period = period; phase = .waiting
    }
    public mutating func release() { pressed = false }
    /// Returns a catch once, at the successful transition. Long gaps never advance the game.
    public mutating func advance(delta: Double, working: Bool, intensity: Double, interacting: Bool,
                                 random: () -> Double = { Double.random(in: 0..<1) }) -> FishingCatch? {
        guard delta > 0, delta <= 0.25 else { return nil }
        if phase == .waiting {
            guard working else { return nil }
            waitAge += delta
            if waitAge > 2, (waitAge >= 28 || random() < Self.biteProbability(delta: delta, intensity: intensity)) {
                let species = water?.pick(unit: random(), period: period) ?? CatchSpecies.pick(unit: random())
                let size = species.minCM + (species.maxCM - species.minCM) * pow(random(), water == .deep ? 0.9 : 1.5)
                catchResult = FishingCatch(species: species, sizeCM: size)
                phase = .bite; elapsed = 0
            }
        } else if phase == .bite {
            elapsed += delta
            if elapsed > 8 { phase = .escaped; pressed = false }
        } else if phase == .fighting {
            guard interacting else { pressed = false; return nil }
            elapsed += delta
            velocity += (pressed ? 1.65 : -1.2) * delta
            velocity = min(0.9, max(-0.9, velocity))
            bar += velocity * delta
            let half = barHeight / 2
            if bar < half { bar = half; velocity = abs(velocity) * 0.18 }
            if bar > 1 - half { bar = 1 - half; velocity = -abs(velocity) * 0.18 }
            changeIn -= delta
            if changeIn <= 0 {
                let motion = catchResult!.species.motion
                switch motion {
                case .calm: target = 0.3 + random() * 0.35
                case .float: target = 0.4 + random() * 0.52
                case .sink: target = 0.08 + random() * 0.5
                case .dart, .wild: target = 0.08 + random() * 0.84
                }
                changeIn = 0.55 + (1 - challenge) * 1.5 + random() * 0.6
            }
            // The giant feels heavy: sustained pulls, with short deliberate surges.
            if catchResult?.species.isSecret == true {
                let cycle=elapsed.truncatingRemainder(dividingBy:7.5)
                target = cycle<1.3 ? 0.78 : 0.18+0.12*(sin(elapsed*0.6)+1)
            }
            let speed = catchResult?.species.isSecret == true ? (elapsed.truncatingRemainder(dividingBy:7.5)<1.3 ? 0.52:0.22) : 0.12 + challenge * 0.65
            fish += min(speed * delta, max(-speed * delta, target - fish))
            fish = min(0.96, max(0.04, fish))
            if !inRange { perfect = false }
            progress += (inRange ? 0.15 - challenge * 0.035 : -(0.085 + challenge * 0.09)) * delta
            progress = min(1, max(0, progress))
            if progress >= 1 { phase = .landed; pressed = false; return catchResult }
            if progress <= 0 || elapsed > 65 { phase = .escaped; pressed = false }
        }
        return nil
    }
}
