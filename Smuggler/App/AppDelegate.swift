import AppKit
import os

private let logger = Logger(subsystem: "com.benjaminhuebner.Smuggler", category: "App")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appModel = AppModel()

    // No update UI in service mode: the session quits within ~1s and the
    // menu command is unreachable there. Lazy so tests can instantiate
    // the delegate without starting Sparkle.
    lazy var updater = UpdaterController()

    // False while the app is still handling the request that launched it —
    // such a request must use cold-launch service mode (see consumeColdLaunch()).
    var isReady = false

    // Non-default launches include reasons that never deliver a request (own
    // result notifications, state restoration); an unconsumed cold launch must
    // expire or a much later request would misclassify and self-terminate.
    var coldLaunchGracePeriod: Duration = .seconds(5)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        _ = updater

        completeLaunch(
            isDefaultLaunch: (notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool) ?? true)
    }

    // AppKit sets launchIsDefault to false when the app was launched to
    // handle a URL or Services request. Never write false here: the
    // launching request may already have been consumed before this runs.
    func completeLaunch(isDefaultLaunch: Bool) {
        if isDefaultLaunch {
            isReady = true
        } else {
            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: coldLaunchGracePeriod)
                isReady = true
            }
        }
    }

    // Marks the launch sequence complete even when it returns false — every
    // request after the first must see an already-running app.
    func consumeColdLaunch() -> Bool {
        let wasCold = !isReady
        isReady = true
        return wasCold
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // Logout, restart and shutdown ask through an Apple event; a modal here would
    // stall that and macOS would report Smuggler as the app that cancelled it.
    // A menu quit or a closing window carries no event.
    private static var isSystemInitiatedQuit: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventClass == kCoreEventClass && event.eventID == kAEQuitApplication
    }

    // A headless service session ends itself on purpose; only a person quitting
    // mid-run is doing it without knowing what they abandon.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard appModel.serviceMode == nil, appModel.isProcessing, !Self.isSystemInitiatedQuit else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Quit while items are still being freed?",
            comment: "Alert title: quitting with work in flight")
        alert.informativeText = String(
            localized: "Items still in progress will be left as they are.",
            comment: "Alert body: quitting with work in flight")
        alert.addButton(withTitle: String(localized: "Quit", comment: "Alert button: quit anyway"))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Alert button: cancel"))
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\u{1b}"

        guard alert.runModal() == .alertFirstButtonReturn else {
            // This path is also how closing the last window asks to quit. Staying
            // alive without bringing the window back would leave the work the user
            // just chose to keep running out of sight.
            if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            return .terminateCancel
        }
        return .terminateNow
    }

    // MARK: - NSServices handler

    @objc func removeQuarantine(
        _ pboard: NSPasteboard,
        userData: String,
        error errorPointer: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let urls = pboard.readObjects(forClasses: [NSURL.self]) as? [URL],
            !urls.isEmpty
        else {
            logger.warning("Services handler: no file paths on pasteboard")
            return
        }
        logger.info("Services handler: processing \(urls.count) item(s)")

        let coldLaunch = consumeColdLaunch()
        if !coldLaunch {
            NSApp.activate(ignoringOtherApps: true)
        }
        appModel.handleServiceURLs(urls, action: .remove, quitAfter: coldLaunch)
    }
}
