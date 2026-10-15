import Foundation

/// A chart's model selection. Nil shows all models; an explicit set, including an empty one, keeps the user's choice.
public struct TokenModelFilter: Equatable, Sendable {
    public private(set) var consumerIDs: Set<String>?

    public init(consumerIDs: Set<String>? = nil) { self.consumerIDs = consumerIDs }

    public var isAll: Bool { consumerIDs == nil }
    public func includes(_ id: String) -> Bool { consumerIDs?.contains(id) ?? true }
    public func isPicked(_ id: String) -> Bool { consumerIDs?.contains(id) == true }

    /// The first model starts a filter; subsequent clicks add or remove models from it.
    public mutating func toggle(_ id: String) {
        var next = consumerIDs ?? []
        if !next.insert(id).inserted { next.remove(id) }
        consumerIDs = next
    }

    public mutating func selectAll() { consumerIDs = nil }
}
