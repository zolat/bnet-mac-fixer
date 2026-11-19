import Foundation

/// Rebuilds an `ActivityLog` from the daemon's text log, so history from before activity tracking
/// existed (including the bnet-sleepguard era) shows up on first run.
public enum LogImporter {
    public static func activity(fromLogs texts: [String], now: Date = Date()) -> ActivityLog {
        var parser = Parser()
        for text in texts {
            for line in text.split(separator: "\n") { parser.consume(line) }
        }
        return parser.finish(now: now)
    }

    private struct Parser {
        var log: ActivityLog?
        var pausedAt: Date?
        var backgroundWakes = 0
        // Old-format restarts weren't verified; if the next one names the same pid, the first failed.
        var unverifiedRestart: (date: Date, openFiles: Int, pid: String)?
        var stoppingOpenFiles: Int?

        private static let dates: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f
        }()

        mutating func consume(_ line: Substring) {
            guard let space = line.firstIndex(of: " "), let date = Self.dates.date(from: String(line[..<space])) else { return }
            let message = line[line.index(after: space)...]
            if log == nil { log = ActivityLog(since: date) }

            if message.hasPrefix("started:") {
                pausedAt = nil
            } else if message.hasPrefix("will sleep: paused "), !message.hasSuffix("no Battle.net processes") {
                if pausedAt == nil { pausedAt = date; backgroundWakes = 0 }
            } else if message.hasPrefix("powered on: caps="), message.contains("userAwake=false"), pausedAt != nil {
                backgroundWakes += 1
            } else if message.contains(": resumed "), let start = pausedAt {
                log?.recordSleep(pausedAt: start, resumedAt: date, backgroundWakes: backgroundWakes)
                pausedAt = nil
            } else if message.hasPrefix("agent: ") {
                consumeAgent(message, date)
            }
        }

        mutating func consumeAgent(_ message: Substring, _ date: Date) {
            let words = message.split(separator: " ")
            let openFiles = words.count > 1 ? Int(words[1]) : nil
            if message.contains("restart deferred until "), let openFiles {
                let games = message.components(separatedBy: "restart deferred until ").last?
                    .replacingOccurrences(of: " has quit", with: "")
                    .components(separatedBy: ", ") ?? []
                log?.recordAgentDeferred(at: date, openFiles: openFiles, games: games)
            } else if message.contains("; restarted pid "), let openFiles, let pid = words.last {
                if let previous = unverifiedRestart, previous.pid != pid {
                    log?.recordAgentRestart(at: previous.date, openFiles: previous.openFiles, outcome: .exited, manual: false)
                } else if let previous = unverifiedRestart {
                    log?.recordAgentRestart(at: previous.date, openFiles: previous.openFiles, outcome: .failed, manual: false)
                }
                unverifiedRestart = (date, openFiles, String(pid))
            } else if message.contains("; stopping pid ") {
                stoppingOpenFiles = openFiles
            } else if message.hasPrefix("agent: pid ") {
                let outcome: ActivityLog.RestartOutcome =
                    message.contains(" exited") ? .exited : message.contains("force-quit") ? .forceQuit : .failed
                log?.recordAgentRestart(at: date, openFiles: stoppingOpenFiles, outcome: outcome, manual: false)
                stoppingOpenFiles = nil
            }
            if let openFiles, message.contains("open files") { log?.observeAgent(openFiles: openFiles) }
        }

        mutating func finish(now: Date) -> ActivityLog {
            if let previous = unverifiedRestart {
                log?.recordAgentRestart(at: previous.date, openFiles: previous.openFiles, outcome: .exited, manual: false)
            }
            log?.sortEvents()
            return log ?? ActivityLog(since: now)
        }
    }
}
