import XCTest
@testable import BnetFixerCore

final class FormatTests: XCTestCase {
    func testDuration() {
        XCTAssertEqual(Format.duration(45), "45s")
        XCTAssertEqual(Format.duration(12 * 60 + 5), "12m")
        XCTAssertEqual(Format.duration(6 * 3600 + 12 * 60), "6h 12m")
        XCTAssertEqual(Format.duration(2 * 86400 + 3 * 3600 + 59), "2d 3h")
        XCTAssertEqual(Format.duration(-5), "0s")
    }

    func testCountAndPlural() {
        XCTAssertEqual(Format.count(7), "7")
        XCTAssertEqual(Format.count(2740), "2,740")
        XCTAssertEqual(Format.count(1_234_567), "1,234,567")
        XCTAssertEqual(Format.plural(1, "sleep"), "1 sleep")
        XCTAssertEqual(Format.plural(3, "sleep"), "3 sleeps")
        XCTAssertEqual(Format.list(["World of Warcraft", "WowVoiceProxy"]), "World of Warcraft and WowVoiceProxy")
    }
}

final class ActivityLogTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testSleepTotals() {
        var log = ActivityLog(since: t0)
        log.recordSleep(pausedAt: t0, resumedAt: t0 + 3600, backgroundWakes: 4)
        log.recordSleep(pausedAt: t0 + 7200, resumedAt: t0 + 7260, backgroundWakes: 0)
        XCTAssertEqual(log.sleepsGuarded, 2)
        XCTAssertEqual(log.backgroundWakesHeld, 4)
        XCTAssertEqual(log.secondsPaused, 3660)
        XCTAssertEqual(log.events.map(\.text), [
            "Kept Battle.net paused for 1h 0m of sleep, held through 4 background wakes",
            "Kept Battle.net paused for 1m of sleep",
        ])
    }

    func testAgentRestartOutcomes() {
        var log = ActivityLog(since: t0)
        log.recordAgentRestart(at: t0, openFiles: 2740, outcome: .exited, manual: false)
        log.recordAgentRestart(at: t0, openFiles: 2398, outcome: .forceQuit, manual: false)
        log.recordAgentRestart(at: t0, openFiles: 250, outcome: .failed, manual: true)
        XCTAssertEqual(log.agentRestarts, 2)
        XCTAssertEqual(log.agentForceQuits, 1)
        XCTAssertEqual(log.events.last?.text, "Couldn't restart the Agent at 250 open files (from the menu)")
    }

    func testHistoryIsCapped() {
        var log = ActivityLog(since: t0)
        for i in 0..<(ActivityLog.maxEvents + 5) { log.note("n\(i)", at: t0 + Double(i)) }
        XCTAssertEqual(log.events.count, ActivityLog.maxEvents)
        XCTAssertEqual(log.events.first?.text, "n5")
    }

    func testRoundTripsThroughJSON() throws {
        var log = ActivityLog(since: t0)
        log.recordSleep(pausedAt: t0, resumedAt: t0 + 90, backgroundWakes: 1)
        log.observeAgent(openFiles: 900)
        let data = try FixerCoding.encoder.encode(log)
        XCTAssertEqual(try FixerCoding.decoder.decode(ActivityLog.self, from: data), log)
    }
}

final class LogImporterTests: XCTestCase {
    // Trimmed from real bnet-sleepguard / bnet-mac-fixer logs.
    let sleepguard = """
    2026-11-17T19:58:10+10:30 started: caps=0xf lidClosed=false lidCausesSleep=true userAwake=true; watching 100(main)
    2026-11-17T20:00:00+10:30 will sleep: paused 100(main) 101(helper)
    2026-11-17T20:05:00+10:30 powered on: caps=0x9 lidClosed=true lidCausesSleep=false userAwake=false
    2026-11-17T20:20:00+10:30 powered on: caps=0xf lidClosed=true lidCausesSleep=true userAwake=false
    2026-11-17T21:00:00+10:30 will sleep: paused 100(main) 101(helper)
    2026-11-18T02:00:00+10:30 powered on: caps=0xf lidClosed=false lidCausesSleep=false userAwake=true
    2026-11-18T02:00:00+10:30 powered on: resumed 101(helper) 100(main) [caps=0xf lidClosed=false lidCausesSleep=false userAwake=true]
    2026-11-18T03:00:00+10:30 will sleep: paused no Battle.net processes
    2026-11-18T03:30:00+10:30 poll: resumed no Battle.net processes [caps=0xf]
    """
    let fixer = """
    2026-11-18T20:08:56+10:30 agent: 2400 open files (limit ~1024); restart deferred until WowVoiceProxy, World of Warcraft has quit
    2026-11-18T20:08:56+10:30 started: caps=0xf lidClosed=false lidCausesSleep=true userAwake=true; watching 59868(main)
    2026-11-18T21:50:41+10:30 will sleep: paused 59868(main)
    2026-11-18T22:00:17+10:30 poll: resumed 59868(main) [caps=0xf lidClosed=false lidCausesSleep=false userAwake=true]
    2026-11-18T22:00:47+10:30 agent: 2398 open files (limit ~1024); restarted pid 60831
    2026-11-18T22:01:47+10:30 agent: 2440 open files (limit ~1024); restart deferred until World of Warcraft has quit
    2026-11-19T18:52:08+10:30 agent: 2740 open files (limit ~1024); restarted pid 60831
    2026-11-20T10:00:00+10:30 agent: 700 open files (limit ~1024); stopping pid 92750
    2026-11-20T10:00:15+10:30 agent: pid 92750 ignored SIGTERM, force-quit it; Battle.net relaunches it on demand
    """

    func testRebuildsTotals() {
        let log = LogImporter.activity(fromLogs: [sleepguard, fixer])
        XCTAssertEqual(log.since, ISO8601DateFormatter().date(from: "2026-11-17T09:28:10Z"))
        // A sleep that re-sleeps while still paused counts once, from the first pause.
        XCTAssertEqual(log.sleepsGuarded, 2)
        XCTAssertEqual(log.secondsPaused, 6 * 3600 + 9 * 60 + 36)
        XCTAssertEqual(log.backgroundWakesHeld, 2)
        XCTAssertEqual(log.peakAgentOpenFiles, 2740)
    }

    func testRepeatedPidMeansFirstRestartFailed() {
        let log = LogImporter.activity(fromLogs: [fixer])
        XCTAssertEqual(log.agentRestarts, 2) // 18:52 (pid really changed) + the force-quit
        XCTAssertEqual(log.agentForceQuits, 1)
        let agentEvents = log.events.filter { $0.kind == .agent }.map(\.text)
        XCTAssertEqual(agentEvents, [
            "Agent at 2,400 open files; restart waits until WowVoiceProxy and World of Warcraft quits",
            "Couldn't restart the Agent at 2,398 open files",
            "Agent at 2,440 open files; restart waits until World of Warcraft quits",
            "Restarted the Agent at 2,740 open files",
            "Force-quit the Agent at 700 open files after it ignored a restart",
        ])
    }

    func testEmptyLogsStartNow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(LogImporter.activity(fromLogs: ["", "garbage line"], now: now), ActivityLog(since: now))
    }
}

final class ControlSocketTests: XCTestCase {
    func testRoundTrip() throws {
        let path = NSTemporaryDirectory() + "bmf-\(getpid()).sock"
        let server = ControlServer(path: path, handlerQueue: DispatchQueue(label: "test"))
        var seen: [ControlRequest.Command] = []
        try server.start { request in
            seen.append(request.command)
            return ControlResponse(ok: true, message: "got \(request.command.rawValue)")
        }
        defer { server.stop() }

        XCTAssertEqual(try ControlClient.send(.init(.status), path: path).message, "got status")
        XCTAssertEqual(try ControlClient.send(.init(.restartAgent), path: path).message, "got restart-agent")
        XCTAssertEqual(seen, [.status, .restartAgent])
    }

    func testNoDaemonIsNotRunning() {
        XCTAssertThrowsError(try ControlClient.send(.init(.status), path: NSTemporaryDirectory() + "nope-\(getpid()).sock")) {
            XCTAssertEqual($0 as? ControlError, .notRunning)
        }
    }

    func testRejectsGarbage() throws {
        let path = NSTemporaryDirectory() + "bmf-g-\(getpid()).sock"
        let server = ControlServer(path: path, handlerQueue: DispatchQueue(label: "test"))
        try server.start { _ in ControlResponse(ok: true) }
        defer { server.stop() }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = try UnixSocket.address(path)
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        UnixSocket.configure(fd, timeout: 2)
        UnixSocket.write(fd, Data("not json\n".utf8))
        let reply = try FixerCoding.decoder.decode(ControlResponse.self, from: XCTUnwrap(UnixSocket.readLine(fd)))
        XCTAssertFalse(reply.ok)
    }

    func testSocketIsUserOnly() throws {
        let path = NSTemporaryDirectory() + "bmf-p-\(getpid()).sock"
        let server = ControlServer(path: path, handlerQueue: DispatchQueue(label: "test"))
        try server.start { _ in ControlResponse(ok: true) }
        defer { server.stop() }
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }
}

final class StatusSummaryTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func snapshot(paused: Bool = false, openFiles: Int? = 252, games: [String] = [], restarting: Bool = false) -> FixerSnapshot {
        var activity = ActivityLog(since: now - 86400)
        activity.recordSleep(pausedAt: now - 7200, resumedAt: now - 3600, backgroundWakes: 3)
        activity.observeAgent(openFiles: 2740)
        return FixerSnapshot(
            pid: 1, startedAt: now - 60,
            battleNet: .init(processCount: 8, paused: paused, pausedSince: paused ? now - 180 : nil),
            agent: openFiles.map { .init(pid: 92750, openFiles: $0) }, agentThreshold: 600,
            agentRestarting: restarting, games: games, activity: activity
        )
    }

    func testOffline() {
        let s = StatusSummary(nil, now: now)
        XCTAssertEqual(s.health, .offline)
        XCTAssertFalse(s.canRestartAgent)
    }

    func testHealthy() {
        let s = StatusSummary(snapshot(), now: now)
        XCTAssertEqual(s.health, .ok)
        XCTAssertEqual(s.agent, "Agent: 252 open files, healthy (restarts at 600)")
        XCTAssertNil(s.games)
        XCTAssertEqual(s.totals, [
            "1 sleep guarded, 1h 0m paused in total",
            "3 background wakes held (each a possible logout)",
            "0 Agent restarts, peak 2,740 open files",
        ])
        XCTAssertTrue(s.canRestartAgent)
        XCTAssertFalse(s.canResumeBattleNet)
    }

    func testLeakingWhilePlaying() {
        let s = StatusSummary(snapshot(openFiles: 2400, games: ["World of Warcraft"]), now: now)
        XCTAssertEqual(s.health, .attention)
        XCTAssertEqual(s.agent, "Agent: 2,400 open files, updates will fail; restarts after World of Warcraft quits")
        XCTAssertEqual(s.games, "Playing: World of Warcraft")
    }

    func testLeakingIdle() {
        XCTAssertEqual(StatusSummary(snapshot(openFiles: 700), now: now).agent, "Agent: 700 open files, restarting within a few minutes")
    }

    func testPaused() {
        let s = StatusSummary(snapshot(paused: true), now: now)
        XCTAssertEqual(s.health, .paused)
        XCTAssertEqual(s.battleNet, "Battle.net: paused for 3m since the Mac slept; resumes on a full wake")
        XCTAssertTrue(s.canResumeBattleNet)
    }

    func testRestartingAndNoAgent() {
        XCTAssertEqual(StatusSummary(snapshot(restarting: true), now: now).agent, "Agent: restarting…")
        XCTAssertFalse(StatusSummary(snapshot(restarting: true), now: now).canRestartAgent)
        XCTAssertEqual(StatusSummary(snapshot(openFiles: nil), now: now).agent, "Agent: not running (Battle.net starts it when needed)")
    }
}
