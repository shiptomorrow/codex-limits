import AppKit

@main
@MainActor
enum CodexLimitsApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        // Settings are opened explicitly by the menu bar action.
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
