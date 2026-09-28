import Foundation
import CoreGraphics

/// Accumulates only eligible play time; never interrupts a held interaction.
public struct RotationClock {
    public private(set) var elapsed: TimeInterval = 0
    public init() {}
    public mutating func reset() { elapsed = 0 }
    public mutating func advance(delta: TimeInterval, enabled: Bool, working: Bool,
                                 interacting: Bool, interval: TimeInterval) -> Bool {
        guard enabled else { reset(); return false }
        guard working, !interacting else { return false }
        elapsed += min(2, max(0, delta))
        if elapsed >= max(1, interval) { elapsed = 0; return true }
        return false
    }
}

/// Each press counts once, even when the mouse moves while held.
public struct StrikeGate {
    public private(set) var isDown = false
    public init() {}
    public mutating func press(onTarget: Bool) -> Bool {
        guard !isDown else { return false }
        isDown = true
        return onTarget
    }
    public mutating func release() { isDown = false }
}

public final class ActivityCounter {
    private let defaults: UserDefaults
    private let key: String
    public private(set) var total: Int
    public private(set) var session = 0
    public init(defaults: UserDefaults = .standard, key: String = "woodfish.total") {
        self.defaults = defaults
        self.key = key
        total = max(0, defaults.integer(forKey: key))
    }
    public func increment() {
        guard total < Int.max, session < Int.max else { return }
        total += 1
        session += 1
        defaults.set(total, forKey: key)
    }
}

/// Motion-controlled friction, independent of mouse event frequency.
public struct FrictionEnvelope {
    public private(set) var volume: Double = 0
    public private(set) var rate: Double = 1
    private var target = 0.0
    private var lastMotion = -Double.infinity
    public init() {}
    public mutating func move(speed: Double, dirt: Double, now: TimeInterval) {
        guard speed > 8, dirt > 0.015 else { target = 0; return }
        lastMotion = now
        let motion = min(1, speed / 750)
        target = min(0.28, sqrt(motion) * min(1, dirt * 2.5) * 0.24)
        rate = 0.82 + min(0.5, speed / 1800)
    }
    public mutating func release() { target = 0; lastMotion = -.infinity }
    public mutating func tick(now: TimeInterval, delta: TimeInterval) {
        if now - lastMotion > 0.085 { target = 0 }
        let timeConstant = target > volume ? 0.028 : 0.035
        volume += (target - volume) * (1 - exp(-max(0, delta) / timeConstant))
        if volume < 0.0001 { volume = 0 }
    }
}

/// Tracks coverage of a single stain, so repeated strokes cannot farm the same stain.
public struct StainProgress {
    private var remaining: [CGPoint]
    private let initialCount: Int
    public private(set) var completed = false
    public init(center: CGPoint, radius: CGFloat, bounds: CGRect? = nil, coverage: ((CGPoint) -> Bool)? = nil) {
        let count = 80
        remaining = (0..<count).map { index in
            let angle = CGFloat(index) * 2.399963229728653
            let distance = radius * sqrt((CGFloat(index) + 0.5) / CGFloat(count))
            return CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
        }.filter { (bounds?.contains($0) ?? true) && (coverage?($0) ?? true) }
        initialCount = remaining.count
        completed = remaining.isEmpty
    }
    public mutating func erase(from start: CGPoint, to end: CGPoint, radius: CGFloat) -> Bool {
        guard !completed else { return false }
        let dx = end.x - start.x, dy = end.y - start.y
        let squaredLength = dx * dx + dy * dy
        guard squaredLength > 0.25 else { return false }
        return erase { point in
            let t = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / squaredLength))
            return hypot(point.x - start.x - t * dx, point.y - start.y - t * dy) <= radius
        }
    }
    /// The renderer and coverage counter can share the very same swept contact shape.
    public mutating func erase(where touches: (CGPoint) -> Bool) -> Bool {
        guard !completed else { return false }
        remaining.removeAll(where: touches)
        if remaining.count <= Int(Double(initialCount) * 0.15) {
            completed = true
            return true
        }
        return false
    }
}

/// One shared clock for all monitors. No offline catch-up or idle/background decay.
public struct WorkDecayClock {
    public private(set) var elapsed: TimeInterval = 0
    public init() {}
    public mutating func advance(delta: TimeInterval, active: Bool) -> Bool {
        guard active else { elapsed = 0; return false }
        elapsed += min(2, max(0, delta))
        if elapsed >= 5 { elapsed -= 5; return true }
        return false
    }
}
