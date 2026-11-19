import Foundation

/// Turns a daemon snapshot into the words and icon state the menu bar (and `status`) show.
/// Pure, so the wording is unit-tested rather than eyeballed.
public struct StatusSummary: Equatable {
    public enum Health: Equatable {
        case ok
        /// Battle.net is paused (asleep, or awake with the lid closed).
        case paused
        /// The Agent has leaked past the restart threshold.
        case attention
        /// Battle.net is reconnecting after a wake or restart; game launches may fail.
        case reconnecting
        /// The daemon isn't reachable.
        case offline
    }

    public var health: Health
    public var battleNet: String
    public var agent: String
    public var games: String?
    /// Lifetime totals, one line each.
    public var totals: [String]
    public var canResumeBattleNet: Bool
    public var canRestartAgent: Bool
    public var canRestartBattleNet: Bool

    public init(_ snapshot: FixerSnapshot?, now: Date = Date()) {
        guard let s = snapshot else {
            self.init(health: .offline, battleNet: "bnet-mac-fixer isn't running", agent: "", games: nil, totals: [],
                      canResumeBattleNet: false, canRestartAgent: false, canRestartBattleNet: false)
            return
        }

        let bn = s.battleNet
        let reconnecting = s.reconnect.map { $0.isWaiting } ?? false
        var battleNet: String
        if let r = s.reconnect, r.isWaiting {
            let elapsed = OverlayContent.clock(now.timeIntervalSince(r.restartedAt ?? r.since))
            switch r.phase {
            case .restarting: battleNet = "Battle.net: restarting (\(elapsed))"
            case .stuck: battleNet = "Battle.net: stuck on its old connection (\(elapsed)); restarting it is faster"
            default: battleNet = "Battle.net: reconnecting after sleep (\(elapsed)); wait before pressing Play"
            }
        } else if bn.processCount == 0 {
            battleNet = "Battle.net: not running"
        } else if bn.paused {
            let since = bn.pausedSince.map { " for \(Format.duration(now.timeIntervalSince($0)))" } ?? ""
            battleNet = "Battle.net: paused\(since) since the Mac slept; resumes on a full wake"
        } else {
            battleNet = "Battle.net: running, will be paused when the Mac sleeps"
        }

        let overThreshold = (s.agent?.openFiles ?? 0) >= s.agentThreshold
        let agent: String
        if s.agentRestarting {
            agent = "Agent: restarting…"
        } else if let a = s.agent {
            let files = a.openFiles.map { "\(Format.count($0)) open files" } ?? "open files unknown"
            if !overThreshold {
                agent = "Agent: \(files), healthy (restarts at \(Format.count(s.agentThreshold)))"
            } else {
                let broken = (a.openFiles ?? 0) >= s.agentLimit ? "updates will fail; " : ""
                agent = s.games.isEmpty
                    ? "Agent: \(files), \(broken)restarting within a few minutes"
                    : "Agent: \(files), \(broken)restarts after \(Format.list(s.games)) quits"
            }
        } else {
            agent = "Agent: not running (Battle.net starts it when needed)"
        }

        let a = s.activity
        var totals = [
            "\(Format.plural(a.sleepsGuarded, "sleep")) guarded, \(Format.duration(a.secondsPaused)) paused in total",
            "\(Format.plural(a.backgroundWakesHeld, "background wake")) held (each a possible logout)",
            "\(Format.plural(a.agentRestarts, "Agent restart"))" + (a.peakAgentOpenFiles > 0 ? ", peak \(Format.count(a.peakAgentOpenFiles)) open files" : ""),
        ]
        if a.agentForceQuits > 0 { totals[2] += ", \(Format.count(a.agentForceQuits)) force-quit" }

        self.init(
            health: reconnecting ? .reconnecting : overThreshold ? .attention : bn.paused ? .paused : .ok,
            battleNet: battleNet,
            agent: agent,
            games: s.games.isEmpty ? nil : "Playing: \(Format.list(s.games))",
            totals: totals,
            canResumeBattleNet: bn.paused,
            canRestartAgent: s.agent != nil && !s.agentRestarting,
            canRestartBattleNet: bn.processCount > 0 && s.reconnect?.phase != .restarting
        )
    }

    public init(health: Health, battleNet: String, agent: String, games: String?, totals: [String],
                canResumeBattleNet: Bool, canRestartAgent: Bool, canRestartBattleNet: Bool) {
        self.health = health
        self.battleNet = battleNet
        self.agent = agent
        self.games = games
        self.totals = totals
        self.canResumeBattleNet = canResumeBattleNet
        self.canRestartAgent = canRestartAgent
        self.canRestartBattleNet = canRestartBattleNet
    }
}
