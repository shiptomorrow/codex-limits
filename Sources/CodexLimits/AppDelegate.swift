import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private(set) var monitor = UsageMonitor()
    /// Every account or service shown so far, kept so switching back doesn't start over.
    private var monitors: [UsageSourceSelection: UsageMonitor] = [:]

    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var statusIcon: NSImage?
    private var snapshotCancellable: AnyCancellable?
    private var activityErrorCancellable: AnyCancellable?
    private var usageErrorCancellable: AnyCancellable?
    private var preferencesCancellable: AnyCancellable?
    private var providerCancellable: AnyCancellable?
    private var accountsCancellable: AnyCancellable?
    /// Readings of the other account shown beside the current one in the menu bar.
    private var companionCancellables: [AnyCancellable] = []
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
        preloadClaudeAccounts()
        attachMonitor()
        updateCompanionMonitors()

        accountsCancellable = ClaudeAccountStore.shared.$options
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.preloadClaudeAccounts()
                self?.updateCompanionMonitors()
            }

        providerCancellable = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .map { _ in UsageSourceSelection.current }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] selection in self?.switchSource(to: selection) }

        let initialPresentation = StatusItemPresentation.current
        preferencesCancellable = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .map { _ in StatusItemPresentation.current }
            .prepend(initialPresentation)
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] presentation in
                self?.updateCompanionMonitors()
                self?.updateStatusItem(presentation: presentation)
            }
    }

    private func switchSource(to selection: UsageSourceSelection) {
        let current = UsageSourceSelection(monitor: monitor)
        guard selection != current else { return }
        // updateCompanionMonitors pauses it unless the menu bar still shows it.
        monitors[current] = monitor
        if let existing = monitors.removeValue(forKey: selection) {
            monitor = existing
            monitor.resume()
        } else {
            monitor = UsageMonitor(provider: selection.provider, claudeAccount: selection.claudeAccount)
        }
        preloadClaudeAccounts()
        attachMonitor()
        updateCompanionMonitors()
    }

    /// The two Claude accounts the menu bar shows side by side, ordered like the popover's
    /// account switch, or nil when it shows only the current account.
    private var menuBarAccounts: [UsageMonitor]? {
        guard monitor.provider == .claude, StatusItemPreferences.showsBothClaudeAccounts else { return nil }
        let options = ClaudeAccountStore.shared.options
        guard options.count == 2 else { return nil }
        let shown = options.compactMap { option in
            option.account == monitor.claudeAccount
                ? monitor
                : monitors[UsageSourceSelection(provider: .claude, claudeAccount: option.account)]
        }
        return shown.count == 2 ? shown : nil
    }

    /// Keeps checking the other account while the menu bar shows it, and pauses every other
    /// monitor that isn't on screen.
    private func updateCompanionMonitors() {
        let shown = menuBarAccounts.map { Set($0.map(ObjectIdentifier.init)) } ?? []
        companionCancellables = []
        for other in monitors.values {
            guard shown.contains(ObjectIdentifier(other)) else {
                other.pause()
                continue
            }
            other.resume()
            companionCancellables.append(
                other.$snapshot
                    .map { _ in () }
                    .merge(with: other.$usageReadFailed.removeDuplicates().map { _ in () })
                    .receive(on: RunLoop.main)
                    .sink { [weak self] in self?.updateStatusItem() }
            )
        }
        updateStatusItem()
    }

    /// Loads the other Claude accounts paused, from their saved readings and without
    /// requests, so the first switch is instant and the menu bar item is sized for them.
    private func preloadClaudeAccounts() {
        guard monitor.provider == .claude else { return }
        for option in ClaudeAccountStore.shared.options where option.account != monitor.claudeAccount {
            let selection = UsageSourceSelection(provider: .claude, claudeAccount: option.account)
            guard monitors[selection] == nil else { continue }
            let preloaded = UsageMonitor(provider: .claude, claudeAccount: option.account)
            preloaded.pause()
            monitors[selection] = preloaded
        }
    }

    /// Points the popover, settings window and menu bar item at the current monitor.
    private func attachMonitor() {
        let content = MenuContentView(
            monitor: monitor,
            openSettingsAction: { [weak self] in self?.showSettings() }
        )
        // Replacing the root view rather than the controller keeps the open popover in place.
        if let controller = popover.contentViewController as? NSHostingController<MenuContentView> {
            controller.rootView = content
        } else {
            popover.contentViewController = NSHostingController(rootView: content)
        }
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
        monitors.values.forEach { $0.shutdown() }
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
        let title: String
        let titleWidth: CGFloat
        if let accounts = menuBarAccounts {
            // Both accounts stay in place whichever one is current.
            title = accounts.map(\.menuBarText).joined(separator: " | ")
            titleWidth = 0
        } else {
            title = monitor.menuBarText
            // Room for every account's percentage, so switching accounts doesn't
            // resize the item and slide the open popover sideways.
            titleWidth = ([monitor] + Array(monitors.values))
                .map { StatusItemImage.titleWidth($0.menuBarText) }
                .max() ?? 0
        }
        button.image = StatusItemImage.make(
            title: title,
            minimumTitleWidth: titleWidth,
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
    static let showsBothClaudeAccountsKey = "menuBarShowsBothClaudeAccounts"

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

    /// Applies only while exactly two Claude accounts are signed in.
    static var showsBothClaudeAccounts: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: showsBothClaudeAccountsKey) != nil else { return true }
        return defaults.bool(forKey: showsBothClaudeAccountsKey)
    }
}

private struct StatusItemPresentation: Equatable {
    let spacing: CGFloat
    let showsIcon: Bool
    let showsUsedPercentage: Bool
    let showsBothClaudeAccounts: Bool

    static var current: Self {
        Self(
            spacing: StatusItemPreferences.spacing,
            showsIcon: StatusItemPreferences.showsIcon,
            showsUsedPercentage: UsagePercentageDisplay.showsUsed,
            showsBothClaudeAccounts: StatusItemPreferences.showsBothClaudeAccounts
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

    static func titleWidth(_ title: String) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: font]).width)
    }

    /// The title is left-aligned in `minimumTitleWidth` when it is narrower.
    static func make(
        title: String,
        minimumTitleWidth: CGFloat = 0,
        spacing: CGFloat,
        icon: NSImage?
    ) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        let titleSize = (title as NSString).size(withAttributes: attributes)
        let iconWidth = icon == nil ? 0 : imageSize.width + spacing
        let size = NSSize(
            width: ceil(iconWidth + max(titleSize.width, minimumTitleWidth)),
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

/// The service and, for Claude, the account the menu bar item tracks.
private struct UsageSourceSelection: Hashable {
    let provider: UsageProvider
    let claudeAccount: ClaudeAccount

    @MainActor static var current: UsageSourceSelection {
        let provider = UsageProvider.current
        return UsageSourceSelection(
            provider: provider,
            claudeAccount: provider == .claude ? .current : .default
        )
    }

    @MainActor init(monitor: UsageMonitor) {
        self.init(provider: monitor.provider, claudeAccount: monitor.claudeAccount)
    }

    init(provider: UsageProvider, claudeAccount: ClaudeAccount) {
        self.provider = provider
        self.claudeAccount = claudeAccount
    }
}
