import Foundation
import WhileCore

enum Failure: Error { case assertion(String) }
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure.assertion(message) }
}
func event(_ type: String, turn: String? = "a", timestamp: String? = nil) -> Data {
    var payload: [String: Any] = ["type": type]
    if let turn { payload["turn_id"] = turn }
    var root: [String: Any] = ["type": "event_msg", "payload": payload]
    if let timestamp { root["timestamp"] = timestamp }
    return try! JSONSerialization.data(withJSONObject: root)
}

@main enum Checks {
    static func main() throws {
        var state = WorkActivity()
        state.consume(line: event("task_started"), sessionID: "one")
        try expect(state.isWorking, "start should mark active")
        state.consume(line: event("task_started", turn: "b"), sessionID: "two")
        state.consume(line: event("task_complete"), sessionID: "one")
        try expect(state.isWorking, "a second session must keep work active")
        state.consume(line: event("turn_aborted", turn: "b"), sessionID: "two")
        try expect(!state.isWorking, "abort must stop the remaining session")

        state.consume(line: event("turn_started", turn: "new"), sessionID: "one")
        state.consume(line: event("turn_complete", turn: "old"), sessionID: "one")
        try expect(state.isWorking, "stale completion must not stop a new turn")
        state.consume(line: event("turn_complete", turn: "new"), sessionID: "one")
        try expect(!state.isWorking, "v2 completion alias must stop work")

        state.consume(line: event("task_started", timestamp: "2020-01-01T00:00:00.123Z"), sessionID: "stale")
        state.expire(before: Date().addingTimeInterval(-1200))
        try expect(!state.isWorking, "old/crashed sessions should expire")
        let instant = Date()
        state.consume(line: event("task_started"), sessionID: "one", now: instant)
        state.consume(line: event("agent_message"), sessionID: "one", now: instant.addingTimeInterval(10))
        state.expire(before: instant.addingTimeInterval(5))
        try expect(state.isWorking, "fresh activity should extend liveness")
        state.consume(line: Data("not json".utf8), sessionID: "one")
        state.consume(line: Data(#"{"type":"response_item","payload":{"type":"task_complete"}}"#.utf8), sessionID: "one")
        try expect(state.isWorking, "malformed/non-lifecycle records must be ignored")
        state.consume(line: event("turn_aborted", turn: nil), sessionID: "one")
        try expect(!state.isWorking, "legacy abort without turn ID should stop work")

        state.consume(line: event("item_completed", turn: "recovered"), sessionID: "tail")
        try expect(state.active["tail"]?.turnID == "recovered", "progress with a stable turn ID recovers an omitted start")
        state.consume(line: event("task_complete", turn: "recovered"), sessionID: "tail")
        state.consume(line: event("item_completed", turn: "recovered"), sessionID: "tail")
        try expect(!state.isWorking, "late progress must not revive a completed turn")
        state.consume(line: event("item_completed", turn: nil), sessionID: "tail")
        try expect(!state.isWorking, "unidentified progress must not invent a turn")
        state.consume(line: event("item_completed", turn: "next"), sessionID: "tail")
        try expect(state.isWorking, "a new turn may recover without its start")
        state.remove(sessionID: "tail")
        var buffer = LineBuffer()
        let line = event("task_started") + Data([10])
        let cut = line.count / 2
        try expect(buffer.append(line.prefix(cut)).isEmpty, "partial writes must wait for newline")
        let completed = buffer.append(line.suffix(line.count - cut))
        try expect(completed.count == 1, "split JSON line should be reconstructed once")
        try expect(completed[0] == line.dropLast(), "reconstructed bytes must match")
        try expect(buffer.append(Data("a\nb\nc".utf8)).count == 2, "multiple lines should be split")
        try expect(buffer.append(Data("d\n".utf8)) == [Data("cd".utf8)], "tail must carry over")
        _ = buffer.append(Data(repeating: 65, count: 1_048_577))
        let recovered = buffer.append(Data("bad tail\nok\n".utf8))
        try expect(recovered == [Data("ok".utf8)], "oversized lines must be dropped completely")
        state.consume(line: event("task_started"), sessionID: "truncated")
        state.remove(sessionID: "truncated")
        try expect(!state.isWorking, "truncated or removed sessions must release active state")
        var rotation = RotationClock()
        try expect(!rotation.advance(delta: 1, enabled: true, working: true, interacting: false, interval: 2), "rotation waits for the interval")
        try expect(!rotation.advance(delta: 1, enabled: true, working: true, interacting: true, interval: 2), "rotation must not interrupt a held gesture")
        try expect(rotation.elapsed == 1, "interaction pauses eligible time")
        try expect(!rotation.advance(delta: 1, enabled: true, working: false, interacting: false, interval: 2), "idle AI pauses rotation")
        try expect(rotation.advance(delta: 1, enabled: true, working: true, interacting: false, interval: 2), "rotation resumes at its remaining interval")
        _ = rotation.advance(delta: 1, enabled: true, working: true, interacting: false, interval: 5)
        _ = rotation.advance(delta: 1, enabled: false, working: true, interacting: false, interval: 5)
        try expect(rotation.elapsed == 0, "disabling rotation resets accumulated time")
        try expect(!rotation.advance(delta: 3600, enabled: true, working: true, interacting: false, interval: 30), "waking from sleep must not skip games")

        var gate = StrikeGate()
        try expect(gate.press(onTarget: true), "a click on wood counts")
        try expect(!gate.press(onTarget: true), "holding or dragging must not count twice")
        gate.release()
        try expect(!gate.press(onTarget: false), "background clicks do not count")
        try expect(!gate.press(onTarget: true), "dragging onto wood is not a new click")
        gate.release()
        try expect(gate.press(onTarget: true), "a new click counts again")

        let suite = "WhileAIWorks.CoreChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let counter = ActivityCounter(defaults: defaults)
        counter.increment(); counter.increment()
        try expect(counter.total == 2 && counter.session == 2, "each strike increments both counters")
        let reopened = ActivityCounter(defaults: defaults)
        try expect(reopened.total == 2 && reopened.session == 0, "total survives reopening while session starts at zero")
        reopened.increment()
        try expect(ActivityCounter(defaults: defaults).total == 3, "subsequent launches preserve the new total")

        var friction = FrictionEnvelope()
        friction.move(speed: 0, dirt: 0.8, now: 0)
        friction.tick(now: 0.01, delta: 0.01)
        try expect(friction.volume == 0, "stationary clicks must stay silent")
        friction.move(speed: 400, dirt: 0, now: 0.01)
        friction.tick(now: 0.02, delta: 0.01)
        try expect(friction.volume == 0, "wiping clean glass should not trigger dirt friction")
        friction.move(speed: 400, dirt: 0.8, now: 0.02)
        friction.tick(now: 0.04, delta: 0.02)
        try expect(friction.volume > 0.05, "motion over dirt fades into audible friction")
        let movingVolume = friction.volume
        friction.tick(now: 0.20, delta: 0.16)
        try expect(friction.volume < movingVolume * 0.02, "stopping movement fades to silence even if mouse remains held")
        friction.move(speed: 500, dirt: 0.8, now: 0.21)
        friction.tick(now: 0.23, delta: 0.02)
        friction.release()
        friction.tick(now: 0.43, delta: 0.2)
        try expect(friction.volume < 0.001, "mouse release ends the friction voice")
        var slow = FrictionEnvelope(), fast = FrictionEnvelope()
        slow.move(speed: 40, dirt: 0.8, now: 1); fast.move(speed: 700, dirt: 0.8, now: 1)
        slow.tick(now: 1.04, delta: 0.04); fast.tick(now: 1.04, delta: 0.04)
        try expect(fast.volume > slow.volume && fast.rate > slow.rate, "friction level and texture follow motion speed")
        var stain = StainProgress(center: CGPoint(x: 100, y: 100), radius: 20)
        try expect(!stain.erase(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 0), radius: 22), "wiping empty space earns no stain")
        try expect(!stain.erase(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 100), radius: 22), "a stationary click earns no stain")
        try expect(stain.erase(from: CGPoint(x: 65, y: 100), to: CGPoint(x: 135, y: 100), radius: 22), "clearing a stain awards it once")
        try expect(!stain.erase(from: CGPoint(x: 65, y: 100), to: CGPoint(x: 135, y: 100), radius: 22), "repeated wiping cannot award a cleared stain again")
        var partial = StainProgress(center: CGPoint(x: 100, y: 100), radius: 40)
        try expect(!partial.erase(from: CGPoint(x: 65, y: 100), to: CGPoint(x: 135, y: 100), radius: 8), "partial cleaning does not count as a whole stain")
        let wipes = ActivityCounter(defaults: defaults, key: "wipe.total")
        wipes.increment()
        try expect(ActivityCounter(defaults: defaults, key: "wipe.total").total == 1 && ActivityCounter(defaults: defaults).total == 3,
                   "each game's persistent counter is independent")
        var decay = WorkDecayClock()
        for _ in 0..<4 { _ = decay.advance(delta: 1, active: true) }
        try expect(decay.advance(delta: 1, active: true), "active work decrements at five seconds")
        _ = decay.advance(delta: 2, active: true)
        try expect(!decay.advance(delta: 1, active: false) && decay.elapsed == 0, "idle work clears partial decay time")
        try expect(!decay.advance(delta: 3600, active: true), "sleep or relaunch must not apply offline debt")
        print("CoreChecks: 46 checks passed (lifecycle, rotation, counters, stain coverage, work decay, audio).")
    }
}
