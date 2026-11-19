import Foundation
import BnetFixerCore

/// Restarts the Battle.net Agent when it has leaked enough file descriptors to break updates,
/// waiting until no Blizzard game is running. See AgentRestartPolicy for the why.
final class AgentWatchdog {
    private static let interval: TimeInterval = 60
    private var policy = AgentRestartPolicy()
    private var games = BlizzardGames()
    private var lastDecision: AgentRestartPolicy.Decision = .healthy
    private var timer: Timer?
    private let isSuspended: () -> Bool

    /// - Parameter isSuspended: true while checks should be skipped (e.g. the Mac is asleep and
    ///   Battle.net is paused, so the Agent can't be relaunched on demand).
    init(isSuspended: @escaping () -> Bool) {
        self.isSuspended = isSuspended
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [unowned self] _ in check() }
        timer?.tolerance = 10
        check()
    }

    private func check() {
        guard !isSuspended() else { return }
        let table = ProcessTable.all()
        let agents = BattleNetAgent.running(in: table)
        let openFiles = agents.compactMap { ProcessTable.openFileCount($0.pid) }.max()
        let runningGames = games.running(in: table)
        let decision = policy.evaluate(openFiles: openFiles, gameRunning: !runningGames.isEmpty, now: Date())
        defer { lastDecision = decision }

        switch decision {
        case .healthy, .coolingDown:
            break
        case .waitingForGame:
            if lastDecision != .waitingForGame {
                let names = runningGames.map { ($0.path as NSString).lastPathComponent }
                log("agent: \(openFiles ?? 0) open files (limit ~1024); restart deferred until \(names.isEmpty ? "the game" : names.joined(separator: ", ")) has quit")
            }
        case .restart:
            policy.didRestart(at: Date())
            for agent in agents {
                log("agent: \(openFiles ?? 0) open files (limit ~1024); stopping pid \(agent.pid)")
                BattleNetAgent.stop(agent) { log("agent: pid \(agent.pid) \(describe($0))") }
            }
        }
    }
}
