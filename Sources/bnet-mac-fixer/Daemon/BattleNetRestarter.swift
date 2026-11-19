import AppKit
import BnetFixerCore

/// Quits and relaunches the Battle.net desktop app. A fresh launch signs in within seconds, which
/// beats waiting a minute or more for a woken Battle.net to notice its connection is dead.
final class BattleNetRestarter {
    private static let quitGrace: TimeInterval = 10
    private(set) var isRestarting = false

    /// Calls `relaunched` once the new process has been started (or failed to start).
    func restart(relaunched: @escaping (_ ok: Bool, _ message: String) -> Void) {
        guard !isRestarting else { return relaunched(false, "Battle.net is already restarting") }
        isRestarting = true
        let table = ProcessTable.all()
        let procs = BattleNetProcesses.running(in: table)
        let appURL = Self.appURL(table: table)

        // A normal app quit (like ⌘Q): Battle.net ignores SIGTERM, but quits cleanly on this in ~7 s.
        for p in procs where p.role == .main { NSRunningApplication(processIdentifier: p.pid)?.terminate() }
        waitForExit(deadline: Date().addingTimeInterval(Self.quitGrace)) { [unowned self] in
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: config) { app, error in
                DispatchQueue.main.async {
                    self.isRestarting = false
                    if let app {
                        relaunched(true, "Relaunched Battle.net (pid \(app.processIdentifier))")
                    } else {
                        relaunched(false, "Couldn't relaunch Battle.net: \(error?.localizedDescription ?? "unknown error")")
                    }
                }
            }
        }
    }

    private func waitForExit(deadline: Date, then: @escaping () -> Void) {
        let remaining = BattleNetProcesses.running()
        if remaining.isEmpty { return then() }
        if deadline.timeIntervalSinceNow <= 0 {
            log("restart: Battle.net didn't quit within \(Int(Self.quitGrace)) s; killing \(describe(remaining))")
            for p in remaining { kill(p.pid, SIGKILL) }
            return DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: then)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [unowned self] in waitForExit(deadline: deadline, then: then) }
    }

    private static func appURL(table: [ProcessTable.Entry]) -> URL {
        if let main = table.first(where: { BattleNetProcesses.role(forExecutablePath: $0.path) == .main }),
           let range = main.path.range(of: ".app/", options: .backwards) {
            return URL(fileURLWithPath: String(main.path[..<range.lowerBound]) + ".app")
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.battle.app")
            ?? URL(fileURLWithPath: "/Applications/Battle.net.app")
    }
}
