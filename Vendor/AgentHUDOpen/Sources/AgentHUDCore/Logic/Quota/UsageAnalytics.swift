import Foundation

/// Pure transforms from quota samples + transcript usage to the report's derived series.
public enum UsageAnalytics {
    /// `AlertPolicy.resetRise`.
    static var resetRise: Double { AlertPolicy.resetRise }

    /// Recent pace: consumption over the cycle's latest `paceInterval` of readings, including idle time.
    /// A younger or shorter observed series is used whole.
    public static func burnRate(samples: [QuotaSample], cycle: QuotaCycle?, now: Date) -> BurnRate? {
        guard let cycle, now >= cycle.start, now < cycle.resetAt else { return nil }
        let sampled = sampledQuota(samples, cycle: cycle, now: now)
        guard let earliest = sampled.first, let last = sampled.last else { return nil }
        let cutoff = last.timestamp.addingTimeInterval(-cycle.paceInterval)
        let first = sampled.last { $0.timestamp <= cutoff } ?? earliest
        let elapsed = last.timestamp.timeIntervalSince(first.timestamp)
        // Whole-point readings say nothing about a shorter span.
        guard elapsed >= cycle.sampleInterval else { return nil }
        return BurnRate(pctPerHour: max(0, first.remainingPct - last.remainingPct) / (elapsed / 3600))
    }

    /// Keep the observed baseline, each cycle-aligned bucket's last reading, and the latest partial bucket.
    /// A rise of `resetRise` points or more breaks the series (for example an early reset); never bridge across it.
    static func sampledQuota(_ samples: [QuotaSample], cycle: QuotaCycle, now: Date) -> [QuotaSample] {
        let current = samples.filter { $0.timestamp >= cycle.start && $0.timestamp <= now && $0.timestamp < cycle.resetAt }
            .sorted { $0.timestamp < $1.timestamp }
        var startIndex = 0
        for index in current.indices.dropFirst() where current[index].remainingPct - current[index - 1].remainingPct >= resetRise {
            startIndex = index
        }
        let segment = current.dropFirst(startIndex)
        guard let first = segment.first else { return [] }
        var buckets: [Int: QuotaSample] = [:]
        for sample in segment {
            let bucket = Int(sample.timestamp.timeIntervalSince(cycle.start) / cycle.sampleInterval)
            buckets[bucket] = sample
        }
        var result = [first]
        for key in buckets.keys.sorted() {
            if let sample = buckets[key], sample.timestamp > result.last!.timestamp { result.append(sample) }
        }
        return result
    }

    public struct CapStats: Hashable, Sendable {
        public let hits: Int
        public let totalWait: TimeInterval
        public let longestWait: TimeInterval
        public let longestAt: Date?

        public static let none = CapStats(hits: 0, totalWait: 0, longestWait: 0, longestAt: nil)
    }

    /// Times the window hit its cap (remaining ≤ `threshold`) and how long each outage lasted.
    public static func capStats(samples: [QuotaSample], threshold: Double = AlertPolicy.exhaustedRemaining, now: Date) -> CapStats {
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        var hits = 0
        var total: TimeInterval = 0
        var longest: TimeInterval = 0
        var longestAt: Date?
        var cappedSince: Date?
        for sample in sorted {
            let capped = sample.remainingPct <= threshold
            if capped, cappedSince == nil {
                cappedSince = sample.timestamp
                hits += 1
            } else if !capped, let start = cappedSince {
                let wait = sample.timestamp.timeIntervalSince(start)
                total += wait
                if wait > longest {
                    longest = wait
                    longestAt = start
                }
                cappedSince = nil
            }
        }
        if let start = cappedSince {
            let wait = now.timeIntervalSince(start)
            total += wait
            if wait > longest {
                longest = wait
                longestAt = start
            }
        }
        return CapStats(hits: hits, totalWait: total, longestWait: longest, longestAt: longestAt)
    }

    /// 7 × 24 grid (Mon → Sun) of 15-minute buckets that end after `since`, by the local hour each bucket starts in.
    public static func activityGrid(usage: [UsageBucket], since: Date, calendar: Calendar, dimensions: TokenDimensions = .fresh) -> ActivityGrid {
        var cells = Array(repeating: Array(repeating: [String: Int](), count: 24), count: 7)
        for bucket in usage where bucket.end > since {
            let row = (calendar.component(.weekday, from: bucket.start) + 5) % 7 // Monday = 0
            cells[row][calendar.component(.hour, from: bucket.start)][bucket.agentId, default: 0] += dimensions.count(bucket)
        }
        return ActivityGrid(tokensByModel: cells)
    }
}
