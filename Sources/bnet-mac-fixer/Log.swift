import Foundation
import BnetFixerCore

func log(_ message: String) {
    let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
    print("\(stamp) \(message)")
}

func describe(_ procs: [BattleNetProcesses.Process]) -> String {
    procs.isEmpty ? "no Battle.net processes" : procs.map { "\($0.pid)(\($0.role))" }.joined(separator: " ")
}

func describe(_ result: BattleNetAgent.StopResult) -> String {
    switch result {
    case .exited: return "exited; Battle.net relaunches it on demand"
    case .forceQuit: return "ignored SIGTERM, force-quit it; Battle.net relaunches it on demand"
    case .stillRunning: return "is still running after SIGKILL"
    case .signalFailed: return "couldn't be signalled"
    }
}
