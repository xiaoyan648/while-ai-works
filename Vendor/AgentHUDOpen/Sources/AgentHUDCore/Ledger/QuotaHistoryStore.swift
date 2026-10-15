import Foundation

/// One quota reading, persisted so trends, burn rate and cap statistics survive restarts.
public struct QuotaSample: Hashable, Codable, Sendable {
    public let agentId: String
    public let timestamp: Date
    public let remainingPct: Double

    public init(agentId: String, timestamp: Date, remainingPct: Double) {
        self.agentId = agentId
        self.timestamp = timestamp
        self.remainingPct = remainingPct
    }
}

/// One provider's quota readings in the usage ledger, appended as they are observed. The ledger keeps 30 days.
public actor QuotaHistoryStore {
    public static let retention: TimeInterval = 30 * 86400

    private let ledger: UsageLedger
    private let scope: String
    private var legacyFile: URL?

    /// - scope: separates providers, so one provider can forget its readings.
    /// - importing: a JSON history written by earlier versions, moved into the ledger on first use and then deleted.
    public init(ledger: UsageLedger = .inMemory(), scope: String = "", importing legacyFile: URL? = nil) {
        self.ledger = ledger
        self.scope = scope
        self.legacyFile = legacyFile
    }

    public func append(_ new: [QuotaSample], now: Date) async {
        guard !new.isEmpty else { return }
        await importIfNeeded()
        let scope = scope
        _ = try? await ledger.write { try $0.appendSamples(new, scope: scope) }
    }

    public func removeAll() async {
        await importIfNeeded()
        let scope = scope
        _ = try? await ledger.write { try $0.removeSamples(scope: scope) }
    }

    public func samples(agentId: String, since: Date) async -> [QuotaSample] {
        await importIfNeeded()
        return (try? await ledger.samples(scope: scope, windowID: agentId, since: since)) ?? []
    }

    public var count: Int {
        get async {
            await importIfNeeded()
            return (try? await ledger.sampleCount(scope: scope)) ?? 0
        }
    }

    private func importIfNeeded() async {
        guard let file = legacyFile else { return }
        legacyFile = nil
        guard let data = try? Data(contentsOf: file) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let cutoff = Date().addingTimeInterval(-Self.retention)
        let samples = ((try? decoder.decode([QuotaSample].self, from: data)) ?? []).filter { $0.timestamp >= cutoff }
        let scope = scope
        do {
            _ = try await ledger.write { try $0.appendSamples(samples, scope: scope) }
            try? FileManager.default.removeItem(at: file)
        } catch {
            legacyFile = file
        }
    }
}
