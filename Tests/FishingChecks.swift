import Foundation
import WhileCore

@main enum FishingChecks {
    static func main() throws {
        var checked = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label); checked += 1
        }
        check(FishingEnvironment(hour: 5.999).period == .night, "night continues until 06:00")
        check(FishingEnvironment(hour: 6).period == .day && FishingEnvironment(hour: 17.999).period == .day, "day boundary is inclusive at 06:00")
        check(FishingEnvironment(hour: 18).period == .night, "night starts at 18:00")
        check(FishingEnvironment(hour: 24) == FishingEnvironment(hour: 0), "midnight wraps without discontinuity")
        check(abs(FishingEnvironment(hour: 5.999).nightAmount - FishingEnvironment(hour: 6.001).nightAmount) < 0.004, "dawn light blends through fish-pool boundary")
        check(abs(FishingEnvironment(hour: 17.999).nightAmount - FishingEnvironment(hour: 18.001).nightAmount) < 0.004, "dusk light blends through fish-pool boundary")
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        var china = utc; china.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let date = Date(timeIntervalSince1970: 10 * 3600)
        check(FishingEnvironment.resolve(mode: .system, date: date, calendar: utc).period == .day, "system mode uses provided local calendar")
        check(FishingEnvironment.resolve(mode: .system, date: date, calendar: china).period == .night, "timezone changes affect environment")
        check(FishingEnvironment.resolve(mode: .day, date: date, calendar: china).period == .day, "free daylight bypasses real evening")
        check(FishingEnvironment.resolve(mode: .night, date: date, calendar: utc).period == .night, "free night bypasses real daytime")
        for water in FishingWater.allCases {
            var nightIDs = Set<String>(), dayIDs = Set<String>()
            for i in 0..<10000 {
                let unit = Double(i) / 10000
                dayIDs.insert(water.pick(unit:unit,period:.day).id)
                nightIDs.insert(water.pick(unit:unit,period:.night).id)
            }
            check(["eel","oarfish","moonfish"].allSatisfy { dayIDs.contains($0) }, "system time must not lock daytime users out of collections")
            check(["eel","oarfish","moonfish"].allSatisfy { nightIDs.contains($0) }, "all night-only species remain reachable in each water")
        }
        var waiting = FishingGame(); waiting.cast(into:.deep,period:.night)
        for _ in 0..<285 { _ = waiting.advance(delta:0.1,working:true,intensity:0,interacting:true,random:{0.9999}) }
        check(waiting.phase == .bite && waiting.period == .night, "unlucky active waiting is bounded to 28 seconds, cast pool stays locked")
        var seed: UInt64 = 918_273
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(UInt64.max >> 11)
        }
        let catalog = CatchSpecies.catalog
        check(catalog.filter(\.isFish).count == 15 && catalog.count == 22, "15 fish and seven incidental catches")
        check(Set(catalog.map(\.id)).count == catalog.count, "stable unique catalogue identifiers")
        check(abs(catalog.reduce(0) { $0 + $1.probability } - 1) < 0.000001, "weighted probabilities sum to one")
        check(catalog.allSatisfy { $0.minCM > 0 && $0.maxCM > $0.minCM && $0.weight > 0 }, "valid size ranges and weights")
        var distribution: [String: Int] = [:]
        for _ in 0..<100_000 { distribution[CatchSpecies.pick(unit: random()).id, default: 0] += 1 }
        for species in catalog {
            check(abs(Double(distribution[species.id] ?? 0) / 100_000 - species.probability) < 0.008, "weighted sampling for \(species.id)")
        }
        var habitatSamples: [FishingWater: [String: Int]] = [:]
        for water in FishingWater.allCases {
            var counts: [String: Int] = [:]
            for i in 0..<20_000 { counts[water.pick(unit: Double(i) / 20_000).id, default: 0] += 1 }
            check(counts.count == catalog.count, "every habitat retains all species")
            habitatSamples[water] = counts
            var cast = FishingGame(); cast.cast(into: water)
            check(cast.phase == .waiting && cast.water == water, "cast preserves habitat through waiting")
        }
        check(habitatSamples[.shallow]!["crucian"]! > habitatSamples[.deep]!["crucian"]!, "shallow water favors crucian")
        check(habitatSamples[.reeds]!["catfish"]! > habitatSamples[.shallow]!["catfish"]!, "cover favors catfish")
        check(habitatSamples[.deep]!["tuna"]! > habitatSamples[.shallow]!["tuna"]!, "deep water favors large fish")
        let tankSuite = "WhileAIWorks.AquariumChecks." + UUID().uuidString
        let tankDefaults = UserDefaults(suiteName: tankSuite)!
        defer { tankDefaults.removePersistentDomain(forName: tankSuite) }
        var tankBook = FishingBook()
        for species in catalog.prefix(8) { tankBook.record(.init(species: species, sizeCM: species.minCM)) }
        var tank = Aquarium.load(defaults: tankDefaults, book: tankBook)
        check(tank.residents.count == 6, "old collections migrate to a maximum of six fish")
        let first = tank.residents[0]
        check(!tank.add("salmon", book: tankBook), "full tank rejects insertion without a replacement")
        check(tank.add("salmon", replacing: first, book: tankBook), "replacement occupies the same slot")
        tank.remove("salmon"); tank.save(defaults: tankDefaults)
        tank = Aquarium.load(defaults: tankDefaults, book: tankBook)
        check(tank.residents.count == 5 && !tank.residents.contains("salmon"), "removed fish stay out after restart")
        tank.discover(in: tankBook)
        check(tank.residents.count == 5, "rediscovery cannot refill deliberately emptied slots")
        check(!tank.add("can", book: tankBook) && !tank.add("dragon", book: tankBook), "only discovered fish can enter")
        check(tank.add(first, book: tankBook), "removed fish can be re-added")
        let totalBefore = tankBook.total
        tankBook.record(.init(species: catalog[0], sizeCM: catalog[0].maxCM))
        tank.discover(in: tankBook)
        check(tank.residents.count == 6 && Set(tank.residents).count == 6, "new records never duplicate a resident")
        check(tankBook.records[first]!.largestCM == catalog[0].maxCM && tankBook.total == totalBefore + 1, "maximum remains in shared collection")
        let quiet = FishingGame.biteProbability(delta: 1, intensity: 0)
        let busy = FishingGame.biteProbability(delta: 1, intensity: 1)
        check(busy > quiet * 4, "busy Codex substantially increases bite probability")
        check(abs(pow(1 - FishingGame.biteProbability(delta: 1.0 / 30, intensity: 0.5), 30) - (1 - FishingGame.biteProbability(delta: 1, intensity: 0.5))) < 0.000001, "bite chance independent of frame rate")
        var game = FishingGame()
        game.press()
        for _ in 0..<400 { _ = game.advance(delta: 0.1, working: false, intensity: 1, interacting: false, random: { 0 }) }
        check(game.phase == .waiting, "idle Codex cannot generate a bite")
        for _ in 0..<22 { _ = game.advance(delta: 0.1, working: true, intensity: 0, interacting: false, random: { 0 }) }
        check(game.phase == .bite, "working event cadence enables a bite")
        for _ in 0..<81 { _ = game.advance(delta: 0.1, working: false, intensity: 0, interacting: false) }
        check(game.phase == .escaped, "missed bite expires without a catch")
        game.press()
        check(game.phase == .waiting, "retry after a missed bite")
        game.press()
        check(game.phase == .ready, "waiting can be cancelled")

        let suite = "WhileAIWorks.FishingChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var book = FishingBook()
        var selection = 0.0
        var successes = 0
        for species in catalog {
            var catchGame = FishingGame()
            catchGame.press()
            // First RNG roll triggers the bite, second chooses this species, third chooses size.
            var rolls = [0.0, selection + species.probability / 2, 0.5]
            for _ in 0..<21 {
                _ = catchGame.advance(delta: 0.1, working: true, intensity: 1, interacting: false, random: { rolls.isEmpty ? 0.99 : rolls.removeFirst() })
                if catchGame.phase == .bite { break }
            }
            check(catchGame.catchResult?.species == species, "every species can bite: \(species.id)")
            let size = catchGame.catchResult!.sizeCM
            check(size >= species.minCM && size <= species.maxCM, "species size bounds: \(species.id)")
            catchGame.press(); catchGame.release()
            let pausedBar = catchGame.bar, pausedFish = catchGame.fish, pausedProgress = catchGame.progress
            for _ in 0..<100 { _ = catchGame.advance(delta: 0.1, working: false, intensity: 0, interacting: false) }
            check(catchGame.bar == pausedBar && catchGame.fish == pausedFish && catchGame.progress == pausedProgress, "Option release pauses fight")
            _ = catchGame.advance(delta: 300, working: true, intensity: 1, interacting: true)
            check(catchGame.bar == pausedBar && catchGame.progress == pausedProgress, "sleep does not simulate offline fishing")
            var result: FishingCatch?
            var previousBar = catchGame.bar
            for _ in 0..<1950 {
                // Predictive player: start braking before reaching the fish.
                let velocity = (catchGame.bar - previousBar) * 30
                previousBar = catchGame.bar
                let shouldPress = catchGame.bar + velocity * 0.24 < catchGame.fish
                if shouldPress && !catchGame.pressed { catchGame.press() }
                if !shouldPress { catchGame.release() }
                if let caught = catchGame.advance(delta: 1.0 / 30, working: false, intensity: 0, interacting: true, random: random) { result = caught; break }
                if catchGame.phase == .escaped { break }
            }
            if let result {
                successes += 1; book.record(result)
                check(catchGame.advance(delta: 0.1, working: true, intensity: 1, interacting: true) == nil, "a landed catch is emitted once")
            }
            selection += species.probability
        }
        check(successes >= 17, "a responsive player can land most fish including difficult species (\(successes)/\(catalog.count))")
        let secret=catalog.first{ $0.isSecret }!
        check(catalog.filter(\.isSecret).count==1,"Exactly one secret species")
        check(secret.isHidden(in:FishingBook()) && secret.guideName(in:FishingBook()) == "未知巨物","An empty or old save cannot disclose the secret identity")
        check(book.records[secret.id] != nil,"The giant can be landed by the same predictive player, without a debug unlock")
        check(!secret.isHidden(in:book) && secret.guideName(in:book)==secret.name,"Only a successful recorded catch reveals identity")
        check(secret.minCM>=180 && secret.maxCM<=300,"Giant size range remains biologically plausible")
        let testFish = catalog[0]
        book.record(.init(species: testFish, sizeCM: testFish.maxCM))
        let before = book.total
        book.record(.init(species: testFish, sizeCM: testFish.minCM))
        check(book.records[testFish.id]?.largestCM == testFish.maxCM && book.total == before + 1, "smaller catch counts without replacing size record")
        check(book.fishCount + book.itemCount == book.total, "separate real fish and items while preserving total catch")
        book.save(defaults: defaults)
        check(FishingBook.load(defaults: defaults) == book, "catalogue counts and records survive relaunch")

        var pace = WorkPace()
        let now = Date()
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func log(_ date: Date, type: String = "agent_message") -> Data {
            try! JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": formatter.string(from: date), "payload": ["type": type]])
        }
        pace.consume(line: log(now), fresh: false, now: now)
        pace.consume(line: log(now.addingTimeInterval(-120)), fresh: true, now: now)
        pace.consume(line: log(now, type: "user_message"), fresh: true, now: now)
        check(pace.intensity(now: now) == 0, "history and user prompts do not inflate work speed")
        for _ in 0..<20 { pace.consume(line: log(now), fresh: true, now: now) }
        check(pace.intensity(now: now) == 1, "fresh activity burst raises pace within bound")
        check(pace.intensity(now: now.addingTimeInterval(10)) < 0.3, "activity decays between bursts")
        check(pace.intensity(now: now.addingTimeInterval(20)) == 0, "stale activity expires")
        print("FishingChecks: \(checked) catalogue, probability, gameplay, pause, persistence and work-pace checks passed; simulated player landed \(successes)/\(catalog.count) species.")
    }
}
