import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let monitor = UsageMonitor()

    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var statusContentView: StatusItemContentView?
    private var snapshotCancellable: AnyCancellable?
    private var activityErrorCancellable: AnyCancellable?
    private var usageErrorCancellable: AnyCancellable?
    private var preferencesCancellable: AnyCancellable?
    private var settingsWindow: NSWindow?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        LoginItem.enableByDefault()

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let image = NSImage(
            systemSymbolName: "gauge.with.dots.needle.50percent",
            accessibilityDescription: "Codex usage"
        )
        image?.isTemplate = true

        let statusContentView = StatusItemContentView(image: image, statusItem: statusItem)
        statusContentView.target = self
        statusContentView.action = #selector(togglePopover)
        statusItem.view = statusContentView

        let content = MenuContentView(
            monitor: monitor,
            openSettingsAction: { [weak self] in self?.showSettings() }
        )
        popover.behavior = .applicationDefined
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: content)

        self.statusItem = statusItem
        self.statusContentView = statusContentView
        updateStatusItem()

        snapshotCancellable = monitor.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }

        activityErrorCancellable = monitor.$activityErrorMessage
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }

        usageErrorCancellable = monitor.$usageReadFailed
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }

        let initialPresentation = StatusItemPresentation.current
        preferencesCancellable = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .map { _ in StatusItemPresentation.current }
            .prepend(initialPresentation)
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] presentation in
                self?.updateStatusItem(presentation: presentation)
            }
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeClickAwayMonitors()
        monitor.shutdown()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    func popoverDidShow(_ notification: Notification) {
        statusContentView?.isHighlighted = true
        installClickAwayMonitors()
    }

    func popoverDidClose(_ notification: Notification) {
        statusContentView?.isHighlighted = false
        removeClickAwayMonitors()
    }

    @objc private func togglePopover() {
        guard let statusContentView else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(
                relativeTo: statusContentView.bounds,
                of: statusContentView,
                preferredEdge: .minY
            )
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateStatusItem(
        presentation: StatusItemPresentation = .current
    ) {
        guard let statusItem, let statusContentView else { return }
        let width = statusContentView.update(
            title: monitor.menuBarText,
            spacing: presentation.spacing,
            showsIcon: presentation.showsIcon
        )
        statusItem.length = width
    }

    private func showSettings() {
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView(monitor: monitor))
            let window = NSWindow(contentViewController: controller)
            window.title = "Codex Limits Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 380, height: 600))
            window.center()
            settingsWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func installClickAwayMonitors() {
        guard localMouseMonitor == nil, globalMouseMonitor == nil else { return }

        let mouseEvents: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown
        ]

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) {
            [weak self] event in
            guard let self else { return event }
            if !self.isProtectedClick(event) {
                self.popover.performClose(nil)
            }
            return event
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) {
            [weak self] _ in
            self?.popover.performClose(nil)
        }
    }

    private func removeClickAwayMonitors() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    private func isProtectedClick(_ event: NSEvent) -> Bool {
        guard let eventWindow = event.window else { return false }

        if eventWindow === popover.contentViewController?.view.window {
            return true
        }

        var candidateWindow: NSWindow? = eventWindow
        while let window = candidateWindow {
            if window === settingsWindow {
                return true
            }
            candidateWindow = window.sheetParent ?? window.parent
        }

        guard let statusContentView, eventWindow === statusContentView.window else {
            return false
        }
        let pointInStatusItem = statusContentView.convert(event.locationInWindow, from: nil)
        return statusContentView.bounds.contains(pointInStatusItem)
    }
}

enum StatusItemPreferences {
    static let spacingKey = "menuBarIconTextSpacing"
    static let showsIconKey = "menuBarShowsIcon"

    static var spacing: CGFloat {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: spacingKey) != nil else { return 4 }
        return CGFloat(min(max(defaults.double(forKey: spacingKey), 0), 12))
    }

    static var showsIcon: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: showsIconKey) != nil else { return true }
        return defaults.bool(forKey: showsIconKey)
    }
}

private struct StatusItemPresentation: Equatable {
    let spacing: CGFloat
    let showsIcon: Bool
    let showsUsedPercentage: Bool

    static var current: Self {
        Self(
            spacing: StatusItemPreferences.spacing,
            showsIcon: StatusItemPreferences.showsIcon,
            showsUsedPercentage: UsagePercentageDisplay.showsUsed
        )
    }
}

@MainActor
private final class StatusItemContentView: NSControl {
    private let imageView: NSImageView
    private let titleField = NSTextField(labelWithString: "")
    private let stackView = NSStackView()
    private weak var statusItem: NSStatusItem?

    override var isHighlighted: Bool {
        get { super.isHighlighted }
        set {
            if super.isHighlighted != newValue {
                super.isHighlighted = newValue
                let foregroundColor: NSColor = newValue ? .selectedMenuItemTextColor : .labelColor
                imageView.contentTintColor = foregroundColor
                titleField.textColor = foregroundColor
                needsDisplay = true
            }
        }
    }

    init(image: NSImage?, statusItem: NSStatusItem) {
        imageView = NSImageView(image: image ?? NSImage())
        self.statusItem = statusItem
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: 0,
            height: NSStatusBar.system.thickness
        ))

        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 14),
            imageView.heightAnchor.constraint(equalToConstant: 14)
        ])

        titleField.font = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.systemFontSize,
            weight: .regular
        )
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byClipping
        titleField.setContentCompressionResistancePriority(.required, for: .horizontal)

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = StatusItemPreferences.spacing
        stackView.edgeInsets = NSEdgeInsets()
        stackView.addArrangedSubview(imageView)
        stackView.addArrangedSubview(titleField)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -0.5)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(title: String, spacing: CGFloat, showsIcon: Bool) -> CGFloat {
        if titleField.stringValue != title {
            titleField.stringValue = title
        }
        if stackView.spacing != spacing {
            stackView.spacing = spacing
        }
        if imageView.isHidden == showsIcon {
            imageView.isHidden = !showsIcon
        }

        layoutSubtreeIfNeeded()
        let width = ceil(stackView.fittingSize.width)
        if frame.width != width {
            frame.size.width = width
        }
        return width
    }

    override func draw(_ dirtyRect: NSRect) {
        statusItem?.drawStatusBarBackground(in: bounds, withHighlight: isHighlighted)
    }

    override func mouseDown(with event: NSEvent) {
        isHighlighted = true
    }

    override func mouseUp(with event: NSEvent) {
        sendAction(action, to: target)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }
}
