import XCTest
@testable import BnetFixerCore

private func utc(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

final class BattleNetLogTests: XCTestCase {
    func testParsesSignInAndDisconnect() {
        guard case .loggedIn(let l)? = BattleNetLog.event(in: "I 2026-11-19 08:22:05.745193 [BNLogin] {Main} Logged into Battle.net successfully. |bnet=1:0:32bdee0|game=2:100417070:155e949") else {
            return XCTFail("not parsed")
        }
        XCTAssertEqual(l.timeIntervalSince(utc("2026-11-19T08:22:05Z")), 0.745, accuracy: 0.001)
        guard case .disconnected(let d)? = BattleNetLog.event(in: "E 2026-11-19 08:21:59.094303 [BNLogin] {Main} Disconnected from Battle.net: err=ERROR_NETWORK_MODULE_SOCKET_CLOSED (1016)") else {
            return XCTFail("not parsed")
        }
        XCTAssertEqual(d.timeIntervalSince(utc("2026-11-19T08:21:59Z")), 0.094, accuracy: 0.001)
    }

    func testIgnoresOtherLines() {
        XCTAssertNil(BattleNetLog.event(in: "I 2026-11-19 08:22:00.049039 [Main] {Main} Connecting to server. address=us.actual.battle.net port=1119"))
        XCTAssertNil(BattleNetLog.event(in: "W 2026-11-18 11:30:42.846261 [GameLaunchController] {Main} Pending game launch expired before Agent reported it running. uid=wowf"))
        XCTAssertNil(BattleNetLog.event(in: "garbage [BNLogin] Logged into Battle.net successfully"))
    }
}

final class LogFollowerTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bmf-logs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { [dir] in try? FileManager.default.removeItem(at: dir!) }
    }

    private func append(_ name: String, _ text: String) throws {
        let url = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        h.write(Data(text.utf8))
        try h.close()
    }

    func testOnlyReturnsLinesWrittenAfterStart() throws {
        try append("battle.net-1.log", "old line\n")
        var f = LogFollower(directory: dir)
        XCTAssertEqual(f.readNewLines(), [])
        try append("battle.net-1.log", "new 1\nnew 2\n")
        XCTAssertEqual(f.readNewLines(), ["new 1", "new 2"])
        XCTAssertEqual(f.readNewLines(), [])
    }

    func testHoldsPartialLinesUntilFinished() throws {
        try append("battle.net-1.log", "")
        var f = LogFollower(directory: dir)
        try append("battle.net-1.log", "half")
        XCTAssertEqual(f.readNewLines(), [])
        try append("battle.net-1.log", " done\n")
        XCTAssertEqual(f.readNewLines(), ["half done"])
    }

    func testPicksUpTheFileANewLaunchCreates() throws {
        try append("battle.net-1.log", "old\n")
        var f = LogFollower(directory: dir)
        try append("battle.net-2.log", "fresh launch line\n")
        try append("libcef-2.log", "not ours\n")
        XCTAssertEqual(f.readNewLines(), ["fresh launch line"])
    }
}

final class ReconnectTrackerTests: XCTestCase {
    let t0 = utc("2026-11-19T08:21:59Z")

    func testFastWake() {
        // 19 Nov 18:51: disconnect at once, signed in 7 s later.
        var t = ReconnectTracker()
        t.begin(at: t0)
        t.observe(.disconnected(t0 + 0.1))
        t.tick(now: t0 + 3)
        XCTAssertEqual(t.state?.phase, .waiting)
        t.observe(.loggedIn(t0 + 7))
        XCTAssertEqual(t.state?.phase, .ready)
        XCTAssertEqual(t.state?.readyAt, t0 + 7)
    }

    func testStaleConnectionIsFlaggedThenRecovers() {
        // 18 Nov 22:00: no disconnect for 76 s, signed in at ~82 s.
        var t = ReconnectTracker()
        t.begin(at: t0)
        t.tick(now: t0 + 14)
        XCTAssertEqual(t.state?.phase, .waiting)
        t.tick(now: t0 + ReconnectTracker.stuckAfter)
        XCTAssertEqual(t.state?.phase, .stuck)
        t.observe(.disconnected(t0 + 76))
        XCTAssertEqual(t.state?.phase, .waiting)
        t.observe(.loggedIn(t0 + 82))
        XCTAssertEqual(t.state?.phase, .ready)
    }

    func testIgnoresEventsFromBeforeTheWake() {
        var t = ReconnectTracker()
        t.begin(at: t0)
        t.observe(.loggedIn(t0 - 3600))
        XCTAssertEqual(t.state?.phase, .waiting)
    }

    func testRestartContinuesTheEpisodeAndIgnoresTheOldProcess() {
        var t = ReconnectTracker()
        t.begin(at: t0)
        t.tick(now: t0 + 20)
        t.beginRestart(at: t0 + 20)
        XCTAssertEqual(t.state?.phase, .restarting)
        XCTAssertEqual(t.state?.since, t0) // same episode: a dismissed overlay stays dismissed
        t.relaunched(at: t0 + 22)
        t.observe(.loggedIn(t0 + 21)) // the dying process finally reconnecting doesn't count
        XCTAssertEqual(t.state?.phase, .restarting)
        t.tick(now: t0 + 60) // no "stuck" while restarting
        XCTAssertEqual(t.state?.phase, .restarting)
        t.observe(.loggedIn(t0 + 31))
        XCTAssertEqual(t.state?.phase, .ready)
        XCTAssertEqual(t.state?.restartedAt, t0 + 20)
    }

    func testRestartWithoutAWake() {
        var t = ReconnectTracker()
        t.beginRestart(at: t0)
        XCTAssertEqual(t.state, .init(phase: .restarting, cause: .restart, since: t0, restartedAt: t0))
    }

    func testGivesUpButStillNoticesALateSignIn() {
        var t = ReconnectTracker()
        t.begin(at: t0)
        t.tick(now: t0 + ReconnectTracker.giveUpAfter)
        XCTAssertEqual(t.state?.phase, .timedOut)
        t.observe(.loggedIn(t0 + 200))
        XCTAssertEqual(t.state?.phase, .ready)
    }

    func testStateRoundTripsThroughJSON() throws {
        let s = ReconnectTracker.State(phase: .stuck, cause: .wake, since: t0)
        XCTAssertEqual(try FixerCoding.decoder.decode(ReconnectTracker.State.self, from: FixerCoding.encoder.encode(s)), s)
    }
}

final class OverlayContentTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testClock() {
        XCTAssertEqual(OverlayContent.clock(0), "0:00")
        XCTAssertEqual(OverlayContent.clock(42), "0:42")
        XCTAssertEqual(OverlayContent.clock(65), "1:05")
    }

    func testWaitingOffersRestartAsSecondary() throws {
        let c = try XCTUnwrap(OverlayContent(.init(phase: .waiting, cause: .wake, since: t0), now: t0 + 4))
        XCTAssertEqual(c.title, "Reconnecting to Battle.net…")
        XCTAssertEqual(c.timer, "0:04")
        XCTAssertTrue(c.showsRestart)
        XCTAssertFalse(c.restartIsPrimary)
    }

    func testStuckRecommendsRestart() throws {
        let c = try XCTUnwrap(OverlayContent(.init(phase: .stuck, cause: .wake, since: t0), now: t0 + 20))
        XCTAssertEqual(c.style, .suggestRestart)
        XCTAssertTrue(c.restartIsPrimary)
    }

    func testRestartingTimesFromTheRestart() throws {
        let c = try XCTUnwrap(OverlayContent(.init(phase: .restarting, cause: .wake, since: t0, restartedAt: t0 + 20), now: t0 + 25))
        XCTAssertEqual(c.timer, "0:05")
        XCTAssertFalse(c.showsRestart)
    }

    func testReadyLingersBrieflyThenHides() {
        let ready = ReconnectTracker.State(phase: .ready, cause: .wake, since: t0, readyAt: t0 + 65)
        XCTAssertEqual(OverlayContent(ready, now: t0 + 66)?.detail, "Signed back in after 1m.")
        XCTAssertNil(OverlayContent(ready, now: t0 + 65 + OverlayContent.readyLinger))
        let restarted = ReconnectTracker.State(phase: .ready, cause: .wake, since: t0, restartedAt: t0 + 20, readyAt: t0 + 34)
        XCTAssertEqual(OverlayContent(restarted, now: t0 + 35)?.detail, "Restarted and signed in after 14s.")
    }

    func testTimedOutEventuallyStopsCovering() {
        let s = ReconnectTracker.State(phase: .timedOut, cause: .wake, since: t0)
        XCTAssertEqual(OverlayContent(s, now: t0 + 200)?.style, .warning)
        XCTAssertNil(OverlayContent(s, now: t0 + OverlayContent.timedOutLinger))
        XCTAssertNil(OverlayContent(nil, now: t0))
    }

    func testHistoryRecordsHowLongItTook() {
        var log = ActivityLog(since: t0)
        log.recordReconnect(.init(phase: .ready, cause: .wake, since: t0, readyAt: t0 + 82))
        log.recordReconnect(.init(phase: .ready, cause: .wake, since: t0, restartedAt: t0 + 20, readyAt: t0 + 34))
        log.recordReconnect(.init(phase: .ready, cause: .restart, since: t0, restartedAt: t0, readyAt: t0 + 9))
        log.recordReconnect(.init(phase: .waiting, cause: .wake, since: t0))
        XCTAssertEqual(log.events.map(\.text), [
            "Battle.net signed back in 1m after waking",
            "Battle.net signed back in 14s after waking and a restart",
            "Battle.net signed back in 9s after a restart",
        ])
    }

    func testMenuSummaryWhileReconnecting() {
        let snap = FixerSnapshot(pid: 1, startedAt: t0, battleNet: .init(processCount: 8, paused: false), agent: nil,
                                 agentThreshold: 600, games: [], reconnect: .init(phase: .stuck, cause: .wake, since: t0),
                                 activity: ActivityLog(since: t0))
        let s = StatusSummary(snap, now: t0 + 30)
        XCTAssertEqual(s.health, .reconnecting)
        XCTAssertEqual(s.battleNet, "Battle.net: stuck on its old connection (0:30); restarting it is faster")
        XCTAssertTrue(s.canRestartBattleNet)
    }
}
