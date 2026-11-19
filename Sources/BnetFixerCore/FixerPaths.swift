import Foundation

/// Where the daemon keeps its state and where clients find it.
public enum FixerPaths {
    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/bnet-mac-fixer", isDirectory: true)
    }

    /// Unix socket the daemon serves `ControlRequest`s on (user-only permissions).
    public static var controlSocket: String { supportDirectory.appendingPathComponent("control.sock").path }

    /// Persisted `ActivityLog`.
    public static var activity: URL { supportDirectory.appendingPathComponent("activity.json") }

    public static var log: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/bnet-mac-fixer.log")
    }

    /// Logs to seed history from on first run, oldest first (bnet-sleepguard was the previous name).
    public static var historicalLogs: [URL] {
        [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/bnet-sleepguard.log"), log]
    }
}
