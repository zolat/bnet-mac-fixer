import Foundation
import BnetFixerCore

/// Watches Battle.net's log after a wake or restart until it has signed back in, so the menu bar
/// can tell you when it's safe to press Play. See ReconnectTracker for the why.
final class ReconnectMonitor {
    private static let interval: TimeInterval = 0.5
    private var tracker = ReconnectTracker()
    private var follower: LogFollower?
    private var timer: Timer?
    private let recorder: ActivityRecorder

    var state: ReconnectTracker.State? { tracker.state }

    init(recorder: ActivityRecorder) {
        self.recorder = recorder
    }

    /// Call *before* resuming Battle.net, so nothing it logs the instant it wakes is missed.
    func markLog() -> LogFollower { LogFollower() }

    func wokeUp(_ follower: LogFollower, at now: Date) {
        self.follower = follower
        tracker.begin(at: now)
        startTimer()
    }

    func restarting(at now: Date) {
        if follower == nil || timer == nil { follower = LogFollower() }
        tracker.beginRestart(at: now)
        startTimer()
    }

    func relaunched(at now: Date) {
        tracker.relaunched(at: now)
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [unowned self] _ in tick() }
    }

    private func tick() {
        let before = tracker.state?.phase
        for line in follower?.readNewLines() ?? [] {
            if let event = BattleNetLog.event(in: line) { tracker.observe(event) }
        }
        let now = Date()
        tracker.tick(now: now)
        guard let state = tracker.state else { return stop() }

        if state.phase != before {
            log("reconnect: \(state.phase.rawValue) after \(Format.duration(now.timeIntervalSince(state.since)))")
            if state.phase == .ready || state.phase == .timedOut { recorder.update { $0.recordReconnect(state) } }
        }
        let start = state.restartedAt ?? state.since
        if state.phase == .ready || (state.phase == .timedOut && now.timeIntervalSince(start) >= OverlayContent.timedOutLinger) {
            stop()
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        follower = nil
    }
}
