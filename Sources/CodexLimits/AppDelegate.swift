import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private(set) var monitor = UsageMonitor()

    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var statusIcon: NSImage?
    private var snapshotCancellable: AnyCancellable?
    private var activityErrorCancellable: AnyCancellable?
    private var usageErrorCancellable: AnyCancellable?
    private var preferencesCancellable: AnyCancellable?
    private var providerCancellable: AnyCancellable?
    private var settingsWindow: NSWindow?
    private var globalMouseMonitor: Any?
    private var localReleaseMonitor: Any?
    private var globalReleaseMonitor: Any?
    private var openingPressTimestamp: TimeInterval?
    private var isPopoverOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        LoginItem.enableByDefault()

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }

        button.target = self
        button.action = #selector(handleStatusItemAction)
        button.sendAction(on: [.leftMouseDown])
        button.title = ""
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone

        let image = NSImage(
            systemSymbolName: "gauge.with.dots.needle.50percent",
            accessibilityDescription: "Usage"
        )
        image?.isTemplate = true

        popover.behavior = .applicationDefined
        popover.delegate = self

        self.statusItem = statusItem
        statusIcon = image
        attachMonitor()

        providerCancellable = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .map { _ in UsageProvider.current }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] provider in self?.switchProvider(to: provider) }

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

    private func switchProvider(to provider: UsageProvider) {
        guard provider != monitor.provider else { return }
        monitor.shutdown()
        monitor = UsageMonitor(provider: provider)
        attachMonitor()
    }

    /// Points the popover, settings window and menu bar item at the current monitor.
    private func attachMonitor() {
        popover.contentViewController = NSHostingController(rootView: MenuContentView(
            monitor: monitor,
            openSettingsAction: { [weak self] in self?.showSettings() }
        ))
        (settingsWindow?.contentViewController as? NSHostingController<SettingsView>)?
            .rootView = SettingsView(monitor: monitor)
        settingsWindow?.title = "\(monitor.provider.displayName) Limits Settings"

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

        updateStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        endOpeningPress()
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
        endOpeningPress()
        removeClickAwayMonitor()
    }

    @objc private func handleStatusItemAction() {
        switch NSApp.currentEvent?.type {
        case .leftMouseDown:
            if !isPopoverOpen, let timestamp = NSApp.currentEvent?.timestamp {
                beginOpeningPress(at: timestamp)
            }
            togglePopover()
        case .leftMouseUp:
            // Showing the popover can end the button's tracking with a synthetic
            // mouse-up action while the mouse is still held. Only the event
            // monitors below may finish the opening press.
            break
        default:
            togglePopover()
        }
    }

    private func beginOpeningPress(at timestamp: TimeInterval) {
        endOpeningPress()
        openingPressTimestamp = timestamp
        // Watch releases outside the button too, including in other apps.
        localReleaseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) {
            [weak self] event in
            self?.finishOpeningPress(with: event)
            return event
        }
        globalReleaseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) {
            [weak self] event in
            self?.finishOpeningPress(with: event)
        }
    }

    private func finishOpeningPress(with event: NSEvent) {
        guard let timestamp = openingPressTimestamp else { return }
        endOpeningPress()
        if event.timestamp - timestamp >= 0.5 {
            closePopover()
        }
    }

    private func endOpeningPress() {
        openingPressTimestamp = nil
        if let localReleaseMonitor {
            NSEvent.removeMonitor(localReleaseMonitor)
            self.localReleaseMonitor = nil
        }
        if let globalReleaseMonitor {
            NSEvent.removeMonitor(globalReleaseMonitor)
            self.globalReleaseMonitor = nil
        }
    }

    private func togglePopover() {
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
            window.title = "\(monitor.provider.displayName) Limits Settings"
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
        // The menu bar also routes clicks in the status window's padding to
        // the button, so include its full frame on every side.
        let statusFrame = buttonFrame.union(window.frame)
        // Leave those clicks to togglePopover, including the exact screen edge,
        // so mouse-down cannot close the popover before mouse-up reopens it.
        let topEdge = max(statusFrame.maxY, window.screen?.frame.maxY ?? statusFrame.maxY)
        let location = NSEvent.mouseLocation
        return location.x >= statusFrame.minX && location.x < statusFrame.maxX
            && location.y >= statusFrame.minY && location.y <= topEdge
    }

    private func closePopover() {
        endOpeningPress()
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
        result.accessibilityDescription = "Usage \(title)"
        return result
    }
}
