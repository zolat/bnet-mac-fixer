import Foundation
import BnetFixerCore

// bnet-mac-fixer: works around Battle.net desktop-app bugs on macOS.
//   1. SleepGuard: stops Power Nap wakes from logging you out (pauses Battle.net through sleep).
//   2. AgentWatchdog: restarts the Agent before its descriptor leak breaks game updates.
//
// Usage: bnet-mac-fixer [run|status|freeze|thaw|restart-agent]

setlinebuf(stdout)

func printStatus() {
    let table = ProcessTable.all()
    print("power: \(WakeState.current()?.description ?? "state unknown")")
    print("battle.net: \(describe(BattleNetProcesses.running(in: table)))")
    let agents = BattleNetAgent.running(in: table)
    if agents.isEmpty { print("agent: not running") }
    for agent in agents {
        print("agent: pid \(agent.pid), \(ProcessTable.openFileCount(agent.pid).map(String.init) ?? "?") open files (restart at \(AgentRestartPolicy().threshold))")
    }
    var games = BlizzardGames()
    let running = games.running(in: table).map { "\($0.pid)(\(($0.path as NSString).lastPathComponent))" }
    print("games: \(running.isEmpty ? "none running" : running.joined(separator: " "))")
}

switch CommandLine.arguments.dropFirst().first ?? "run" {
case "run":
    let sleepGuard = SleepGuard()
    sleepGuard.start()
    let watchdog = AgentWatchdog(isSuspended: { sleepGuard.isPaused })
    watchdog.start()
    log("started: \(WakeState.current()?.description ?? "state unknown"); watching \(describe(BattleNetProcesses.running()))")
    RunLoop.main.run()
case "status":
    printStatus()
case "freeze":
    print("paused \(describe(BattleNetProcesses.freeze()))")
case "thaw":
    print("resumed \(describe(BattleNetProcesses.thaw()))")
case "restart-agent":
    let agents = BattleNetAgent.running()
    if agents.isEmpty { print("agent: not running") }
    for agent in agents {
        print("agent: stopping pid \(agent.pid)…")
        let done = DispatchSemaphore(value: 0)
        BattleNetAgent.stop(agent, queue: .global()) { print("agent: pid \(agent.pid) \(describe($0))"); done.signal() }
        done.wait()
    }
default:
    FileHandle.standardError.write("usage: bnet-mac-fixer [run|status|freeze|thaw|restart-agent]\n".data(using: .utf8)!)
    exit(64)
}
