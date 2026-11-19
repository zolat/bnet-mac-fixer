import Foundation
import BnetFixerCore

/// Restarts the Battle.net Agent when it has leaked enough file descriptors to break updates,
/// waiting until no Blizzard game is running. See AgentRestartPolicy for the why.
final class AgentWatchdog {
    struct Reading {
        var agents: [BattleNetAgent.Instance]
        var openFiles: Int?
        var games: [ProcessTable.Entry]

        var gameNames: [String] { BlizzardGames.displayNames(games) }
    }

    private static let interval: TimeInterval = 60
    private var policy = AgentRestartPolicy()
    private var games = BlizzardGames()
    private var lastDecision: AgentRestartPolicy.Decision = .healthy
    private var timer: Timer?
    private let recorder: ActivityRecorder
    private let isSuspended: () -> Bool
    private(set) var isRestarting = false

    var threshold: Int { policy.threshold }
    var lastRestart: Date? { policy.lastRestart }

    /// - Parameter isSuspended: true while checks should be skipped (e.g. the Mac is asleep and
    ///   Battle.net is paused, so the Agent can't be relaunched on demand).
    init(recorder: ActivityRecorder, isSuspended: @escaping () -> Bool) {
        self.recorder = recorder
        self.isSuspended = isSuspended
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [unowned self] _ in check() }
        timer?.tolerance = 10
        check()
    }

    func read(_ table: [ProcessTable.Entry] = ProcessTable.all()) -> Reading {
        let agents = BattleNetAgent.running(in: table)
        return Reading(
            agents: agents,
            openFiles: agents.compactMap { ProcessTable.openFileCount($0.pid) }.max(),
            games: games.running(in: table)
        )
    }

    /// Manual restart from the menu bar / CLI. Skips the policy: the user asked.
    func restartNow() -> (ok: Bool, message: String) {
        guard !isRestarting else { return (false, "The Agent is already restarting") }
        let reading = read()
        guard !reading.agents.isEmpty else { return (false, "The Agent isn't running") }
        log("agent: \(reading.openFiles ?? 0) open files; restart requested")
        restart(reading, manual: true)
        return (true, "Restarting the Agent (pid \(reading.agents.map { String($0.pid) }.joined(separator: ", ")))")
    }

    private func check() {
        guard !isSuspended(), !isRestarting else { return }
        let reading = read()
        if let openFiles = reading.openFiles { recorder.update { $0.observeAgent(openFiles: openFiles) } }
        let decision = policy.evaluate(openFiles: reading.openFiles, gameRunning: !reading.games.isEmpty, now: Date())
        defer { lastDecision = decision }

        switch decision {
        case .healthy, .coolingDown:
            break
        case .waitingForGame:
            if lastDecision != .waitingForGame {
                let names = reading.gameNames
                log("agent: \(reading.openFiles ?? 0) open files (limit ~1024); restart deferred until \(names.isEmpty ? "the game" : names.joined(separator: ", ")) has quit")
                recorder.update { $0.recordAgentDeferred(at: Date(), openFiles: reading.openFiles ?? 0, games: names) }
            }
        case .restart:
            log("agent: \(reading.openFiles ?? 0) open files (limit ~1024); stopping pid \(reading.agents.map { String($0.pid) }.joined(separator: ", "))")
            restart(reading, manual: false)
        }
    }

    private func restart(_ reading: Reading, manual: Bool) {
        policy.didRestart(at: Date())
        isRestarting = true
        var pending = reading.agents.count
        for agent in reading.agents {
            BattleNetAgent.stop(agent) { [unowned self] result in
                log("agent: pid \(agent.pid) \(describe(result))")
                let outcome: ActivityLog.RestartOutcome = switch result {
                case .exited: .exited
                case .forceQuit: .forceQuit
                case .stillRunning, .signalFailed: .failed
                }
                recorder.update { $0.recordAgentRestart(at: Date(), openFiles: reading.openFiles, outcome: outcome, manual: manual) }
                pending -= 1
                if pending == 0 { isRestarting = false }
            }
        }
    }
}
