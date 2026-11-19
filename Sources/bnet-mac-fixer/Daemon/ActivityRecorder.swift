import Foundation
import BnetFixerCore

/// Owns the daemon's `ActivityLog` and keeps it on disk. On first run it's rebuilt from the text logs.
final class ActivityRecorder {
    private(set) var activity: ActivityLog
    private let url: URL

    init(url: URL = FixerPaths.activity, historicalLogs: [URL] = FixerPaths.historicalLogs) {
        self.url = url
        if let data = try? Data(contentsOf: url), let saved = try? FixerCoding.decoder.decode(ActivityLog.self, from: data) {
            activity = saved
        } else {
            let texts = historicalLogs.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            activity = LogImporter.activity(fromLogs: texts)
            log("activity: imported history since \(activity.since) from logs (\(activity.sleepsGuarded) sleeps, \(activity.agentRestarts) Agent restarts)")
            save()
        }
    }

    func update(_ change: (inout ActivityLog) -> Void) {
        let before = activity
        change(&activity)
        if activity != before { save() }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FixerCoding.encoder.encode(activity).write(to: url, options: .atomic)
        } catch {
            log("activity: couldn't save \(url.path): \(error)")
        }
    }
}
