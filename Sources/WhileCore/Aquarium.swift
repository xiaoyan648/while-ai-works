import Foundation

public struct Aquarium: Codable {
    public static let capacity = 6
    public private(set) var residents: [String] = []
    private var seen: Set<String> = []
    public init() {}
    public mutating func discover(in book: FishingBook) {
        for fish in CatchSpecies.catalog where fish.isFish && book.records[fish.id] != nil {
            if seen.insert(fish.id).inserted && residents.count < Self.capacity { residents.append(fish.id) }
        }
    }
    @discardableResult public mutating func add(_ id: String, replacing old: String? = nil, book: FishingBook) -> Bool {
        guard CatchSpecies.catalog.contains(where: { $0.id == id && $0.isFish }), book.records[id] != nil,
              !residents.contains(id) else { return false }
        if let old {
            guard let index = residents.firstIndex(of: old) else { return false }
            residents[index] = id
        } else {
            guard residents.count < Self.capacity else { return false }
            residents.append(id)
        }
        seen.insert(id); return true
    }
    public mutating func remove(_ id: String) { residents.removeAll { $0 == id } }
    public static func load(defaults: UserDefaults, book: FishingBook) -> Self {
        var result = defaults.data(forKey: "aquarium.v1").flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
        var valid: Set<String> = []
        result.residents = Array(result.residents.filter { id in
            book.records[id] != nil && CatchSpecies.catalog.contains { $0.id == id && $0.isFish } && valid.insert(id).inserted
        }.prefix(capacity))
        result.discover(in: book)
        return result
    }
    public func save(defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: "aquarium.v1") }
    }
}
