import Foundation

/// What the fixer has done: running totals plus a short history, persisted by the daemon and
/// shown by the menu bar and `status`.
public struct ActivityLog: Codable, Equatable {
    public struct Event: Codable, Equatable {
        public enum Kind: String, Codable { case sleep, agent, info }
        public var date: Date
        public var kind: Kind
        public var text: String

        public init(date: Date, kind: Kind, text: String) {
            self.date = date
            self.kind = kind
            self.text = text
        }
    }

    public var since: Date
    /// Sleeps Battle.net was kept paused through.
    public private(set) var sleepsGuarded = 0
    /// Wakes that didn't reach the user (DarkWakes, lid-closed notification wakes) during which
    /// Battle.net stayed paused — each one a reconnect that could have logged you out.
    public private(set) var backgroundWakesHeld = 0
    public private(set) var secondsPaused: TimeInterval = 0
    public private(set) var agentRestarts = 0
    public private(set) var agentForceQuits = 0
    public private(set) var peakAgentOpenFiles = 0
    /// Most recent last.
    public private(set) var events: [Event] = []

    public static let maxEvents = 100

    public init(since: Date) {
        self.since = since
    }

    /// Battle.net was paused from `pausedAt` until `resumedAt`.
    public mutating func recordSleep(pausedAt: Date, resumedAt: Date, backgroundWakes: Int) {
        let paused = max(0, resumedAt.timeIntervalSince(pausedAt))
        sleepsGuarded += 1
        backgroundWakesHeld += backgroundWakes
        secondsPaused += paused
        let wakes = backgroundWakes > 0 ? ", held through \(Format.plural(backgroundWakes, "background wake"))" : ""
        append(.sleep, resumedAt, "Kept Battle.net paused for \(Format.duration(paused)) of sleep\(wakes)")
    }

    public enum RestartOutcome: Equatable { case exited, forceQuit, failed }

    public mutating func recordAgentRestart(at date: Date, openFiles: Int?, outcome: RestartOutcome, manual: Bool) {
        let files = openFiles.map { " at \(Format.count($0)) open files" } ?? ""
        let by = manual ? " (from the menu)" : ""
        switch outcome {
        case .exited:
            agentRestarts += 1
            append(.agent, date, "Restarted the Agent\(files)\(by)")
        case .forceQuit:
            agentRestarts += 1
            agentForceQuits += 1
            append(.agent, date, "Force-quit the Agent\(files) after it ignored a restart\(by)")
        case .failed:
            append(.agent, date, "Couldn't restart the Agent\(files)\(by)")
        }
    }

    public mutating func recordAgentDeferred(at date: Date, openFiles: Int, games: [String]) {
        let waiting = games.isEmpty ? "the game" : Format.list(games)
        append(.agent, date, "Agent at \(Format.count(openFiles)) open files; restart waits until \(waiting) quits")
    }

    public mutating func observeAgent(openFiles: Int) {
        peakAgentOpenFiles = max(peakAgentOpenFiles, openFiles)
    }

    public mutating func note(_ text: String, at date: Date) {
        append(.info, date, text)
    }

    /// For importers that learn about events out of order.
    mutating func sortEvents() {
        events.sort { $0.date.timeIntervalSince1970 < $1.date.timeIntervalSince1970 }
    }

    private mutating func append(_ kind: Event.Kind, _ date: Date, _ text: String) {
        events.append(Event(date: date, kind: kind, text: text))
        if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
    }
}
