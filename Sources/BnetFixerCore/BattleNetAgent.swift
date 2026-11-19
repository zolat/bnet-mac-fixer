import Darwin
import Foundation

/// The Battle.net Agent: the background process (/Users/Shared/Battle.net/Agent/Agent.<build>/Agent.app)
/// that installs, updates and launches games.
public enum BattleNetAgent {
    public struct Instance: Equatable {
        public let pid: pid_t
        public let path: String

        public init(pid: pid_t, path: String) {
            self.pid = pid
            self.path = path
        }
    }

    public static func isAgent(executablePath path: String) -> Bool {
        path.hasPrefix("/Users/Shared/Battle.net/Agent/") && path.hasSuffix("/Agent.app/Contents/MacOS/Agent")
    }

    public static func running(in table: [ProcessTable.Entry] = ProcessTable.all()) -> [Instance] {
        table.filter { isAgent(executablePath: $0.path) }.map { Instance(pid: $0.pid, path: $0.path) }
    }

    /// True while this exact process is alive (same pid *and* executable, so pid reuse doesn't count).
    public static func isRunning(_ instance: Instance) -> Bool {
        ProcessTable.path(of: instance.pid) == instance.path
    }

    public enum StopResult: Equatable {
        /// Quit on SIGTERM.
        case exited
        /// Ignored SIGTERM for the whole grace period and was killed.
        case forceQuit
        case stillRunning
        case signalFailed
    }

    /// Stops the Agent; Battle.net relaunches it on demand within a couple of seconds.
    ///
    /// SIGTERM first, then SIGKILL if it's still running after `grace`. The Agent doesn't always
    /// honour SIGTERM — it was seen ignoring it mid-update while its downloader was failing with
    /// 5007 — and a leaking Agent left running is exactly what breaks updates.
    public static func stop(
        _ instance: Instance,
        grace: TimeInterval = 15,
        queue: DispatchQueue = .main,
        completion: @escaping (StopResult) -> Void
    ) {
        guard kill(instance.pid, SIGTERM) == 0 else { return completion(isRunning(instance) ? .signalFailed : .exited) }
        waitForExit(instance, timeout: grace, queue: queue) { exited in
            if exited { return completion(.exited) }
            kill(instance.pid, SIGKILL)
            waitForExit(instance, timeout: 2, queue: queue) { completion($0 ? .forceQuit : .stillRunning) }
        }
    }

    private static func waitForExit(_ instance: Instance, timeout: TimeInterval, queue: DispatchQueue, done: @escaping (Bool) -> Void) {
        let interval: TimeInterval = 0.25
        func poll(remaining: TimeInterval) {
            if !isRunning(instance) { return done(true) }
            if remaining <= 0 { return done(false) }
            queue.asyncAfter(deadline: .now() + interval) { poll(remaining: remaining - interval) }
        }
        queue.async { poll(remaining: timeout) }
    }
}
