import Foundation

/// Decides when to restart a Battle.net Agent that is leaking file descriptors.
///
/// Why: the Agent leaks a pipe for every failed code-signature check of a running game, and some
/// builds (e.g. WoW Forever, which ships a data file in Contents/MacOS) fail ~300 checks per launch.
/// Past ~1024 descriptors its downloader can't open sockets, so every update fails with error 5007
/// ("Failed to initialize the tact instance") until the Agent restarts.
///
/// Restart once descriptors pass `threshold`, but never while a game is running (or just quit),
/// and not again within `cooldown` of the last restart.
public struct AgentRestartPolicy {
    public var threshold: Int
    public var gameQuietPeriod: TimeInterval
    public var cooldown: TimeInterval
    private var lastGameSeen: Date?
    public private(set) var lastRestart: Date?

    public init(threshold: Int = 600, gameQuietPeriod: TimeInterval = 30, cooldown: TimeInterval = 300) {
        self.threshold = threshold
        self.gameQuietPeriod = gameQuietPeriod
        self.cooldown = cooldown
    }

    public enum Decision: Equatable {
        case healthy
        /// Over threshold, but a game is running or quit less than `gameQuietPeriod` ago.
        case waitingForGame
        /// Over threshold, but the Agent was restarted less than `cooldown` ago.
        case coolingDown
        case restart
    }

    // Comparisons use TimeIntervals, not Dates: the SDK's `Date >=` symbol is missing from some
    // macOS builds' Foundation and resolves to a null pointer at runtime.
    public mutating func evaluate(openFiles: Int?, gameRunning: Bool, now: Date) -> Decision {
        if gameRunning { lastGameSeen = now }
        guard let openFiles, openFiles >= threshold else { return .healthy }
        if let seen = lastGameSeen, now.timeIntervalSince(seen) < gameQuietPeriod { return .waitingForGame }
        if let last = lastRestart, now.timeIntervalSince(last) < cooldown { return .coolingDown }
        return .restart
    }

    public mutating func didRestart(at now: Date) {
        lastRestart = now
    }
}
