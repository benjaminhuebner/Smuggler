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
    // such a request must use cold-launch service mode. Consumers flip it to
    // true when the first request arrives (see consumeColdLaunch()).
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
