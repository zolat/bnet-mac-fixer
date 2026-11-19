import Foundation

/// Follows Battle.net from a wake (or a restart) until it has signed back in.
///
/// Why: after every wake Battle.net drops its connection and signs in again. Sometimes it notices
/// at once and is back in ~7 s; often it keeps using the dead connection for 60–100 s first, and
/// games launched in that window fail ("Pending game launch expired", SSO token timeouts).
/// No disconnect within `stuckAfter` has, so far, always meant the slow case.
public struct ReconnectTracker {
    public enum Phase: String, Codable {
        case waiting
        /// No disconnect yet: it's still on the dead connection and will take a minute or more.
        case stuck
        case restarting
        case ready
        case timedOut
    }

    public enum Cause: String, Codable { case wake, restart }

    public struct State: Codable, Equatable {
        public var phase: Phase
        public var cause: Cause
        /// When the episode began; also identifies it (e.g. for "dismissed").
        public var since: Date
        public var restartedAt: Date?
        public var readyAt: Date?

        public init(phase: Phase, cause: Cause, since: Date, restartedAt: Date? = nil, readyAt: Date? = nil) {
            self.phase = phase
            self.cause = cause
            self.since = since
            self.restartedAt = restartedAt
            self.readyAt = readyAt
        }

        /// Still waiting for Battle.net to come online.
        public var isWaiting: Bool { phase == .waiting || phase == .stuck || phase == .restarting }
    }

    public static let stuckAfter: TimeInterval = 15
    public static let giveUpAfter: TimeInterval = 180

    public private(set) var state: State?
    private var sawDisconnect = false
    /// Events logged before this are ignored (e.g. from the process being restarted).
    private var ignoreBefore: Date?

    public init() {}

    public mutating func begin(at now: Date) {
        state = State(phase: .waiting, cause: .wake, since: now)
        sawDisconnect = false
        ignoreBefore = now.addingTimeInterval(-1)
    }

    /// Battle.net is being restarted (from the overlay or menu). Continues a wake episode if one is running.
    public mutating func beginRestart(at now: Date) {
        if var s = state, s.isWaiting || s.phase == .timedOut {
            s.phase = .restarting
            s.restartedAt = now
            state = s
        } else {
            state = State(phase: .restarting, cause: .restart, since: now, restartedAt: now)
        }
        ignoreBefore = now
    }

    /// The new Battle.net process has been launched; only its sign-in counts.
    public mutating func relaunched(at now: Date) {
        ignoreBefore = now
    }

    public mutating func observe(_ event: BattleNetLog.Event) {
        guard var s = state, s.isWaiting || s.phase == .timedOut else { return }
        switch event {
        case .disconnected(let date):
            guard isCurrent(date) else { return }
            sawDisconnect = true
            if s.phase == .stuck { s.phase = .waiting } // it noticed; sign-in follows in seconds
        case .loggedIn(let date):
            guard isCurrent(date) else { return }
            s.phase = .ready
            s.readyAt = date
        }
        state = s
    }

    public mutating func tick(now: Date) {
        guard var s = state else { return }
        let waited = now.timeIntervalSince(s.restartedAt ?? s.since)
        if s.phase == .waiting, !sawDisconnect, now.timeIntervalSince(s.since) >= Self.stuckAfter { s.phase = .stuck }
        if s.isWaiting, waited >= Self.giveUpAfter { s.phase = .timedOut }
        state = s
    }

    private func isCurrent(_ date: Date) -> Bool {
        guard let ignoreBefore else { return true }
        return date.timeIntervalSince(ignoreBefore) >= 0
    }
}
