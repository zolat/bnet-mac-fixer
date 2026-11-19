import Foundation

/// What the reconnect status bar says for a given state. Nil means don't show it.
/// Kept to one short line: it sits along the top of the Battle.net window and is easy to ignore.
public struct OverlayContent: Equatable {
    public enum Style: Equatable { case waiting, suggestRestart, busy, success, warning }

    public var style: Style
    public var title: String
    public var detail: String
    /// Elapsed time, e.g. "0:42".
    public var timer: String?
    public var showsRestart: Bool
    public var restartIsPrimary: Bool

    /// How long "Ready" stays up before the overlay disappears.
    public static let readyLinger: TimeInterval = 2.5
    /// After giving up, stop covering the window eventually even if nobody dismisses it.
    public static let timedOutLinger: TimeInterval = 600

    public init?(_ state: ReconnectTracker.State?, now: Date) {
        guard let state else { return nil }
        let start = state.restartedAt ?? state.since
        let timer = Self.clock(now.timeIntervalSince(state.since))
        switch state.phase {
        case .waiting:
            self.init(style: .waiting, title: "Reconnecting to Battle.net…",
                      detail: "Wait before pressing Play: games launched now can fail to sign in.",
                      timer: timer, showsRestart: true, restartIsPrimary: false)
        case .stuck:
            self.init(style: .suggestRestart, title: "Battle.net is stuck on its old connection",
                      detail: "It can take another minute to notice. Restarting is faster (about 10 s).",
                      timer: timer, showsRestart: true, restartIsPrimary: true)
        case .restarting:
            self.init(style: .busy, title: "Restarting Battle.net…",
                      detail: "It will sign back in by itself.",
                      timer: Self.clock(now.timeIntervalSince(start)), showsRestart: false, restartIsPrimary: false)
        case .ready:
            guard let readyAt = state.readyAt, now.timeIntervalSince(readyAt) < Self.readyLinger else { return nil }
            let took = Format.duration(readyAt.timeIntervalSince(start))
            self.init(style: .success, title: "Battle.net is ready",
                      detail: state.restartedAt == nil ? "Signed back in after \(took)." : "Restarted and signed in after \(took).",
                      timer: nil, showsRestart: false, restartIsPrimary: false)
        case .timedOut:
            guard now.timeIntervalSince(start) < Self.timedOutLinger else { return nil }
            self.init(style: .warning, title: "Battle.net still hasn't signed back in",
                      detail: "Restarting it usually fixes this.",
                      timer: timer, showsRestart: true, restartIsPrimary: true)
        }
    }

    public init(style: Style, title: String, detail: String, timer: String?, showsRestart: Bool, restartIsPrimary: Bool) {
        self.style = style
        self.title = title
        self.detail = detail
        self.timer = timer
        self.showsRestart = showsRestart
        self.restartIsPrimary = restartIsPrimary
    }

    /// 42 -> "0:42", 65 -> "1:05".
    public static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return "\(s / 60):" + (s % 60 < 10 ? "0" : "") + "\(s % 60)"
    }
}
