import AppKit
import Foundation
import SleepGuardCore

// Keeps Battle.net running across sleep without it reconnecting during DarkWakes.
//
// Why: during Power Nap / maintenance wakes Battle.net reconnects, Blizzard issues a
// token-security-checkpoint, and the Mac sleeps again before it completes — which
// invalidates the saved login. Pausing the app for the whole sleep (including DarkWakes)
// and resuming only on a real, user-facing wake means it reconnects once, fully awake.
//
// Usage: bnet-sleepguard [run|status|freeze|thaw]

setlinebuf(stdout)

func log(_ message: String) {
    let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
    print("\(stamp) \(message)")
}

func describe(_ procs: [BattleNetProcesses.Process]) -> String {
    procs.isEmpty ? "no Battle.net processes" : procs.map { "\($0.pid)(\($0.role))" }.joined(separator: " ")
}

final class Guard {
    private static let sleepAckGrace: TimeInterval = 1
    private let power = PowerMonitor()
    private var frozen = false
    private var policy = ResumePolicy()
    private var loggedSettling = false
    private var pollTimer: Timer?

    func run() -> Never {
        // Recover from a previous instance dying while Battle.net was paused.
        if WakeState.current()?.isUserAwake ?? true {
            BattleNetProcesses.thaw()
        }

        power.onWillSleep = { [unowned self] allowSleep in
            let pause = { [unowned self] in
                let procs = BattleNetProcesses.freeze()
                frozen = !procs.isEmpty
                policy.reset()
                loggedSettling = false
                log("will sleep: paused \(describe(procs))")
                allowSleep()
            }
            // Battle.net (via its embedded Chromium) registers for the same sleep notification.
            // A stopped process can't acknowledge it, which makes the kernel wait 30 s before
            // sleeping — so if it's still running, give it a moment to ack before pausing it.
            // Our own ack is withheld until then, so the system can't sleep in between.
            if frozen {
                pause()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.sleepAckGrace, execute: pause)
            }
        }
        power.onPoweredOn = { [unowned self] in
            log("powered on: \(WakeState.current()?.description ?? "state unknown")")
            resumeIfUserAwake(reason: "powered on")
        }
        guard power.start() else {
            log("error: IORegisterForSystemPower failed")
            exit(1)
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [unowned self] _ in resumeIfUserAwake(reason: "screens did wake") }

        // DarkWake -> FullWake promotions don't send a new power-on message, so poll while paused.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [unowned self] _ in
            if frozen { resumeIfUserAwake(reason: "poll") }
        }

        log("started: \(WakeState.current()?.description ?? "state unknown"); watching \(describe(BattleNetProcesses.running()))")
        RunLoop.main.run()
        exit(0)
    }

    private func resumeIfUserAwake(reason: String) {
        guard frozen else { return }
        let state = WakeState.current()
        switch policy.evaluate(state, now: Date()) {
        case .stayPaused:
            loggedSettling = false
        case .settling(let until):
            if !loggedSettling {
                log("\(reason): awake with lid closed; holding pause until \(until) [\(state?.description ?? "state unknown")]")
                loggedSettling = true
            }
        case .resume:
            let procs = BattleNetProcesses.thaw()
            frozen = false
            loggedSettling = false
            log("\(reason): resumed \(describe(procs)) [\(state?.description ?? "state unknown")]")
        }
    }
}

switch CommandLine.arguments.dropFirst().first ?? "run" {
case "run":
    Guard().run()
case "status":
    print(WakeState.current()?.description ?? "state unknown")
    print(describe(BattleNetProcesses.running()))
case "freeze":
    print("paused \(describe(BattleNetProcesses.freeze()))")
case "thaw":
    print("resumed \(describe(BattleNetProcesses.thaw()))")
default:
    FileHandle.standardError.write("usage: bnet-sleepguard [run|status|freeze|thaw]\n".data(using: .utf8)!)
    exit(64)
}
