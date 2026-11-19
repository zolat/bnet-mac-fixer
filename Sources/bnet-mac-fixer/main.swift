import AppKit
import BnetFixerCore

// bnet-mac-fixer: works around Battle.net desktop-app bugs on macOS.
//   1. SleepGuard: stops Power Nap wakes from logging you out (pauses Battle.net through sleep).
//   2. AgentWatchdog: restarts the Agent before its descriptor leak breaks game updates.
// `run` is the daemon; `menubar` is an optional, separate client of its control socket.

setlinebuf(stdout)
let usage = "usage: bnet-mac-fixer [run|menubar [--dump]|status|freeze|thaw|restart-agent]\n"

/// Sends a command to the daemon if it's running. Nil means it isn't.
func askDaemon(_ command: ControlRequest.Command) -> ControlResponse? {
    do {
        return try ControlClient.send(.init(command))
    } catch ControlError.notRunning {
        return nil
    } catch {
        FileHandle.standardError.write("control: \(error)\n".data(using: .utf8)!)
        return nil
    }
}

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

    guard let snapshot = askDaemon(.status)?.snapshot else {
        print("fixer: not running")
        return
    }
    let summary = StatusSummary(snapshot)
    print("fixer: running since \(localTime(snapshot.startedAt)) (pid \(snapshot.pid))")
    print("  \(summary.battleNet)")
    print("  \(summary.agent)")
    print("history since \(localTime(snapshot.activity.since)):")
    summary.totals.forEach { print("  \($0)") }
    let recent = snapshot.activity.events.suffix(5)
    if !recent.isEmpty { print("recent:") }
    recent.forEach { print("  \(localTime($0.date))  \($0.text)") }
}

switch CommandLine.arguments.dropFirst().first ?? "run" {
case "run":
    let recorder = ActivityRecorder()
    let sleepGuard = SleepGuard(recorder: recorder)
    sleepGuard.start()
    let watchdog = AgentWatchdog(recorder: recorder, isSuspended: { sleepGuard.isPaused })
    watchdog.start()
    let control = ControlService(sleepGuard: sleepGuard, watchdog: watchdog, recorder: recorder)
    control.start()
    log("started: \(WakeState.current()?.description ?? "state unknown"); watching \(describe(BattleNetProcesses.running()))")
    // Timers and the socket handler hold these unowned; keep them alive for the daemon's lifetime.
    withExtendedLifetime((recorder, sleepGuard, watchdog, control)) { RunLoop.main.run() }

case "menubar":
    if CommandLine.arguments.contains("--dump") {
        let snapshot = StatusMenuController.fetch(timeout: 2)
        let builder = MenuBuilder(actions: .init(
            target: NSObject(), restartAgent: #selector(NSObject.copy), resumeBattleNet: #selector(NSObject.copy),
            startFixer: #selector(NSObject.copy), openLog: #selector(NSObject.copy), openProject: #selector(NSObject.copy),
            quit: #selector(NSObject.copy)
        ))
        print("icon: \(MenuBuilder.symbolName(for: StatusSummary(snapshot).health))")
        print(dump(builder.build(snapshot)))
        exit(0)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory) // menu bar only: no Dock icon or app menu
    let controller = StatusMenuController()
    controller.start()
    withExtendedLifetime(controller) { app.run() }

case "status":
    printStatus()

case "freeze":
    print("paused \(describe(BattleNetProcesses.freeze()))")

case "thaw":
    // Through the daemon when it's running, so it knows Battle.net is no longer paused.
    if let response = askDaemon(.resumeBattleNet) {
        print(response.message ?? "resumed")
    } else {
        print("resumed \(describe(BattleNetProcesses.thaw()))")
    }

case "restart-agent":
    if let response = askDaemon(.restartAgent) {
        print(response.message ?? "")
        if response.ok { print("(watch progress with: tail -f ~/Library/Logs/bnet-mac-fixer.log)") }
        exit(response.ok ? 0 : 1)
    }
    let agents = BattleNetAgent.running()
    if agents.isEmpty { print("agent: not running") }
    for agent in agents {
        print("agent: stopping pid \(agent.pid)…")
        let done = DispatchSemaphore(value: 0)
        BattleNetAgent.stop(agent, queue: .global()) { print("agent: pid \(agent.pid) \(describe($0))"); done.signal() }
        done.wait()
    }

default:
    FileHandle.standardError.write(usage.data(using: .utf8)!)
    exit(64)
}
