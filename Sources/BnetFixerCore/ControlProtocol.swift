import Foundation

/// Messages exchanged over the daemon's control socket: one JSON line each way per connection.
///
///     $ echo '{"command":"status"}' | nc -U ~/Library/Application\ Support/bnet-mac-fixer/control.sock
public struct ControlRequest: Codable, Equatable {
    public enum Command: String, Codable {
        case status
        case restartAgent = "restart-agent"
        case resumeBattleNet = "resume-battlenet"
        case restartBattleNet = "restart-battlenet"
    }

    public var command: Command

    public init(_ command: Command) {
        self.command = command
    }
}

public struct ControlResponse: Codable, Equatable {
    public var ok: Bool
    public var message: String?
    public var snapshot: FixerSnapshot?

    public init(ok: Bool, message: String? = nil, snapshot: FixerSnapshot? = nil) {
        self.ok = ok
        self.message = message
        self.snapshot = snapshot
    }
}

/// Everything a client needs to show the daemon's state.
public struct FixerSnapshot: Codable, Equatable {
    public struct BattleNet: Codable, Equatable {
        public var processCount: Int
        public var paused: Bool
        public var pausedSince: Date?
        public var backgroundWakesThisSleep: Int

        public init(processCount: Int, paused: Bool, pausedSince: Date? = nil, backgroundWakesThisSleep: Int = 0) {
            self.processCount = processCount
            self.paused = paused
            self.pausedSince = pausedSince
            self.backgroundWakesThisSleep = backgroundWakesThisSleep
        }
    }

    public struct Agent: Codable, Equatable {
        public var pid: Int32
        public var openFiles: Int?

        public init(pid: Int32, openFiles: Int?) {
            self.pid = pid
            self.openFiles = openFiles
        }
    }

    public var pid: Int32
    public var startedAt: Date
    public var battleNet: BattleNet
    public var agent: Agent?
    /// The Agent's restart threshold, and the point (FD_SETSIZE) where its downloader breaks.
    public var agentThreshold: Int
    public var agentLimit: Int
    public var agentRestarting: Bool
    public var lastAgentRestart: Date?
    public var games: [String]
    /// The latest wake/restart episode, until Battle.net has signed back in (and a little after).
    public var reconnect: ReconnectTracker.State?
    public var activity: ActivityLog

    public init(
        pid: Int32, startedAt: Date, battleNet: BattleNet, agent: Agent?, agentThreshold: Int,
        agentLimit: Int = 1024, agentRestarting: Bool = false, lastAgentRestart: Date? = nil,
        games: [String], reconnect: ReconnectTracker.State? = nil, activity: ActivityLog
    ) {
        self.pid = pid
        self.startedAt = startedAt
        self.battleNet = battleNet
        self.agent = agent
        self.agentThreshold = agentThreshold
        self.agentLimit = agentLimit
        self.agentRestarting = agentRestarting
        self.lastAgentRestart = lastAgentRestart
        self.games = games
        self.reconnect = reconnect
        self.activity = activity
    }
}

/// JSON coding shared by the socket and the activity file.
public enum FixerCoding {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
