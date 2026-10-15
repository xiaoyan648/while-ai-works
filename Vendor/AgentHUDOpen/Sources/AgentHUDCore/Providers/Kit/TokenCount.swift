import Foundation

enum TokenCount {
    /// Adds counters read from a client's records; a sum that overflows means the record is malformed.
    static func sum(_ values: Int...) throws -> Int {
        var total = 0
        for value in values {
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { throw ProviderFailure.format }
            total = next
        }
        return total
    }
}
