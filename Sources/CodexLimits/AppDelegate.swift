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
    private var globalMouseMonitor: Any?
    private var isPopoverOpen = false

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
        removeClickAwayMonitor()
        monitor.shutdown()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    func popoverDidShow(_ notification: Notification) {
        installClickAwayMonitor()
    }

    func popoverDidClose(_ notification: Notification) {
        isPopoverOpen = false
        removeClickAwayMonitor()
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if isPopoverOpen {
            closePopover()
        } else {
            isPopoverOpen = true
            popover.show(
                relativeTo: button.bounds,
                of: button,
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

    private func installClickAwayMonitor() {
        guard globalMouseMonitor == nil else { return }

        let mouseEvents: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown
        ]

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) {
            [weak self] _ in
            guard let self, !self.isStatusItemClick else { return }
            self.closePopover()
        }
    }

    private var isStatusItemClick: Bool {
        guard let button = statusItem?.button, let window = button.window else { return false }
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        return buttonFrame.contains(NSEvent.mouseLocation)
    }

    private func closePopover() {
        isPopoverOpen = false
        popover.close()
    }

    private func removeClickAwayMonitor() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
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
private final class StatusItemContentView: NSView {
    private let imageView: NSImageView
    private let titleField = NSTextField(labelWithString: "")
    private let stackView = NSStackView()

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
        invalidateIntrinsicContentSize()
        return width
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
