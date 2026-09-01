import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let monitor = UsageMonitor()

    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var statusIcon: NSImage?
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
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone

        let image = NSImage(
            systemSymbolName: "gauge.with.dots.needle.50percent",
            accessibilityDescription: "Codex usage"
        )
        image?.isTemplate = true

        let content = MenuContentView(
            monitor: monitor,
            openSettingsAction: { [weak self] in self?.showSettings() }
        )
        popover.behavior = .applicationDefined
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: content)

        self.statusItem = statusItem
        statusIcon = image
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
        guard let button = statusItem?.button else { return }
        button.image = StatusItemImage.make(
            title: monitor.menuBarText,
            spacing: presentation.spacing,
            icon: presentation.showsIcon ? statusIcon : nil
        )
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
private enum StatusItemImage {
    private static let imageSize = NSSize(width: 14, height: 14)
    private static let font = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.systemFontSize,
        weight: .regular
    )

    static func make(title: String, spacing: CGFloat, icon: NSImage?) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        let titleSize = (title as NSString).size(withAttributes: attributes)
        let iconWidth = icon == nil ? 0 : imageSize.width + spacing
        let size = NSSize(
            width: ceil(iconWidth + titleSize.width),
            height: ceil(max(imageSize.height, titleSize.height))
        )
        let result = NSImage(size: size, flipped: false) { _ in
            var x: CGFloat = 0
            if let icon {
                icon.draw(
                    in: NSRect(
                        x: x,
                        y: floor((size.height - imageSize.height) / 2),
                        width: imageSize.width,
                        height: imageSize.height
                    ),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1
                )
                x += imageSize.width + spacing
            }
            (title as NSString).draw(
                at: NSPoint(x: x, y: floor((size.height - titleSize.height) / 2)),
                withAttributes: attributes
            )
            return true
        }
        result.isTemplate = true
        result.accessibilityDescription = "Codex usage \(title)"
        return result
    }
}
