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

        return pids.prefix(Int(count)).compactMap { pid in
            guard pid > 0, let path = path(of: pid) else { return nil }
            return Entry(pid: pid, path: path)
        }
    }

    /// Executable path of a live process, or nil if it's gone, a zombie, or not ours.
    public static func path(of pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_status == SZOMB { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN)) // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
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
