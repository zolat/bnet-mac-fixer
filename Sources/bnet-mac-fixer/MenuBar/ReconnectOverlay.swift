import AppKit
import BnetFixerCore

/// A slim status bar along the top of the Battle.net window while it reconnects after a wake:
/// says when it's safe to press Play and offers a restart when it's stuck. Only the bar itself
/// takes clicks, so Battle.net stays usable and the bar is easy to ignore. It sits directly above
/// Battle.net's window, never above other apps, and hides when that window isn't on screen.
final class ReconnectOverlay {
    static let barHeight: CGFloat = 40
    /// Clears Battle.net's own title/nav strip so its window controls stay reachable.
    static let topInset: CGFloat = 52

    var onRestart: () -> Void = {}
    private let panel = OverlayPanel()
    private let bar = StatusBarView()
    private var content: OverlayContent?
    private var episode: Date?
    private var dismissedEpisode: Date?
    private var mainPid: pid_t?
    private var lastWindowFrame: NSRect?

    /// While true the caller should keep calling `update` a few times a second.
    var isActive: Bool { content != nil }
    var windowNumber: Int { panel.windowNumber }
    private(set) var coveredWindow: CGWindowID?

    init() {
        panel.contentView = bar
        bar.onRestart = { [unowned self] in onRestart() }
        bar.onDismiss = { [unowned self] in
            dismissedEpisode = episode
            update(nil, now: Date())
        }
    }

    func update(_ state: ReconnectTracker.State?, now: Date) {
        episode = state?.since
        if let state, state.since != dismissedEpisode, let content = OverlayContent(state, now: now) {
            if content != self.content { bar.show(content) }
            self.content = content
            position()
        } else {
            content = nil
            hide()
        }
    }

    private func position() {
        var window = mainPid.flatMap(BattleNetWindow.find)
        if window == nil {
            mainPid = BattleNetProcesses.running().first { $0.role == .main }?.pid
            window = mainPid.flatMap(BattleNetWindow.find)
        }
        if let window, window.isOnScreen {
            lastWindowFrame = window.frame
            place(over: window.frame)
            panel.order(.above, relativeTo: Int(window.id))
            coveredWindow = window.id
            show()
        } else if window == nil, let lastWindowFrame, content?.style == .busy || content?.style == .success {
            // Mid-restart there's no window yet; stay where it was so the progress stays visible.
            place(over: lastWindowFrame)
            panel.orderFrontRegardless()
            coveredWindow = nil
            show()
        } else {
            // Minimised, or on another Space (e.g. behind a fullscreen game): don't float over anything else.
            coveredWindow = nil
            hide()
        }
    }

    private func place(over window: NSRect) {
        let frame = NSRect(x: window.minX, y: window.maxY - Self.topInset - Self.barHeight, width: window.width, height: Self.barHeight)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private func show() {
        guard panel.alphaValue < 1 else { return }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
    }

    private func hide() {
        guard panel.isVisible else { return }
        panel.alphaValue = 0
        panel.orderOut(nil)
    }
}

/// Borderless and never takes focus.
private final class OverlayPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .normal
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        alphaValue = 0
        collectionBehavior = [.ignoresCycle, .fullScreenNone]
        appearance = NSAppearance(named: .darkAqua) // Battle.net's UI is dark
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class StatusBarView: NSVisualEffectView {
    var onRestart: () -> Void = {}
    var onDismiss: () -> Void = {}

    private let spinner = NSProgressIndicator()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let timer = NSTextField(labelWithString: "")
    private let restart = PillButton(title: "Restart Battle.net")
    private let dismiss = PillButton(symbol: "xmark", label: "Dismiss")
    private let accent = NSView()

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active

        accent.wantsLayer = true // thin colour strip on the left: state at a glance
        spinner.style = .spinning
        spinner.controlSize = .small
        icon.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        timer.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        timer.textColor = .secondaryLabelColor
        restart.target = self
        restart.action = #selector(restartClicked)
        dismiss.target = self
        dismiss.action = #selector(dismissClicked)

        let leading = NSStackView(views: [spinner, icon, title, detail])
        leading.spacing = 8
        let trailing = NSStackView(views: [timer, restart, dismiss])
        trailing.spacing = 10
        for v in [accent, leading, trailing] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            accent.leadingAnchor.constraint(equalTo: leadingAnchor),
            accent.topAnchor.constraint(equalTo: topAnchor),
            accent.bottomAnchor.constraint(equalTo: bottomAnchor),
            accent.widthAnchor.constraint(equalToConstant: 3),
            leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            leading.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            leading.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ c: OverlayContent) {
        title.stringValue = c.title
        detail.stringValue = c.detail
        timer.stringValue = c.timer ?? ""
        timer.isHidden = c.timer == nil

        let busy = c.style == .waiting || c.style == .busy
        spinner.isHidden = !busy
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        icon.isHidden = busy
        let color: NSColor
        switch c.style {
        case .waiting, .busy: color = .systemBlue
        case .success: color = .systemGreen; setIcon("checkmark.circle.fill", color)
        case .suggestRestart: color = .systemOrange; setIcon("wifi.exclamationmark", color)
        case .warning: color = .systemYellow; setIcon("exclamationmark.triangle.fill", color)
        }
        accent.layer?.backgroundColor = color.cgColor

        restart.isHidden = !c.showsRestart
        restart.isPrimary = c.restartIsPrimary
        dismiss.isHidden = c.style == .success
    }

    private func setIcon(_ name: String, _ color: NSColor) {
        icon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        icon.contentTintColor = color
    }

    @objc private func restartClicked() { onRestart() }
    @objc private func dismissClicked() { onDismiss() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Drawn by hand: system bezels render grey in a panel that never becomes key, which hides
/// which action is the recommended one.
private final class PillButton: NSButton {
    var isPrimary = false { didSet { restyle() } }
    private var label: String

    init(title: String) {
        label = title
        super.init(frame: .zero)
        setUp()
    }

    init(symbol: String, label: String) {
        self.label = ""
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        symbolConfiguration = .init(pointSize: 11, weight: .bold)
        contentTintColor = .secondaryLabelColor
        toolTip = label
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
        restyle()
    }

    override var intrinsicContentSize: NSSize {
        label.isEmpty ? NSSize(width: 24, height: 24) : NSSize(width: super.intrinsicContentSize.width + 24, height: 26)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func restyle() {
        guard !label.isEmpty else { return }
        layer?.backgroundColor = (isPrimary ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.14)).cgColor
        attributedTitle = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: isPrimary ? .semibold : .medium),
            .foregroundColor: NSColor.white,
        ])
    }
}
