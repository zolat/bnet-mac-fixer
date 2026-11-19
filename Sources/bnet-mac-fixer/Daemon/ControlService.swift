import Foundation
import BnetFixerCore

/// Answers the control socket: state snapshots for the menu bar and `status`, plus manual actions.
final class ControlService {
    private let server = ControlServer()
    private let sleepGuard: SleepGuard
    private let watchdog: AgentWatchdog
    private let recorder: ActivityRecorder
    private let reconnect: ReconnectMonitor
    private let restarter = BattleNetRestarter()
    private let startedAt = Date()

    init(sleepGuard: SleepGuard, watchdog: AgentWatchdog, recorder: ActivityRecorder, reconnect: ReconnectMonitor) {
        self.sleepGuard = sleepGuard
        self.watchdog = watchdog
        self.recorder = recorder
        self.reconnect = reconnect
    }

    func start() {
        do {
            try server.start { [unowned self] in handle($0) }
        } catch {
            // The fixes keep working without it; only the menu bar and `status` lose live state.
            log("control: couldn't listen on \(FixerPaths.controlSocket): \(error)")
        }
    }

    private func handle(_ request: ControlRequest) -> ControlResponse {
        switch request.command {
        case .status:
            return ControlResponse(ok: true, snapshot: snapshot())
        case .restartAgent:
            let (ok, message) = watchdog.restartNow()
            return ControlResponse(ok: ok, message: message, snapshot: snapshot())
        case .resumeBattleNet:
            let (ok, message) = sleepGuard.resumeNow()
            return ControlResponse(ok: ok, message: message, snapshot: snapshot())
        case .restartBattleNet:
            return restartBattleNet()
        }
    }

    private func restartBattleNet() -> ControlResponse {
        guard !restarter.isRestarting else { return ControlResponse(ok: false, message: "Battle.net is already restarting", snapshot: snapshot()) }
        if sleepGuard.isPaused { _ = sleepGuard.resumeNow() } // a stopped process can't quit
        log("manual: restarting Battle.net")
        reconnect.restarting(at: Date())
        restarter.restart { [unowned self] ok, message in
            log("restart: \(message)")
            if ok { reconnect.relaunched(at: Date()) }
        }
        return ControlResponse(ok: true, message: "Restarting Battle.net", snapshot: snapshot())
    }

    private func snapshot() -> FixerSnapshot {
        let table = ProcessTable.all()
        let reading = watchdog.read(table)
        return FixerSnapshot(
            pid: getpid(),
            startedAt: startedAt,
            battleNet: .init(
                processCount: BattleNetProcesses.running(in: table).count,
                paused: sleepGuard.isPaused,
                pausedSince: sleepGuard.pausedSince,
                backgroundWakesThisSleep: sleepGuard.backgroundWakes
            ),
            agent: reading.agents.first.map { .init(pid: $0.pid, openFiles: reading.openFiles) },
            agentThreshold: watchdog.threshold,
            agentRestarting: watchdog.isRestarting,
            lastAgentRestart: watchdog.lastRestart,
            games: reading.gameNames,
            reconnect: reconnect.state,
            activity: recorder.activity
        )
    }
}
