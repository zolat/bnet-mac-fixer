import XCTest
@testable import BnetFixerCore

final class AgentRestartPolicyTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testHealthyBelowThreshold() {
        var p = AgentRestartPolicy(threshold: 600)
        XCTAssertEqual(p.evaluate(openFiles: 105, gameRunning: false, now: t0), .healthy)
        XCTAssertEqual(p.evaluate(openFiles: 599, gameRunning: true, now: t0), .healthy)
    }

    func testNoAgentIsHealthy() {
        var p = AgentRestartPolicy()
        XCTAssertEqual(p.evaluate(openFiles: nil, gameRunning: false, now: t0), .healthy)
    }

    func testRestartsWhenLeakingAndNoGame() {
        var p = AgentRestartPolicy(threshold: 600)
        // As observed: 1,273 descriptors after four WoW launches, updates failing with 5007.
        XCTAssertEqual(p.evaluate(openFiles: 1273, gameRunning: false, now: t0), .restart)
    }

    func testWaitsWhileGameRunning() {
        var p = AgentRestartPolicy(threshold: 600)
        XCTAssertEqual(p.evaluate(openFiles: 900, gameRunning: true, now: t0), .waitingForGame)
    }

    func testWaitsForQuietPeriodAfterGameQuits() {
        var p = AgentRestartPolicy(threshold: 600, gameQuietPeriod: 30)
        _ = p.evaluate(openFiles: 900, gameRunning: true, now: t0)
        XCTAssertEqual(p.evaluate(openFiles: 900, gameRunning: false, now: t0 + 10), .waitingForGame)
        XCTAssertEqual(p.evaluate(openFiles: 900, gameRunning: false, now: t0 + 30), .restart)
    }

    func testCooldownPreventsRestartLoop() {
        var p = AgentRestartPolicy(threshold: 600, cooldown: 300)
        XCTAssertEqual(p.evaluate(openFiles: 900, gameRunning: false, now: t0), .restart)
        p.didRestart(at: t0)
        XCTAssertEqual(p.evaluate(openFiles: 900, gameRunning: false, now: t0 + 60), .coolingDown)
        XCTAssertEqual(p.evaluate(openFiles: 900, gameRunning: false, now: t0 + 300), .restart)
    }

    func testGameStartingDuringCooldownStillDefers() {
        var p = AgentRestartPolicy(threshold: 600, gameQuietPeriod: 30, cooldown: 300)
        p.didRestart(at: t0)
        XCTAssertEqual(p.evaluate(openFiles: 900, gameRunning: true, now: t0 + 400), .waitingForGame)
    }
}

final class BattleNetAgentTests: XCTestCase {
    func testMatchesVersionedAgent() {
        XCTAssertTrue(BattleNetAgent.isAgent(executablePath: "/Users/Shared/Battle.net/Agent/Agent.9886/Agent.app/Contents/MacOS/Agent"))
        XCTAssertTrue(BattleNetAgent.isAgent(executablePath: "/Users/Shared/Battle.net/Agent/Agent.9873/Agent.app/Contents/MacOS/Agent"))
    }

    func testIgnoresOtherBlizzardProcesses() {
        XCTAssertFalse(BattleNetAgent.isAgent(executablePath: "/Applications/Battle.net.app/Contents/MacOS/Battle.net"))
        XCTAssertFalse(BattleNetAgent.isAgent(executablePath: "/Users/Shared/Battle.net/Agent/Blizzard Error.app/Contents/MacOS/Blizzard Error"))
        XCTAssertFalse(BattleNetAgent.isAgent(executablePath: "/System/Library/CoreServices/WiFiAgent.app/Contents/MacOS/WiFiAgent"))
    }

    func testFindsAgentInProcessTable() {
        let table = [
            ProcessTable.Entry(pid: 1, path: "/sbin/launchd"),
            ProcessTable.Entry(pid: 60831, path: "/Users/Shared/Battle.net/Agent/Agent.9886/Agent.app/Contents/MacOS/Agent"),
        ]
        XCTAssertEqual(BattleNetAgent.running(in: table).map(\.pid), [60831])
    }
}

final class BlizzardGamesTests: XCTestCase {
    // Mirrors the real layout: only the install root has .build.info.
    let markers: Set<String> = ["/Applications/World of Warcraft/.build.info", "/Games/Diablo IV/.build.info"]
    var games: BlizzardGames { BlizzardGames(fileExists: { [markers] in markers.contains($0) }) }

    func testFindsInstallRootFromNestedExecutable() {
        let wow = "/Applications/World of Warcraft/_forever_/World of Warcraft.app/Contents/MacOS/World of Warcraft"
        XCTAssertEqual(games.installRoot(forExecutablePath: wow), "/Applications/World of Warcraft")
        XCTAssertEqual(games.installRoot(forExecutablePath: "/Games/Diablo IV/Diablo IV.app/Contents/MacOS/Diablo IV"), "/Games/Diablo IV")
    }

    func testBattleNetAgentAndSystemAreNotGames() {
        var g = games
        XCTAssertFalse(g.isGame(executablePath: "/Applications/Battle.net.app/Contents/MacOS/Battle.net"))
        XCTAssertFalse(g.isGame(executablePath: "/Users/Shared/Battle.net/Agent/Agent.9886/Agent.app/Contents/MacOS/Agent"))
        XCTAssertFalse(g.isGame(executablePath: "/sbin/launchd"))
    }

    func testHelpersAreNamedAfterTheirGame() {
        let wow = "/Applications/World of Warcraft/_forever_/World of Warcraft.app"
        let entries = [
            ProcessTable.Entry(pid: 1, path: wow + "/Contents/MacOS/World of Warcraft"),
            ProcessTable.Entry(pid: 2, path: wow + "/Contents/Helpers/WowVoiceProxy.app/Contents/MacOS/WowVoiceProxy"),
            ProcessTable.Entry(pid: 3, path: "/Games/Diablo IV/Diablo IV.app/Contents/MacOS/Diablo IV"),
        ]
        XCTAssertEqual(BlizzardGames.displayNames(entries), ["Diablo IV", "World of Warcraft"])
        XCTAssertEqual(BlizzardGames.displayName(forExecutablePath: "/Games/bin/tool"), "tool")
    }

    func testRunningFiltersTable() {
        var g = games
        let table = [
            ProcessTable.Entry(pid: 10, path: "/Applications/Battle.net.app/Contents/MacOS/Battle.net"),
            ProcessTable.Entry(pid: 61043, path: "/Applications/World of Warcraft/_forever_/World of Warcraft.app/Contents/MacOS/World of Warcraft"),
        ]
        XCTAssertEqual(g.running(in: table).map(\.pid), [61043])
    }
}

final class ProcessTableTests: XCTestCase {
    func testOwnOpenFileCountIsReadable() {
        let count = ProcessTable.openFileCount(getpid())
        XCTAssertNotNil(count)
        XCTAssertGreaterThanOrEqual(count ?? 0, 3) // stdin, stdout, stderr
    }

    func testListsOwnProcess() {
        XCTAssertTrue(ProcessTable.all().contains { $0.pid == getpid() })
    }
}

final class AgentStopTests: XCTestCase {
    private func spawn(_ script: String) throws -> BattleNetAgent.Instance {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try p.run()
        addTeardownBlock { kill(p.processIdentifier, SIGKILL) }
        // Wait for the exec to land so the path is stable.
        for _ in 0..<40 where ProcessTable.path(of: p.processIdentifier) != "/bin/sleep" { usleep(25_000) }
        return BattleNetAgent.Instance(pid: p.processIdentifier, path: "/bin/sleep")
    }

    private func stop(_ instance: BattleNetAgent.Instance, grace: TimeInterval) -> BattleNetAgent.StopResult? {
        let done = expectation(description: "stopped")
        var result: BattleNetAgent.StopResult?
        BattleNetAgent.stop(instance, grace: grace, queue: .global()) { result = $0; done.fulfill() }
        wait(for: [done], timeout: grace + 5)
        return result
    }

    func testProcessThatHonoursSigtermExits() throws {
        let proc = try spawn("exec /bin/sleep 30")
        XCTAssertTrue(BattleNetAgent.isRunning(proc))
        XCTAssertEqual(stop(proc, grace: 2), .exited)
        XCTAssertFalse(BattleNetAgent.isRunning(proc))
    }

    func testProcessIgnoringSigtermIsForceQuit() throws {
        // Ignored signals stay ignored across exec, like an Agent that won't quit mid-update.
        let proc = try spawn("trap '' TERM; exec /bin/sleep 30")
        XCTAssertEqual(stop(proc, grace: 1), .forceQuit)
        XCTAssertFalse(BattleNetAgent.isRunning(proc))
    }

    func testPidReuseIsNotTheSameInstance() {
        XCTAssertFalse(BattleNetAgent.isRunning(.init(pid: getpid(), path: "/not/us")))
    }
}
