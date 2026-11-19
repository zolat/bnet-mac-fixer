import AppKit
import BnetFixerCore

/// Locates the Battle.net app's main window through the window server. Window bounds and owners
/// are readable without Screen Recording permission (only titles need it).
struct BattleNetWindow {
    let id: CGWindowID
    /// In AppKit screen coordinates (origin bottom-left of the primary display).
    let frame: NSRect
    let isOnScreen: Bool

    static func find(pid: pid_t) -> BattleNetWindow? {
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let candidates = list.compactMap { info -> BattleNetWindow? in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 300, bounds.height >= 200 // skip the tray/menu strips it also owns
            else { return nil }
            return BattleNetWindow(id: id, frame: appKitFrame(bounds), isOnScreen: (info[kCGWindowIsOnscreen as String] as? Bool) ?? false)
        }
        return candidates.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// True when `ours` is the window immediately in front of `theirs` among on-screen app windows.
    static func isDirectlyAbove(_ ours: Int, _ theirs: CGWindowID) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ids = list.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }.compactMap { $0[kCGWindowNumber as String] as? Int }
        guard let o = ids.firstIndex(of: ours), let t = ids.firstIndex(of: Int(theirs)) else { return false }
        return t == o + 1
    }

    /// Window-server rects are top-left based on the primary display; AppKit's are bottom-left.
    private static func appKitFrame(_ r: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}
