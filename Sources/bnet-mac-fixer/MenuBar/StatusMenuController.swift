import AppKit
import BnetFixerCore

/// The menu bar icon: a client of the daemon's control socket. It holds no state of its own, so
/// quitting it (or it crashing) never affects the fixes.
final class StatusMenuController: NSObject, NSMenuDelegate {
    private static let refreshInterval: TimeInterval = 15
    /// While the overlay is up (or just after a wake) the menu bar follows the daemon closely.
    private static let fastInterval: TimeInterval = 0.25
    private static let fastFetchEvery = 4 // ticks, i.e. once a second
    private static let projectURL = URL(string: "https://github.com/zolat/bnet-mac-fixer")!

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var snapshot: FixerSnapshot?
    private var timer: Timer?
    private var fastTimer: Timer?
    private var fastTicks = 0
    private var fastUntil = Date.distantPast
    private var fetching = false
    private let overlay = ReconnectOverlay()

    private lazy var builder = MenuBuilder(actions: .init(
        target: self,
        restartAgent: #selector(restartAgent),
        resumeBattleNet: #selector(resumeBattleNet),
        restartBattleNet: #selector(restartBattleNet),
        startFixer: #selector(startFixer),
        openLog: #selector(openLog),
        openProject: #selector(openProject),
        quit: #selector(quit)
    ))

    func start() {
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        apply(Self.fetch(timeout: 1))
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [unowned self] _ in refresh() }
        timer?.tolerance = 5

        overlay.onRestart = { [unowned self] in send(.restartBattleNet) }
        // The daemon resumes Battle.net as the Mac wakes; poll quickly so the overlay is up at once.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [unowned self] _ in
                fastUntil = Date().addingTimeInterval(30)
            }
        }
        fastTimer = Timer.scheduledTimer(withTimeInterval: Self.fastInterval, repeats: true) { [unowned self] _ in fastTick() }
        RunLoop.main.add(fastTimer!, forMode: .common)
    }

    private func fastTick() {
        let now = Date()
        guard overlay.isActive || fastUntil.timeIntervalSince(now) > 0 else { return }
        fastTicks += 1
        if fastTicks % Self.fastFetchEvery == 0 { refresh() }
        overlay.update(snapshot?.reconnect, now: now) // keeps the clock ticking and the panel on the window
    }

    // Rebuilt on every open from a fresh snapshot, so what you see is never stale.
    func menuNeedsUpdate(_ menu: NSMenu) {
        apply(Self.fetch(timeout: 0.5))
        let fresh = builder.build(snapshot)
        menu.removeAllItems()
        fresh.items.forEach { fresh.removeItem($0); menu.addItem($0) }
    }

    private func refresh() {
        guard !fetching else { return }
        fetching = true
        DispatchQueue.global().async {
            let snapshot = Self.fetch(timeout: 2)
            DispatchQueue.main.async { self.fetching = false; self.apply(snapshot) }
        }
    }

    private func apply(_ snapshot: FixerSnapshot?) {
        self.snapshot = snapshot
        let summary = StatusSummary(snapshot)
        let image = NSImage(systemSymbolName: MenuBuilder.symbolName(for: summary.health), accessibilityDescription: "bnet-mac-fixer")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = snapshot == nil ? summary.battleNet : "\(summary.battleNet)\n\(summary.agent)"
        overlay.update(snapshot?.reconnect, now: Date())
    }

    static func fetch(timeout: TimeInterval) -> FixerSnapshot? {
        try? ControlClient.send(.init(.status), timeout: timeout).snapshot
    }

    private func send(_ command: ControlRequest.Command) {
        DispatchQueue.global().async {
            let response = try? ControlClient.send(.init(command), timeout: 3)
            DispatchQueue.main.async {
                self.apply(response?.snapshot ?? self.snapshot)
                if let response, !response.ok, let message = response.message { self.alert(message) }
            }
        }
    }

    @objc private func restartAgent() {
        if let games = snapshot?.games, !games.isEmpty {
            let ok = confirm(
                "Restart the Battle.net Agent while \(Format.list(games)) is running?",
                "The fixer normally waits until you quit. Restarting it now is usually fine, but the game may lose its connection to Battle.net.",
                "Restart Agent"
            )
            guard ok else { return }
        }
        send(.restartAgent)
    }

    @objc private func resumeBattleNet() { send(.resumeBattleNet) }
    @objc private func restartBattleNet() { send(.restartBattleNet) }

    @objc private func startFixer() {
        let domain = "gui/\(getuid())"
        let plist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/local.bnet-mac-fixer.plist").path
        DispatchQueue.global().async {
            Self.launchctl(["bootstrap", domain, plist]) // no-op error if already loaded
            Self.launchctl(["kickstart", "\(domain)/local.bnet-mac-fixer"])
            Thread.sleep(forTimeInterval: 1)
            DispatchQueue.main.async { self.refresh() }
        }
    }

    @objc private func openLog() { NSWorkspace.shared.open(FixerPaths.log) }
    @objc private func openProject() { NSWorkspace.shared.open(Self.projectURL) }
    @objc private func quit() { NSApp.terminate(nil) }

    private static func launchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    private func confirm(_ title: String, _ detail: String, _ button: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func alert(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }
}
