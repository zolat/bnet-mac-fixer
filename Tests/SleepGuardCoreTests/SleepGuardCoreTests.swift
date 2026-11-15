import XCTest
@testable import SleepGuardCore

final class WakeStateTests: XCTestCase {
    func testFullWakeLidOpenIsUserAwake() {
        XCTAssertTrue(WakeState(capabilities: 0xF, clamshellClosed: false, clamshellCausesSleep: true).isUserAwake)
    }

    func testDarkWakeIsNotUserAwake() {
        // DarkWake = CPU + Network, no Graphics.
        XCTAssertFalse(WakeState(capabilities: 0x9, clamshellClosed: true, clamshellCausesSleep: true).isUserAwake)
        XCTAssertFalse(WakeState(capabilities: 0x9, clamshellClosed: false, clamshellCausesSleep: false).isUserAwake)
    }

    func testLidClosedNotificationWakeIsNotUserAwake() {
        // e.g. "DarkWake to FullWake ... due to Notification" with the lid shut, then Clamshell Sleep 10s later.
        XCTAssertFalse(WakeState(capabilities: 0xF, clamshellClosed: true, clamshellCausesSleep: true).isUserAwake)
    }

    func testClamshellModeWithExternalDisplayIsUserAwake() {
        XCTAssertTrue(WakeState(capabilities: 0xF, clamshellClosed: true, clamshellCausesSleep: false).isUserAwake)
    }

    func testCurrentStateIsReadable() {
        XCTAssertNotNil(WakeState.current())
    }
}

final class ResumePolicyTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let lidOpen = WakeState(capabilities: 0xF, clamshellClosed: false, clamshellCausesSleep: true)
    let dark = WakeState(capabilities: 0x9, clamshellClosed: true, clamshellCausesSleep: true)
    // As observed at 12:30:55: full wake via HID with lid shut, lidCausesSleep momentarily false.
    let lidClosedAwake = WakeState(capabilities: 0xF, clamshellClosed: true, clamshellCausesSleep: false)

    func testLidOpenResumesImmediately() {
        var p = ResumePolicy()
        XCTAssertEqual(p.evaluate(lidOpen, now: t0), .resume)
    }

    func testDarkWakeStaysPaused() {
        var p = ResumePolicy()
        XCTAssertEqual(p.evaluate(dark, now: t0), .stayPaused)
        XCTAssertEqual(p.evaluate(nil, now: t0), .stayPaused)
    }

    func testLidClosedBumpWakeDoesNotResumeBeforeSettle() {
        var p = ResumePolicy(lidClosedSettle: 90)
        XCTAssertEqual(p.evaluate(lidClosedAwake, now: t0), .settling(until: t0 + 90))
        XCTAssertEqual(p.evaluate(lidClosedAwake, now: t0 + 66), .settling(until: t0 + 90))
    }

    func testLidClosedAwakeResumesAfterSettle() {
        var p = ResumePolicy(lidClosedSettle: 90)
        _ = p.evaluate(lidClosedAwake, now: t0)
        XCTAssertEqual(p.evaluate(lidClosedAwake, now: t0 + 90), .resume)
    }

    func testSettleWindowRestartsAfterDarkWakeOrSleep() {
        var p = ResumePolicy(lidClosedSettle: 90)
        _ = p.evaluate(lidClosedAwake, now: t0)
        _ = p.evaluate(dark, now: t0 + 50)
        XCTAssertEqual(p.evaluate(lidClosedAwake, now: t0 + 100), .settling(until: t0 + 190))
        p.reset()
        XCTAssertEqual(p.evaluate(lidClosedAwake, now: t0 + 200), .settling(until: t0 + 290))
    }

    func testOpeningLidDuringSettleResumesImmediately() {
        var p = ResumePolicy(lidClosedSettle: 90)
        _ = p.evaluate(lidClosedAwake, now: t0)
        XCTAssertEqual(p.evaluate(lidOpen, now: t0 + 5), .resume)
    }
}

final class BattleNetProcessTests: XCTestCase {
    func testMainApp() {
        XCTAssertEqual(BattleNetProcesses.role(forExecutablePath: "/Applications/Battle.net.app/Contents/MacOS/Battle.net"), .main)
    }

    func testHelper() {
        let path = "/Users/x/Library/Application Support/Battle.net/Versions/Battle.net.17986/battle.net-core.framework/Frameworks/Battle.net Helper.app/Contents/MacOS/Battle.net Helper"
        XCTAssertEqual(BattleNetProcesses.role(forExecutablePath: path), .helper)
    }

    func testAgentAndGamesAreIgnored() {
        XCTAssertNil(BattleNetProcesses.role(forExecutablePath: "/Users/Shared/Battle.net/Agent/Agent.9873/Agent.app/Contents/MacOS/Agent"))
        XCTAssertNil(BattleNetProcesses.role(forExecutablePath: "/Applications/World of Warcraft/_forever_/World of Warcraft.app/Contents/MacOS/World of Warcraft"))
        XCTAssertNil(BattleNetProcesses.role(forExecutablePath: "/Applications/Battle.net.app/Contents/MacOS/Battle.net Updater"))
    }
}
