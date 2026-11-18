import Darwin

/// The Battle.net Agent: the background process (/Users/Shared/Battle.net/Agent/Agent.<build>/Agent.app)
/// that installs, updates and launches games.
public enum BattleNetAgent {
    public struct Instance: Equatable {
        public let pid: pid_t
        public let path: String
    }

    public static func isAgent(executablePath path: String) -> Bool {
        path.hasPrefix("/Users/Shared/Battle.net/Agent/") && path.hasSuffix("/Agent.app/Contents/MacOS/Agent")
    }

    public static func running(in table: [ProcessTable.Entry] = ProcessTable.all()) -> [Instance] {
        table.filter { isAgent(executablePath: $0.path) }.map { Instance(pid: $0.pid, path: $0.path) }
    }

    /// Asks the Agent to quit. Battle.net relaunches it on demand within a couple of seconds.
    @discardableResult
    public static func terminate(_ instance: Instance) -> Bool {
        kill(instance.pid, SIGTERM) == 0
    }
}
