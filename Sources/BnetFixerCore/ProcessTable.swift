import Darwin

/// Thin wrapper over libproc: running processes and their open file counts.
/// Only works for processes owned by the same user, which covers Battle.net, its Agent and games.
public enum ProcessTable {
    public struct Entry: Equatable {
        public let pid: pid_t
        public let path: String
    }

    public static func all() -> [Entry] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }

        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN)) // PROC_PIDPATHINFO_MAXSIZE
        var entries: [Entry] = []
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else { continue }
            entries.append(Entry(pid: pid, path: String(cString: pathBuffer)))
        }
        return entries
    }

    /// Number of open file descriptors, or nil if the process is gone or not ours.
    public static func openFileCount(_ pid: pid_t) -> Int? {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let estimate = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard estimate > 0 else { return nil }
        // The estimate can be stale by the time we ask again; leave headroom.
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(estimate) / stride + 64)
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard bytes > 0 else { return nil }
        return Int(bytes) / stride
    }
}
