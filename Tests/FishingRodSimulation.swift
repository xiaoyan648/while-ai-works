import Foundation
import WhileCore
@main enum RodBalance {
    static func main() {
        print("species,rod,successful_trials,trials")
        for species in CatchSpecies.catalog where species.isFish {
            let offset = CatchSpecies.catalog.prefix { $0.id != species.id }.reduce(0.0) { $0 + $1.probability }
            for rod in FishingRod.allCases {
                var successes = 0
                for trial in 0..<100 {
                    var seed = UInt64(12345 + trial)
                    func random() -> Double {
                        seed = seed &* 6364136223846793005 &+ 1442695040888963407
                        return Double(seed >> 11) / Double(UInt64.max >> 11)
                    }
                    var game = FishingGame(rod: rod)
                    game.press()
                    var rolls = [0.0, offset + species.probability / 2, 0.95]
                    for _ in 0..<21 {
                        _ = game.advance(delta: 0.1, working: true, intensity: 1, interacting: true, random: { rolls.isEmpty ? 0.5 : rolls.removeFirst() })
                        if game.phase == .bite { break }
                    }
                    game.press(); game.release()
                    var previous = game.bar
                    for tick in 0..<1950 {
                        let velocity = (game.bar - previous) * 30
                        previous = game.bar
                        // A bounded reaction cadence: adjust only every 0.2 seconds.
                        if tick % 6 == 0 {
                            let press = game.bar + velocity * 0.24 < game.fish
                            if press && !game.pressed { game.press() }
                            if !press { game.release() }
                        }
                        if game.advance(delta: 1.0 / 30, working: true, intensity: 0, interacting: true, random: random) != nil { successes += 1; break }
                        if game.phase == .escaped { break }
                    }
                }
                print("\(species.id),\(rod.rawValue),\(successes),100")
            }
        }
    }
}
