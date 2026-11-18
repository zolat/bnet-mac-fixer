import AppKit
import Foundation
import BnetFixerCore

/// Keeps Battle.net running across sleep without it reconnecting during DarkWakes.
///
/// Why: during Power Nap / maintenance wakes Battle.net reconnects, Blizzard issues a
/// token-security-checkpoint, and the Mac sleeps again before it completes — which
/// invalidates the saved login. Pausing the app for the whole sleep (including DarkWakes)
/// and resuming only on a real, user-facing wake means it reconnects once, fully awake.
final class SleepGuard {
    private static let sleepAckGrace: TimeInterval = 1
    private let power = PowerMonitor()
    private(set) var isPaused = false
    private var policy = ResumePolicy()
    private var loggedSettling = false
    private var pollTimer: Timer?

    func start() {
        // Recover from a previous instance dying while Battle.net was paused.
        if WakeState.current()?.isUserAwake ?? true {
            BattleNetProcesses.thaw()
        }

        power.onWillSleep = { [unowned self] allowSleep in
            let pause = { [unowned self] in
                let procs = BattleNetProcesses.freeze()
                isPaused = !procs.isEmpty
                policy.reset()
                loggedSettling = false
                log("will sleep: paused \(describe(procs))")
                allowSleep()
            }
            // Battle.net (via its embedded Chromium) registers for the same sleep notification.
            // A stopped process can't acknowledge it, which makes the kernel wait 30 s before
            // sleeping — so if it's still running, give it a moment to ack before pausing it.
            // Our own ack is withheld until then, so the system can't sleep in between.
            if isPaused {
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
            if isPaused { resumeIfUserAwake(reason: "poll") }
        }
    }

    private func resumeIfUserAwake(reason: String) {
        guard isPaused else { return }
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
            isPaused = false
            loggedSettling = false
            log("\(reason): resumed \(describe(procs)) [\(state?.description ?? "state unknown")]")
        }
    }
}
