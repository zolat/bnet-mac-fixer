import Darwin

/// Finds the Battle.net desktop app's processes (main + CEF helpers) and pauses/resumes them.
/// The Agent (/Users/Shared/Battle.net/Agent) and games are deliberately left alone.
public enum BattleNetProcesses {
    public enum Role: Equatable { case main, helper }

    public struct Process: Equatable {
        public let pid: pid_t
        public let role: Role
    }

    /// Classifies an executable path. Pure, so it's unit-testable.
    public static func role(forExecutablePath path: String) -> Role? {
        if path.hasSuffix("/Battle.net.app/Contents/MacOS/Battle.net") { return .main }
        if path.contains("/Battle.net Helper.app/Contents/MacOS/") { return .helper }
        return nil
    }

    public static func running(in table: [ProcessTable.Entry] = ProcessTable.all()) -> [Process] {
        table.compactMap { entry in
            role(forExecutablePath: entry.path).map { Process(pid: entry.pid, role: $0) }
        }
    }

    /// Pause: main process first (stops it initiating anything), then helpers.
    @discardableResult
    public static func freeze() -> [Process] {
        let procs = running().sorted { rank($0, first: .main) < rank($1, first: .main) }
        for p in procs { kill(p.pid, SIGSTOP) }
        return procs
    }

    /// Resume: helpers first so the main process finds them responsive, then main.
    @discardableResult
    public static func thaw() -> [Process] {
        let procs = running().sorted { rank($0, first: .helper) < rank($1, first: .helper) }
        for p in procs { kill(p.pid, SIGCONT) }
        return procs
    }

    private static func rank(_ p: Process, first: Role) -> Int { p.role == first ? 0 : 1 }
}
