import Foundation

/// Reads the Battle.net desktop app's own log (~/Library/Application Support/Battle.net/Logs),
/// which is the only reliable signal for when it has signed back in after a wake.
public enum BattleNetLog {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Battle.net/Logs", isDirectory: true)
    }

    public enum Event: Equatable {
        /// It noticed its connection is dead (immediately after some wakes, ~60–100 s after others).
        case disconnected(Date)
        /// Signed in and online: launching a game will work.
        case loggedIn(Date)
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC") // Battle.net logs in UTC
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSS"
        return f
    }()

    /// Parses lines like
    /// `I 2026-11-19 08:22:05.745193 [BNLogin] {Main} Logged into Battle.net successfully. |bnet=…`
    public static func event(in line: some StringProtocol) -> Event? {
        guard line.contains("[BNLogin]") else { return nil }
        let loggedIn = line.contains("Logged into Battle.net successfully")
        guard loggedIn || line.contains("Disconnected from Battle.net") else { return nil }
        let parts = line.split(separator: " ", maxSplits: 3)
        guard parts.count >= 3, let date = stamp.date(from: "\(parts[1]) \(parts[2])") else { return nil }
        return loggedIn ? .loggedIn(date) : .disconnected(date)
    }
}

/// Follows every battle.net-*.log in a directory, returning only lines written after it was created.
/// Battle.net starts a new file each launch, so a restart is picked up automatically.
public struct LogFollower {
    public let directory: URL
    private var offsets: [String: UInt64] = [:]
    private var partial: [String: String] = [:]

    public init(directory: URL = BattleNetLog.directory) {
        self.directory = directory
        for file in logFiles() { offsets[file.path] = size(of: file) }
    }

    public mutating func readNewLines() -> [String] {
        var lines: [String] = []
        for file in logFiles() {
            let size = size(of: file)
            var offset = offsets[file.path] ?? 0 // a file we haven't seen is new: read it all
            if size < offset { offset = 0 }
            guard size > offset, let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            try? handle.seek(toOffset: offset)
            let data = handle.readData(ofLength: Int(size - offset))
            offsets[file.path] = offset + UInt64(data.count)

            var chunks = ((partial[file.path] ?? "") + String(decoding: data, as: UTF8.self)).components(separatedBy: "\n")
            partial[file.path] = chunks.removeLast() // incomplete last line, finished on a later read
            lines += chunks.filter { !$0.isEmpty }
        }
        return lines
    }

    private func logFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix("battle.net-") && $0.hasSuffix(".log") }.sorted()
            .map { directory.appendingPathComponent($0) }
    }

    private func size(of file: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
