import AppKit
import BnetFixerCore

/// Builds the status menu from a snapshot. Actions are sent to `target`.
struct MenuBuilder {
    struct Actions {
        let target: AnyObject
        let restartAgent: Selector
        let resumeBattleNet: Selector
        let startFixer: Selector
        let openLog: Selector
        let openProject: Selector
        let quit: Selector
    }

    let actions: Actions

    static func symbolName(for health: StatusSummary.Health) -> String {
        switch health {
        case .ok: return "checkmark.shield"
        case .paused: return "pause.circle"
        case .attention: return "exclamationmark.shield"
        case .offline: return "shield.slash"
        }
    }

    func build(_ snapshot: FixerSnapshot?, now: Date = Date()) -> NSMenu {
        let summary = StatusSummary(snapshot, now: now)
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(header("bnet-mac-fixer"))
        guard let snapshot else {
            menu.addItem(info(summary.battleNet))
            menu.addItem(action("Start bnet-mac-fixer", actions.startFixer))
            menu.addItem(.separator())
            menu.addItem(action("Open Log", actions.openLog))
            menu.addItem(action("Quit Menu Bar Icon", actions.quit, key: "q"))
            return menu
        }

        menu.addItem(info(summary.battleNet))
        menu.addItem(info(summary.agent))
        if let games = summary.games { menu.addItem(info(games)) }

        menu.addItem(.separator())
        menu.addItem(header("Since \(Self.day.string(from: snapshot.activity.since))"))
        summary.totals.forEach { menu.addItem(info($0)) }
        menu.addItem(recentActivity(snapshot.activity.events))

        menu.addItem(.separator())
        let restartTitle = snapshot.games.isEmpty
            ? "Restart Battle.net Agent"
            : "Restart Battle.net Agent… (\(Format.list(snapshot.games)) running)"
        let restart = action(restartTitle, actions.restartAgent)
        restart.isEnabled = summary.canRestartAgent
        menu.addItem(restart)
        if summary.canResumeBattleNet { menu.addItem(action("Resume Battle.net Now", actions.resumeBattleNet)) }
        menu.addItem(action("Open Log", actions.openLog))
        menu.addItem(action("About bnet-mac-fixer", actions.openProject))

        menu.addItem(.separator())
        menu.addItem(info("Fixer running since \(Self.time.string(from: snapshot.startedAt)) (pid \(snapshot.pid))"))
        menu.addItem(action("Quit Menu Bar Icon", actions.quit, key: "q"))
        return menu
    }

    private func recentActivity(_ events: [ActivityLog.Event]) -> NSMenuItem {
        let item = NSMenuItem(title: "Recent Activity", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let recent = events.suffix(20).reversed()
        if recent.isEmpty { sub.addItem(info("Nothing yet")) }
        for event in recent {
            sub.addItem(info("\(Self.time.string(from: event.date))   \(event.text)"))
        }
        item.submenu = sub
        return item
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.menuFont(ofSize: 0).withWeight(.semibold),
        ])
        item.isEnabled = false
        return item
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = actions.target
        return item
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f
    }()

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()
}

private extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}

/// Plain-text rendering of a menu, for `menubar --dump`.
func dump(_ menu: NSMenu, indent: String = "") -> String {
    menu.items.map { item in
        if item.isSeparatorItem { return indent + "────" }
        let marker = item.action != nil ? (item.isEnabled ? "▶ " : "▷ ") : "  "
        var line = indent + marker + item.title
        if let sub = item.submenu { line += " ›\n" + dump(sub, indent: indent + "      ") }
        return line
    }.joined(separator: "\n")
}
