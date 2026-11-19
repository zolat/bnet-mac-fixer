import AppKit
import BnetFixerCore

// bnet-mac-fixer: works around Battle.net desktop-app bugs on macOS.
//   1. SleepGuard: stops Power Nap wakes from logging you out (pauses Battle.net through sleep).
//   2. AgentWatchdog: restarts the Agent before its descriptor leak breaks game updates.
// `run` is the daemon; `menubar` is an optional, separate client of its control socket.

setlinebuf(stdout)
let usage = "usage: bnet-mac-fixer [run|menubar [--dump]|status|freeze|thaw|restart-agent|restart-battlenet|overlay-preview PHASE [SECONDS]]\n"

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
    let reconnect = ReconnectMonitor(recorder: recorder)
    let sleepGuard = SleepGuard(recorder: recorder, reconnect: reconnect)
    sleepGuard.start()
    let watchdog = AgentWatchdog(recorder: recorder, isSuspended: { sleepGuard.isPaused })
    watchdog.start()
    let control = ControlService(sleepGuard: sleepGuard, watchdog: watchdog, recorder: recorder, reconnect: reconnect)
    control.start()
    log("started: \(WakeState.current()?.description ?? "state unknown"); watching \(describe(BattleNetProcesses.running()))")
    // Timers and the socket handler hold these unowned; keep them alive for the daemon's lifetime.
    withExtendedLifetime((recorder, reconnect, sleepGuard, watchdog, control)) { RunLoop.main.run() }

case "menubar":
    if CommandLine.arguments.contains("--dump") {
        let snapshot = StatusMenuController.fetch(timeout: 2)
        let builder = MenuBuilder(actions: .init(
            target: NSObject(), restartAgent: #selector(NSObject.copy), resumeBattleNet: #selector(NSObject.copy),
            restartBattleNet: #selector(NSObject.copy),
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

case "overlay-preview":
    // Dev aid: shows the reconnect overlay over the real Battle.net window with a fake state.
    let args = Array(CommandLine.arguments.dropFirst(2))
    let phase = args.first.flatMap(ReconnectTracker.Phase.init(rawValue:)) ?? .stuck
    let seconds = args.dropFirst().first.flatMap(Double.init) ?? 6
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let overlay = ReconnectOverlay()
    overlay.onRestart = { print("restart clicked") }
    let start = Date()
    func fake(_ now: Date) -> ReconnectTracker.State {
        ReconnectTracker.State(phase: phase, cause: .wake, since: start.addingTimeInterval(-42),
                               restartedAt: phase == .restarting ? start.addingTimeInterval(-3) : nil,
                               readyAt: phase == .ready ? now : nil)
    }
    let tick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in overlay.update(fake(Date()), now: Date()) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        let covered = overlay.coveredWindow
        print("overlay window \(overlay.windowNumber), covering Battle.net window \(covered.map(String.init) ?? "none")")
        if let covered { print("directly above Battle.net: \(BattleNetWindow.isDirectlyAbove(overlay.windowNumber, covered))") }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
    withExtendedLifetime((overlay, tick)) { app.run() }

case "restart-battlenet":
    guard let response = askDaemon(.restartBattleNet) else { print("bnet-mac-fixer isn't running"); exit(1) }
    print(response.message ?? "")
    exit(response.ok ? 0 : 1)

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
