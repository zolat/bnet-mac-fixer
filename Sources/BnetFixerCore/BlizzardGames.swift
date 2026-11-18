import Foundation

/// Detects running Blizzard games without a hard-coded list: every game the Agent installs has a
/// `.build.info` file at its install root (e.g. /Applications/World of Warcraft/.build.info), and
/// Battle.net itself and the Agent don't.
public struct BlizzardGames {
    private let fileExists: (String) -> Bool
    private var cache: [String: Bool] = [:]

    public init(fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.fileExists = fileExists
    }

    /// The install root containing `.build.info`, searching up from the executable's directory.
    public func installRoot(forExecutablePath path: String) -> String? {
        var dir = (path as NSString).deletingLastPathComponent
        while dir.count > 1 {
            if fileExists(dir + "/.build.info") { return dir }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    public mutating func isGame(executablePath path: String) -> Bool {
        if let known = cache[path] { return known }
        let result = installRoot(forExecutablePath: path) != nil
        cache[path] = result
        return result
    }

    public mutating func running(in table: [ProcessTable.Entry] = ProcessTable.all()) -> [ProcessTable.Entry] {
        table.filter { isGame(executablePath: $0.path) }
    }
}
