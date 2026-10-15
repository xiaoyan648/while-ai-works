import Foundation

public extension Array where Element == AgentDescriptor {
    /// Reorders an account's windows in their existing slots. Interleaved windows of other accounts never move.
    func movingAccountWindow(id: String, to targetID: String) -> [AgentDescriptor] {
        guard let source = first(where: { $0.id == id }),
              let target = first(where: { $0.id == targetID }),
              source.displayVendor == target.displayVendor, source.displayAccountID == target.displayAccountID else { return self }
        let slots = indices.filter {
            self[$0].displayVendor == source.displayVendor && self[$0].displayAccountID == source.displayAccountID
        }
        let windows = slots.map { self[$0] }
        guard let destination = windows.firstIndex(where: { $0.id == targetID }) else { return self }
        let reordered = windows.moving(id: id, to: destination)
        var result = self
        for (slot, window) in zip(slots, reordered) { result[slot] = window }
        return result
    }
}
