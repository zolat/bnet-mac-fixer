import Foundation

/// Decides when a paused Battle.net may be resumed.
///
/// Lid open + user-facing wake: resume immediately.
/// Lid closed but reporting awake (HID/USB bump wakes, or genuine clamshell mode with an
/// external display): only resume once that state has held for `lidClosedSettle` seconds,
/// because bump wakes fall back to sleep within seconds — too soon for a security checkpoint.
public struct ResumePolicy {
    public var lidClosedSettle: TimeInterval
    private var lidClosedAwakeSince: Date?

    public init(lidClosedSettle: TimeInterval = 90) {
        self.lidClosedSettle = lidClosedSettle
    }

    public enum Decision: Equatable {
        case stayPaused
        /// Awake with the lid closed; waiting until the given time before resuming.
        case settling(until: Date)
        case resume
    }

    public mutating func evaluate(_ state: WakeState?, now: Date) -> Decision {
        guard let state, state.isUserAwake else {
            lidClosedAwakeSince = nil
            return .stayPaused
        }
        guard state.clamshellClosed else {
            lidClosedAwakeSince = nil
            return .resume
        }
        let since = lidClosedAwakeSince ?? now
        lidClosedAwakeSince = since
        // Compare TimeIntervals, not Dates: the SDK's `Date >=` symbol is missing from this
        // macOS build's Foundation and resolves to a null pointer at runtime.
        if now.timeIntervalSince(since) >= lidClosedSettle { return .resume }
        return .settling(until: since.addingTimeInterval(lidClosedSettle))
    }

    /// Call when the system is about to sleep, so a settle window never spans a sleep.
    public mutating func reset() {
        lidClosedAwakeSince = nil
    }
}
