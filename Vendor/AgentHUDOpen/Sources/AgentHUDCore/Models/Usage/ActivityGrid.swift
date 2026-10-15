import Foundation

/// 7 × 24 model token counts, rows Monday → Sunday, columns hour 0 → 23.
public struct ActivityGrid: Hashable, Sendable {
    public let tokensByModel: [[[String: Int]]]

    public init(tokensByModel: [[[String: Int]]]) {
        self.tokensByModel = tokensByModel
    }

    public var tokens: [[Int]] {
        tokensByModel.map { $0.map { $0.values.reduce(0, +) } }
    }

    /// Colour intensity derives from the same counts shown on hover.
    public var rows: [[Double]] {
        let peak = max(1, tokens.flatMap { $0 }.max() ?? 0)
        return tokens.map { $0.map { Double($0) / Double(peak) } }
    }
}
