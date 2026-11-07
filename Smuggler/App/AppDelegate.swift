import AppKit
import os

private let logger = Logger(subsystem: "com.benjaminhuebner.Smuggler", category: "App")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appModel: AppModel
    private let confirmQuit: @MainActor () -> Bool
    private let asksNotificationPermissionAtLaunch: Bool

    // Expiry also needs a window the person can see: a Services request waits behind
    // macOS's own confirmation for as long as the answer takes, with no window up.
    private let hasVisibleMainWindow: @MainActor () -> Bool

    // Non-default launches include reasons that never deliver a request (own
    // result notifications, state restoration); an unconsumed cold launch must
    // expire or a much later request would misclassify and self-terminate.
    private let coldLaunchGracePeriod: Duration

    init(
        appModel: AppModel,
        confirmQuit: @escaping @MainActor () -> Bool,
        asksNotificationPermissionAtLaunch: Bool,
        hasVisibleMainWindow: @escaping @MainActor () -> Bool,
        coldLaunchGracePeriod: Duration = .seconds(5)
    ) {
        self.appModel = appModel
        self.confirmQuit = confirmQuit
        self.asksNotificationPermissionAtLaunch = asksNotificationPermissionAtLaunch
        self.hasVisibleMainWindow = hasVisibleMainWindow
        self.coldLaunchGracePeriod = coldLaunchGracePeriod
        super.init()
    }

    // The initializer NSApplicationDelegateAdaptor calls, and the one place live
    // effects are wired: a delegate built any other way cannot reach a modal or Sparkle.
    override convenience init() {
        let updater = UpdaterController()
        self.init(
            appModel: AppModel(
                // Sparkle's prompt and update alerts are windows a quitting session would close
                // unanswered, so the updater starts only once a session stays. Starting twice is harmless.
                handlers: .live(sessionStays: { updater.start() }),
                tokenStore: ServiceTokenStore(),
                batchStore: ServiceBatchStore()
            ),
            confirmQuit: ConfirmationAlert.confirmQuitWhileProcessing,
            // The unit-test host is this app under the shipped bundle ID: a prompt
            // answered there would decide notifications for the installed copy too.
            asksNotificationPermissionAtLaunch: !UserDefaults.standard.bool(
                forKey: "SmugglerSkipsLaunchNotificationPrompt"),
            hasVisibleMainWindow: { NSApp.windows.contains { $0.isVisible && $0.canBecomeMain } }
        )
        self.updater = updater
    }

    // Lazy so a delegate built in a test never touches Sparkle.
    lazy var updater = UpdaterController()

    // Not ready while the app is still handling the request that launched it — such
    // a request must use cold-launch service mode (see consumeColdLaunch()).
    private enum LaunchPhase { case cold, awaitingWindow, ready }

    private var launchPhase = LaunchPhase.cold

    var isReady: Bool { launchPhase == .ready }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeMain(_:)), name: NSWindow.didBecomeMainNotification, object: nil)

        completeLaunch(
            isDefaultLaunch: (notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool) ?? true)
    }

    // AppKit sets launchIsDefault to false when the app was launched to
    // handle a URL or Services request. Never write false here: the
    // launching request may already have been consumed before this runs.
    @discardableResult
    func completeLaunch(isDefaultLaunch: Bool) -> Task<Void, Never> {
        if isDefaultLaunch {
            launchPhase = .ready
            appModel.handlers.sessionStays()
            // Asked here, where the answer has time to land: a headless session posts
            // its one result about a second after it asks, while the prompt is still up.
            return Task { [asks = asksNotificationPermissionAtLaunch, authorize = appModel.handlers.authorize] in
                if asks { await authorize() }
            }
        }
        return Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: coldLaunchGracePeriod)
            if !isReady {
                guard hasVisibleMainWindow() else {
                    launchPhase = .awaitingWindow
                    return
                }
                launchPhase = .ready
            }
            startUpdaterIfSessionStays()
        }
    }

    // Marks the launch sequence complete even when it returns false — every
    // request after the first must see an already-running app.
    func consumeColdLaunch() -> Bool {
        let wasCold = !isReady
        launchPhase = .ready
        return wasCold
    }

    @objc func windowDidBecomeMain(_ notification: Notification) {
        guard launchPhase == .awaitingWindow, (notification.object as? NSWindow)?.canBecomeMain == true else { return }
        launchPhase = .ready
        startUpdaterIfSessionStays()
    }

    // A session still serving a request may quit any moment; if it hands itself to
    // the window instead, the model's hand-back starts the updater then.
    private func startUpdaterIfSessionStays() {
        if !appModel.isServiceMode, !appModel.hasRequestsInFlight {
            appModel.handlers.sessionStays()
        }
    }

    // AppKit asks this after any window closes with none left showing, the
    // quit alert's own panel included: a declined quit would be asked again the
    // moment the alert goes away, and pass once the work had meanwhile finished.
    private var lastClosedWindowCanBecomeMain = false

    @objc func windowWillClose(_ notification: Notification) {
        lastClosedWindowCanBecomeMain = (notification.object as? NSWindow)?.canBecomeMain ?? false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        lastClosedWindowCanBecomeMain
    }

    // Installed by the scene once it exists: a closed SwiftUI window is gone
    // from `NSApp.windows`, so only SwiftUI's own action can bring it back.
    var openMainWindow: (() -> Void)?

    // Logout, restart and shutdown send a quit event that names a reason; a modal would
    // stall them and macOS would report Smuggler as the app that cancelled. The Dock,
    // the app switcher and scripts send the same event without one, and are asked.
    static func isSystemInitiatedQuit(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventClass == kCoreEventClass, event.eventID == kAEQuitApplication else {
            return false
        }
        // Documented as a parameter, commonly sent as an attribute: either counts.
        return event.attributeDescriptor(forKeyword: kAEQuitReason) != nil
            || event.paramDescriptor(forKeyword: kAEQuitReason) != nil
    }

    // A headless service session ends itself on purpose; only a person quitting
    // mid-run is doing it without knowing what they abandon.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !appModel.isServiceMode, appModel.isProcessing,
            !Self.isSystemInitiatedQuit(NSAppleEventManager.shared().currentAppleEvent)
        else {
            return .terminateNow
        }
        guard confirmQuit() else {
            // This path is also how closing the last window asks to quit. Staying
            // alive without bringing the window back would leave the work the user
            // just chose to keep running out of sight.
            openMainWindow?()
            return .terminateCancel
        }
        return .terminateNow
    }

    // MARK: - Request entry points

    // A request that launched the app runs headless; one reaching a running app
    // brings the window forward, because that is where its result will show.
    func handleIncomingURL(_ url: URL) {
        let isColdLaunch = consumeColdLaunch()
        guard let request = IncomingRequest(url: url) else {
            appModel.rejectIncomingRequest(url, isColdLaunch: isColdLaunch)
            return
        }
        if !isColdLaunch {
            bringWindowForward()
        }
        appModel.handleIncomingRequest(request, isColdLaunch: isColdLaunch)
    }

    @objc func removeQuarantine(
        _ pboard: NSPasteboard,
        userData: String,
        error errorPointer: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard
            let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
                as? [URL],
            !urls.isEmpty
        else {
            logger.warning("Services handler: no file paths on pasteboard")
            return
        }
        logger.info("Services handler: processing \(urls.count) item(s)")

        let isColdLaunch = consumeColdLaunch()
        if !isColdLaunch {
            bringWindowForward()
        }
        appModel.handleServicesRequest(urls, isColdLaunch: isColdLaunch)
    }

    // A headless batch that still owns the session may quit after its grace, and
    // Sparkle's prompt would go down with it unanswered.
    private func bringWindowForward() {
        // The app outlives a closed main window while Settings stays open.
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
        if !appModel.isServiceMode {
            appModel.handlers.sessionStays()
        }
    }
}

// The one place the model meets AppKit and the notification center; every
// other construction site hands in stubs.
extension AppModel.Handlers {
    static func live(sessionStays: @escaping AppModel.SessionStaysHandler) -> AppModel.Handlers {
        AppModel.Handlers(
            confirm: ConfirmationAlert.confirmRequest,
            open: { urls in
                for url in urls where !NSWorkspace.shared.open(url) {
                    logger.error("Failed to open \(url.path(percentEncoded: false), privacy: .private)")
                }
            },
            terminate: { NSApp.terminate(nil) },
            authorize: NotificationService.requestAuthorization,
            notify: NotificationService.postResult(items:),
            notifyFailure: NotificationService.postRequestFailure,
            sessionStays: sessionStays
        )
    }
}
