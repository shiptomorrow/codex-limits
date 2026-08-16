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
        guard let button = statusItem.button else { return }

        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp])
        button.title = ""
        button.image = nil

        let image = NSImage(
            systemSymbolName: "gauge.with.dots.needle.50percent",
            accessibilityDescription: "Codex usage"
        )
        image?.isTemplate = true

        let statusContentView = StatusItemContentView(image: image)
        statusContentView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(statusContentView)
        NSLayoutConstraint.activate([
            statusContentView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            statusContentView.centerYAnchor.constraint(equalTo: button.centerYAnchor, constant: -0.5)
        ])

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
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }

        usageErrorCancellable = monitor.$usageReadFailed
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }

        preferencesCancellable = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeClickAwayMonitors()
        monitor.shutdown()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    func popoverDidShow(_ notification: Notification) {
        installClickAwayMonitors()
    }

    func popoverDidClose(_ notification: Notification) {
        removeClickAwayMonitors()
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateStatusItem() {
        guard let statusItem, let statusContentView else { return }

        statusContentView.title = monitor.menuBarText
        statusContentView.spacing = StatusItemPreferences.spacing
        statusContentView.showsIcon = StatusItemPreferences.showsIcon
        statusContentView.layoutSubtreeIfNeeded()
        statusItem.length = ceil(statusContentView.fittingSize.width)
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

        guard let button = statusItem?.button, eventWindow === button.window else {
            return false
        }
        let pointInButton = button.convert(event.locationInWindow, from: nil)
        return button.bounds.contains(pointInButton)
    }
}

@MainActor
private final class StatusItemContentView: NSView {
    private let imageView: NSImageView
    private let titleField = NSTextField(labelWithString: "")
    private let stackView = NSStackView()

    var title: String {
        get { titleField.stringValue }
        set {
            titleField.stringValue = newValue
            invalidateIntrinsicContentSize()
        }
    }

    var spacing: CGFloat {
        get { stackView.spacing }
        set {
            stackView.spacing = newValue
            invalidateIntrinsicContentSize()
        }
    }

    var showsIcon: Bool {
        get { !imageView.isHidden }
        set {
            imageView.isHidden = !newValue
            invalidateIntrinsicContentSize()
        }
    }

    init(image: NSImage?) {
        imageView = NSImageView(image: image ?? NSImage())
        super.init(frame: .zero)

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
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        stackView.fittingSize
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
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
