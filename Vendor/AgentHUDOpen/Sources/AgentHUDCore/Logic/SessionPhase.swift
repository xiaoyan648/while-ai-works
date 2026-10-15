import AgentHUDSupport
import Foundation

/// What a session is doing as the Mac shows it: a turn running or blocked on the user, nothing in flight, or in flight by
/// a reading too old for the Mac to vouch for. A provider decides when it reads a session whether its source has it in
/// flight (`LiveSession.endedAt`), by the rule its client's records support (`read(_:rule:at:)`); the phase adds, at the
/// time it is shown, how long the Mac vouches for that reading, what the newest turn says and whether live status is on.
/// A client's prompt and Stop hooks give a phase of their own, which takes the reading's place where the hooks saw more.
public struct SessionPhase: Hashable, Sendable {
    public enum State: String, Hashable, Sendable {
        /// A turn is in flight.
        case running
        /// A turn in flight is blocked on the user.
        case waitingForApproval
        /// Nothing is in flight, or live status is off.
        case idle
        /// The source had the session in flight when it was last read, too long ago for the Mac to vouch for it.
        case unverified
    }

    public let state: State
    /// In flight: when the turn in flight started, else when the session did. Otherwise: the session's last event.
    public let since: Date
    /// In flight: when the Mac stops vouching for the state without a newer reading or hook. Nil otherwise, and for a
    /// client waiting for an answer to a permission request, which lasts as long as it waits.
    public let validUntil: Date?

    public init(state: State, since: Date, validUntil: Date?) {
        self.state = state
        self.since = since
        self.validUntil = validUntil
    }

    /// When the state changes without new evidence.
    public var nextChange: Date? { validUntil }

    /// Running or blocked on the user: both are work in flight.
    public var isInFlight: Bool { state == .running || state == .waitingForApproval }

    /// How long each piece of session evidence counts.
    public enum Limits {
        /// A session whose source never said what its turn is doing, or whose running turn was never seen to start, stays
        /// in flight this long after its log was last written.
        public static let quiet: TimeInterval = 120
        /// A running turn this quiet was abandoned: its client was killed, or its logs stopped reaching this Mac. One tool
        /// call can keep a log quiet for minutes, so silence alone ends a turn only after this long.
        public static let abandoned: TimeInterval = 30 * 60
        /// How long after a reading that had a session in flight the Mac still vouches for it.
        public static let vouched: TimeInterval = 30 * 60
        /// A Pi run whose observer snapshot is this old is over; the observer refreshes it every 15 seconds while the run
        /// is active.
        public static let heartbeat: TimeInterval = 120
        /// A running DeepSeek turn whose log has recorded no event for this long is checked against the processes that hold
        /// its profile.
        public static let processCheck: TimeInterval = 120
        /// The process table behind that check is read again at most this often.
        public static let processRecheck: TimeInterval = 30
    }

    // MARK: Source

    /// Which of a client's records decide whether its session is in flight when a provider reads it. Under every rule a
    /// turn waiting for approval is in flight as a running one is: its client is blocked on the user, not finished.
    public enum SourceRule: Hashable, Sendable {
        /// A log that dates every line and follows its turn, as Claude Code's main and sub-agent logs do. A turn in flight
        /// stays so until the log has been quiet for `Limits.abandoned`, or for `Limits.quiet` when the log never showed
        /// the turn start; a log that never said what its turn is doing is in flight until it has been quiet for
        /// `Limits.quiet`. A session also runs while any of its sub-agents does.
        case transcript
        /// A log of events that follow its turns, as a Codex rollout is: a newest turn in flight stays so until the log has
        /// recorded no event for `Limits.abandoned`, and a log that never recorded a turn is in flight until it has recorded
        /// none for `Limits.quiet`. One that recorded nothing is never in flight.
        case rollout
        /// A log whose client's process can be checked, as DeepSeek Harness's can: a newest turn in flight of a log that
        /// recorded something stays so however quiet the log is, unless the process table, when it was read, holds no
        /// process that predates the turn.
        case process
        /// Turns a client's records report, and nothing else, as the additional clients' and the open agents' do: a
        /// newest turn in flight stays so until it has gone unobserved for `Limits.abandoned`. A session without turns
        /// is never in flight.
        case turns
    }

    /// A client's request for the user's approval, from its notification hook.
    public struct Approval: Hashable, Sendable {
        public var at: Date
        /// What the client said it is waiting for.
        public var message: String?

        public init(at: Date, message: String?) {
            self.at = at
            self.message = message
        }
    }

    /// What a provider read about one session.
    public struct SourceEvidence: Hashable, Sendable {
        /// The newest turn the source recorded for the session.
        public var turn: SessionTurn?
        /// When the source last recorded anything for the session: a log's last line of any kind, or its newest event. Nil
        /// when it recorded nothing that counts. Quiet always counts from here, never from a file's modification date.
        public var lastWriteAt: Date?
        /// The newest line of the session's sub-agents that are themselves in flight; nil when none is.
        public var subagentsAt: Date?
        /// The client's latest request for approval in the session.
        public var approval: Approval?
        /// Whether a process that holds the client's profile started no later than the newest turn. Nil when the process
        /// table was not read.
        public var processOutlivesTurn: Bool?

        public init(turn: SessionTurn?, lastWriteAt: Date? = nil, subagentsAt: Date? = nil, approval: Approval? = nil,
                    processOutlivesTurn: Bool? = nil) {
            self.turn = turn
            self.lastWriteAt = lastWriteAt
            self.subagentsAt = subagentsAt
            self.approval = approval
            self.processOutlivesTurn = processOutlivesTurn
        }
    }

    /// What a source says about its session when it is read.
    public struct SourceReading: Hashable, Sendable {
        /// Whether the session is in flight: the provider reports it without an end while it is.
        public let inFlight: Bool
        /// The newest turn as the provider reports it.
        public let turn: SessionTurn?
    }

    /// What `evidence` says about its session when it is read at `readAt`, by the rule of the client's records.
    public static func read(_ evidence: SourceEvidence, rule: SourceRule, at readAt: Date) -> SourceReading {
        switch rule {
        case .transcript:
            let limit: TimeInterval?
            if let turn = evidence.turn {
                // A turn nothing was seen to start comes from a partial log; only its freshness vouches for it.
                limit = turn.state.isInFlight ? (turn.startedAtMs == nil ? Limits.quiet : Limits.abandoned) : nil
            } else {
                limit = Limits.quiet
            }
            let fresh = limit.map { limit in evidence.lastWriteAt.map { readAt.timeIntervalSince($0) < limit } ?? false } ?? false
            return SourceReading(inFlight: fresh || evidence.subagentsAt != nil, turn: evidence.turn.map {
                transcriptTurn($0, approval: evidence.approval, subagentsAt: evidence.subagentsAt)
            })
        case .rollout:
            guard let lastWriteAt = evidence.lastWriteAt else { return SourceReading(inFlight: false, turn: evidence.turn) }
            let quiet = readAt.timeIntervalSince(lastWriteAt)
            guard let turn = evidence.turn else { return SourceReading(inFlight: quiet < Limits.quiet, turn: nil) }
            return SourceReading(inFlight: turn.state.isInFlight && quiet < Limits.abandoned, turn: turn)
        case .process:
            return SourceReading(inFlight: evidence.turn?.state.isInFlight == true && evidence.lastWriteAt != nil
                                     && evidence.processOutlivesTurn != false, turn: evidence.turn)
        case .turns:
            guard let turn = evidence.turn else { return SourceReading(inFlight: false, turn: nil) }
            return SourceReading(inFlight: turn.state.isInFlight
                                     && readAt.timeIntervalSince1970 - Double(turn.observedAtMs) / 1000 < Limits.abandoned, turn: turn)
        }
    }

    /// A turn as it stands once its client's Stop hook fired at `stop`, the latest the session's hooks reported: a turn in
    /// flight observed at or before it completed then. Nil leaves the turn as it is.
    public static func stopped(_ turn: SessionTurn, atMs stop: Int64?) -> SessionTurn {
        guard let stop, turn.state.isInFlight, stop >= turn.observedAtMs else { return turn }
        return SessionTurn(provider: turn.provider, sessionID: turn.sessionID, turnID: turn.turnID, state: .completed,
                           startedAtMs: turn.startedAtMs, observedAtMs: stop, message: turn.message)
    }

    /// A turn a heartbeat keeps fresh, as Pi's observer does, as it stands at `readAt`: a turn in flight whose last
    /// snapshot is `Limits.heartbeat` old ended there, without a completion.
    public static func lapsed(_ turn: SessionTurn, at readAt: Date) -> SessionTurn {
        guard turn.state.isInFlight,
              readAt.timeIntervalSince1970 - Double(turn.observedAtMs) / 1000 >= Limits.heartbeat else { return turn }
        return SessionTurn(provider: turn.provider, sessionID: turn.sessionID, turnID: turn.turnID, state: .ended,
                           startedAtMs: turn.startedAtMs, observedAtMs: turn.observedAtMs, message: turn.message)
    }

    /// A transcript's turn as its provider reports it. A running turn waits for approval while the client's request is
    /// newer than the turn's last line, dated by the request and showing its message; then, while sub-agents work, the
    /// turn runs, dated by their newest line. A request is answered by a line of the session's own log, never by a
    /// sub-agent's, so a turn waiting for approval keeps waiting while they work.
    static func transcriptTurn(_ turn: SessionTurn, approval: Approval?, subagentsAt: Date?) -> SessionTurn {
        var state = turn.state, observed = turn.observedAtMs, message = turn.message
        if state == .running, let approval, RecordCoding.milliseconds(approval.at) > observed {
            state = .waitingForApproval
            observed = RecordCoding.milliseconds(approval.at)
            message = approval.message ?? message
        }
        if let subagentsAt {
            if state != .waitingForApproval { state = .running }
            observed = max(observed, RecordCoding.milliseconds(subagentsAt))
        }
        return SessionTurn(provider: turn.provider, sessionID: turn.sessionID, turnID: turn.turnID, state: state,
                           startedAtMs: turn.startedAtMs, observedAtMs: observed, message: message)
    }

    // MARK: View

    /// The phase the Mac shows at `now` for a session its source reported, given its newest turn, when it last did
    /// something and whether its vendor's live status is on:
    /// - live status off: idle since the last event;
    /// - in flight by a reading less than `Limits.vouched` old: waiting for approval while the newest turn does, else
    ///   running; since the turn's start, else the session's;
    /// - in flight by an older reading, unverified; ended, idle; both since the last event.
    public init(session: LiveSession, turn: SessionTurn?, lastEventAt: Date, liveStatus: Bool, now: Date) {
        guard liveStatus else {
            self.init(state: .idle, since: lastEventAt, validUntil: nil)
            return
        }
        if session.isLive(at: now) {
            self.init(state: turn?.state == .waitingForApproval ? .waitingForApproval : .running,
                      since: Self.inFlightSince(session, turn: turn), validUntil: session.observedAt.addingTimeInterval(Limits.vouched))
            return
        }
        self.init(state: session.endedAt == nil ? .unverified : .idle, since: lastEventAt, validUntil: nil)
    }

    /// When the work in flight started: the newest turn's start while it runs or waits for approval, else the session's.
    static func inFlightSince(_ session: LiveSession, turn: SessionTurn?) -> Date {
        guard let turn, turn.state.isInFlight, let start = turn.startedAtMs else { return session.startedAt }
        return RecordCoding.date(start)
    }

    /// The phase of a session whose client waits for an answer to a permission request, given the phase it has otherwise:
    /// waiting for approval for as long as the client waits, which no reading's age bounds, since the work in flight
    /// started.
    func awaitingApproval(_ session: LiveSession, turn: SessionTurn?) -> SessionPhase {
        SessionPhase(state: .waitingForApproval, since: isInFlight ? since : Self.inFlightSince(session, turn: turn), validUntil: nil)
    }

    // MARK: Hooks

    /// A turn a client's hooks saw: it starts when the prompt is submitted and ends at the Stop hook.
    public struct HookTurn: Hashable, Sendable {
        public var startedAt: Date
        public var endedAt: Date?
        /// Whether it is the turn the reading reports; the caller matches the ids.
        public var isReportedTurn: Bool
        /// What the agent said at the Stop hook, where the hook carries it.
        public var message: String?

        public init(startedAt: Date, endedAt: Date?, isReportedTurn: Bool, message: String? = nil) {
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.isReportedTurn = isReportedTurn
            self.message = message
        }
    }

    /// The phase a hook turn gives at `now`: running since its start while it is open, for `Limits.vouched` after the start
    /// as a reading is vouched for, and out of date after that; idle since its end.
    public init(hook: HookTurn, now: Date) {
        if let end = hook.endedAt {
            self.init(state: .idle, since: end, validUntil: nil)
        } else if now.timeIntervalSince(hook.startedAt) < Limits.vouched {
            self.init(state: .running, since: hook.startedAt, validUntil: hook.startedAt.addingTimeInterval(Limits.vouched))
        } else {
            self.init(state: .unverified, since: hook.startedAt, validUntil: nil)
        }
    }

    /// The phase a hook turn gives without a time: running since its start while it is open, however long ago that was,
    /// and idle since its end. `init(hook:now:)` bounds an open turn as a reading is bounded.
    public init(hook: HookTurn) {
        self.init(state: hook.endedAt == nil ? .running : .idle, since: hook.endedAt ?? hook.startedAt, validUntil: nil)
    }

    /// Whether a hook turn takes the place of a reading's phase. The reading keeps it where it saw more than the hooks:
    /// work in flight after the hook's end; while the hook is open, a wait for approval of the same turn, or that turn's
    /// end dated after the hook's start; another turn, or one without an id, dated after the hook's start. Every
    /// comparison of times is strict.
    public static func hookPrevails(_ hook: HookTurn, over reading: SessionPhase, lastEventAt: Date) -> Bool {
        // Work the reading saw after the hook saw the agent stop, such as sub-agents left running, outlasts that stop.
        if reading.isInFlight, let end = hook.endedAt, lastEventAt > end { return false }
        guard hook.isReportedTurn else { return reading.since <= hook.startedAt }
        // The reading can see a wait for approval, or the turn's end, before the hooks do.
        return !(hook.endedAt == nil
            && (reading.state == .waitingForApproval || (!reading.isInFlight && reading.since > hook.startedAt)))
    }

    /// The phase a hook turn gives at `now` in place of a reading's, or nil where the reading keeps its own: where
    /// `hookPrevails(_:over:lastEventAt:)` says the reading saw more, and where the hook turn is out of date while the
    /// reading is in flight, since a hook turn past its half hour vouches for nothing.
    static func hooked(_ hook: HookTurn, over reading: SessionPhase, lastEventAt: Date, now: Date) -> SessionPhase? {
        guard hookPrevails(hook, over: reading, lastEventAt: lastEventAt) else { return nil }
        let phase = SessionPhase(hook: hook, now: now)
        return phase.state == .unverified && reading.isInFlight ? nil : phase
    }
}

extension SessionTurn.State {
    /// Running or blocked on the user: both are a turn in flight.
    var isInFlight: Bool { self == .running || self == .waitingForApproval }
}
