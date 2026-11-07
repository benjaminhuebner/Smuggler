import AppKit
import Foundation
import Testing

@testable import Smuggler

// Inert like `makeModel`: a quit prompt nobody expected fails the test instead of
// parking the run on a modal, and the updater starts only through the model's stub.
@MainActor
private func makeDelegate(
    model: AppModel = makeModel(),
    confirmQuit: @escaping @MainActor () -> Bool = {
        Issue.record("Unexpected quit confirmation")
        return false
    },
    asksNotificationPermissionAtLaunch: Bool = true,
    hasVisibleMainWindow: @escaping @MainActor () -> Bool = { true },
    coldLaunchGracePeriod: Duration = .milliseconds(50)
) -> AppDelegate {
    AppDelegate(
        appModel: model,
        confirmQuit: confirmQuit,
        asksNotificationPermissionAtLaunch: asksNotificationPermissionAtLaunch,
        hasVisibleMainWindow: hasVisibleMainWindow,
        coldLaunchGracePeriod: coldLaunchGracePeriod
    )
}

@MainActor
private func sendServicesRequest(_ urls: [URL], to delegate: AppDelegate) {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.writeObjects(urls.map { $0 as NSURL })
    var error: NSString?
    delegate.removeQuarantine(pasteboard, userData: "", error: &error)
}

private final class MainCapableWindow: NSWindow {
    override var canBecomeMain: Bool { true }
}

@Suite("AppDelegate — launch")
@MainActor
struct AppDelegateLaunchTests {
    let sandbox = TestSandbox()

    @Test("Default launches are immediately ready")
    func defaultLaunchIsReady() {
        let delegate = makeDelegate()

        delegate.completeLaunch(isDefaultLaunch: true)

        #expect(delegate.isReady)
        #expect(delegate.consumeColdLaunch() == false)
    }

    @Test("First request after a non-default launch is the cold-launch request")
    func nonDefaultLaunchConsumesColdLaunchOnce() {
        let delegate = makeDelegate()

        delegate.completeLaunch(isDefaultLaunch: false)

        #expect(delegate.consumeColdLaunch() == true)
        #expect(delegate.consumeColdLaunch() == false)
    }

    @Test("An unconsumed cold launch expires after the grace period")
    func unconsumedColdLaunchExpires() async throws {
        let delegate = makeDelegate()

        await delegate.completeLaunch(isDefaultLaunch: false).value

        #expect(delegate.isReady)
        #expect(delegate.consumeColdLaunch() == false)
    }

    @Test("A cold launch with no window shown yet keeps waiting for its request past the grace")
    func coldLaunchWithoutWindowOutlastsGrace() async {
        let recorder = HandlerRecorder()
        let delegate = makeDelegate(model: makeModel(recorder: recorder), hasVisibleMainWindow: { false })

        await delegate.completeLaunch(isDefaultLaunch: false).value

        #expect(!delegate.isReady)
        #expect(recorder.sessionStaysCount == 0)
        #expect(delegate.consumeColdLaunch() == true)
    }

    @Test("The first main window ends a cold launch that outlasted its grace")
    func firstMainWindowEndsWaitingColdLaunch() async {
        let recorder = HandlerRecorder()
        let delegate = makeDelegate(model: makeModel(recorder: recorder), hasVisibleMainWindow: { false })

        await delegate.completeLaunch(isDefaultLaunch: false).value
        delegate.windowDidBecomeMain(Notification(name: NSWindow.didBecomeMainNotification, object: NSPanel()))
        #expect(!delegate.isReady)
        delegate.windowDidBecomeMain(
            Notification(name: NSWindow.didBecomeMainNotification, object: MainCapableWindow()))

        #expect(delegate.isReady)
        #expect(recorder.sessionStaysCount == 1)
        #expect(delegate.consumeColdLaunch() == false)
    }

    @Test("A Services request confirmed after the grace, before any window showed, still runs headless")
    func lateServicesRequestWithoutWindowRunsHeadless() async throws {
        let url = try sandbox.file(quarantined: true)
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder)
        let delegate = makeDelegate(model: model, hasVisibleMainWindow: { false })

        await delegate.completeLaunch(isDefaultLaunch: false).value
        sendServicesRequest([url], to: delegate)
        try await model.settle()

        #expect(model.items.map(\.status) == [.clean])
        #expect(recorder.terminateCount == 1)
        #expect(recorder.sessionStaysCount == 0)
    }

    @Test("A request consumed before launch completion is not re-armed")
    func earlyRequestIsNotRearmed() {
        let delegate = makeDelegate()

        #expect(delegate.consumeColdLaunch() == true)
        delegate.completeLaunch(isDefaultLaunch: false)

        #expect(delegate.consumeColdLaunch() == false)
    }

    @Test("A default launch starts the updater and asks for notification permission")
    func defaultLaunchStartsUpdaterAndAsksPermission() async {
        let recorder = HandlerRecorder()
        let delegate = makeDelegate(model: makeModel(recorder: recorder))

        await delegate.completeLaunch(isDefaultLaunch: true).value

        #expect(recorder.sessionStaysCount == 1)
        #expect(recorder.authorizeCount == 1)
    }

    @Test("A default launch with the permission prompt switched off starts the updater but asks nothing")
    func defaultLaunchWithoutPromptDoesNotAsk() async {
        let recorder = HandlerRecorder()
        let delegate = makeDelegate(model: makeModel(recorder: recorder), asksNotificationPermissionAtLaunch: false)

        await delegate.completeLaunch(isDefaultLaunch: true).value

        #expect(recorder.sessionStaysCount == 1)
        #expect(recorder.authorizeCount == 0)
    }

    @Test("A launch that delivered no request starts the updater once its grace ends")
    func requestlessLaunchStartsUpdaterAfterGrace() async {
        let recorder = HandlerRecorder()
        let delegate = makeDelegate(model: makeModel(recorder: recorder))

        let grace = delegate.completeLaunch(isDefaultLaunch: false)
        #expect(recorder.sessionStaysCount == 0)
        await grace.value

        #expect(recorder.sessionStaysCount == 1)
        #expect(recorder.authorizeCount == 0)
    }

    @Test("A launch by a URL that keeps the app open starts the updater once its grace ends")
    func interactiveURLLaunchStartsUpdaterAfterGrace() async throws {
        let url = try sandbox.file(quarantined: true)
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder, confirming: true)
        let delegate = makeDelegate(model: model)
        let request = try #require(URL(string: "smuggler://process?action=remove&path=\(url.path())"))

        delegate.handleIncomingURL(request)
        try await model.settle()
        #expect(recorder.sessionStaysCount == 1)
        await delegate.completeLaunch(isDefaultLaunch: false).value

        #expect(model.items.map(\.status) == [.clean])
        #expect(recorder.sessionStaysCount == 2)
    }

    @Test("A launch serving a headless request never starts the updater")
    func headlessLaunchDoesNotStartUpdater() async throws {
        let url = try sandbox.file(quarantined: true)
        let executor = GatedExecutor()
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder, walkExecutor: executor)
        let delegate = makeDelegate(model: model)

        let grace = delegate.completeLaunch(isDefaultLaunch: false)
        sendServicesRequest([url], to: delegate)
        await grace.value
        #expect(recorder.sessionStaysCount == 0)

        executor.open()
        try await model.settle()
        #expect(recorder.terminateCount == 1)
        #expect(recorder.sessionStaysCount == 0)
    }

    @Test("A launch whose request is still waiting its turn when the grace ends does not start the updater")
    func pendingLaunchRequestDoesNotStartUpdater() async throws {
        let url = try sandbox.file(quarantined: true)
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder)
        let delegate = makeDelegate(model: model)

        let release = model.parkRequestQueue()
        let grace = delegate.completeLaunch(isDefaultLaunch: false)
        sendServicesRequest([url], to: delegate)
        await grace.value
        #expect(recorder.sessionStaysCount == 0)

        release.finish()
        try await model.settle()
        #expect(recorder.terminateCount == 1)
    }

    @Test("A request reaching the running app starts the updater while the launching one still waits its turn")
    func warmRequestBehindLaunchRequestStartsUpdater() async throws {
        let launching = try sandbox.file(quarantined: true)
        let later = try sandbox.file(quarantined: true)
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder)
        let delegate = makeDelegate(model: model)

        let release = model.parkRequestQueue()
        sendServicesRequest([launching], to: delegate)
        sendServicesRequest([later], to: delegate)
        #expect(recorder.sessionStaysCount == 1)

        release.finish()
        try await model.settle()
        #expect(model.items.map(\.status) == [.clean, .clean])
        #expect(recorder.sessionStaysCount == 2)
        #expect(recorder.terminateCount == 0)
    }
}

@Suite("AppDelegate — quit")
@MainActor
struct AppDelegateQuitTests {
    let sandbox = TestSandbox()

    @Test("An idle app quits without asking")
    func idleQuitDoesNotAsk() {
        let delegate = makeDelegate()

        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateNow)
    }

    @Test("A declined quit mid-run keeps the work going and brings the window back")
    func declinedQuitKeepsWorkAndReopensWindow() throws {
        let url = try sandbox.file(quarantined: true)
        let recorder = HandlerRecorder()
        let model = makeModel()
        let delegate = makeDelegate(
            model: model,
            confirmQuit: {
                recorder.quitPromptCount += 1
                return false
            })
        delegate.openMainWindow = { recorder.windowReopenCount += 1 }
        model.enqueue(urls: [url])
        try #require(model.isProcessing)

        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateCancel)
        #expect(recorder.quitPromptCount == 1)
        #expect(recorder.windowReopenCount == 1)
        #expect(model.isProcessing)
    }

    @Test("An approved quit mid-run ends the app without reopening the window")
    func approvedQuitTerminates() throws {
        let url = try sandbox.file(quarantined: true)
        let recorder = HandlerRecorder()
        let model = makeModel()
        let delegate = makeDelegate(
            model: model,
            confirmQuit: {
                recorder.quitPromptCount += 1
                return true
            })
        delegate.openMainWindow = { recorder.windowReopenCount += 1 }
        model.enqueue(urls: [url])

        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateNow)
        #expect(recorder.quitPromptCount == 1)
        #expect(recorder.windowReopenCount == 0)
    }

    @Test("A headless session quits without asking, even mid-run")
    func headlessSessionQuitsWithoutAsking() async throws {
        let url = try sandbox.file(quarantined: true)
        let model = makeModel()
        let delegate = makeDelegate(model: model)

        model.handleServiceURLs([url], action: .remove, quitAfter: true)
        try #require(model.isProcessing)
        try #require(model.serviceMode != nil)

        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateNow)
        try await model.settle()
    }

    @Test("Only a closing window that could be main ends the app once it was the last")
    func lastWindowCloseDependsOnTheClosingWindow() {
        let delegate = makeDelegate()
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))

        delegate.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: MainCapableWindow()))
        #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))

        // The quit alert's own panel closing after the window must not ask again.
        delegate.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: NSPanel()))
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))

        delegate.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: nil))
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
    }
}

@Suite("AppDelegate — quit reason")
@MainActor
struct AppDelegateQuitReasonTests {
    private static func appleEvent(_ eventID: AEEventID) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor.appleEvent(
            withEventClass: kCoreEventClass,
            eventID: eventID,
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
    }

    @Test("No event, or a quit that names no reason, is a person quitting")
    func quitWithoutReasonIsNotSystemInitiated() {
        #expect(!AppDelegate.isSystemInitiatedQuit(nil))
        #expect(!AppDelegate.isSystemInitiatedQuit(Self.appleEvent(kAEQuitApplication)))
    }

    @Test(
        "A quit naming a reason comes from the system, as attribute or as parameter",
        arguments: [kAEReallyLogOut, kAERestart, kAEShutDown, kAEQuitAll])
    func quitWithReasonIsSystemInitiated(reason: OSType) {
        let asAttribute = Self.appleEvent(kAEQuitApplication)
        asAttribute.setAttribute(NSAppleEventDescriptor(enumCode: reason), forKeyword: kAEQuitReason)
        let asParameter = Self.appleEvent(kAEQuitApplication)
        asParameter.setParam(NSAppleEventDescriptor(enumCode: reason), forKeyword: kAEQuitReason)

        #expect(AppDelegate.isSystemInitiatedQuit(asAttribute))
        #expect(AppDelegate.isSystemInitiatedQuit(asParameter))
    }

    @Test("A reason on any event but a quit does not count")
    func reasonOnOtherEventIsIgnored() {
        let event = Self.appleEvent(kAEOpenDocuments)
        event.setAttribute(NSAppleEventDescriptor(enumCode: kAEReallyLogOut), forKeyword: kAEQuitReason)

        #expect(!AppDelegate.isSystemInitiatedQuit(event))
    }
}

@Suite("AppDelegate — Services entry")
@MainActor
struct AppDelegateServicesTests {
    let sandbox = TestSandbox()

    @Test("A Services request that launched the app frees its file items without asking, then quits")
    func coldServicesRequestRunsHeadless() async throws {
        let url = try sandbox.file(quarantined: true)
        let other = try sandbox.file(quarantined: true)
        // Read as a path, this web address would name a real, quarantined item.
        let web = try #require(URL(string: "https://example.com\(other.path())"))
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder)
        let delegate = makeDelegate(model: model)
        delegate.openMainWindow = { recorder.windowReopenCount += 1 }

        sendServicesRequest([url, web], to: delegate)

        try await model.settle()
        #expect(recorder.confirmations.isEmpty)
        #expect(model.items.map(\.url) == [url])
        #expect(model.items.map(\.status) == [.clean])
        #expect(hasQuarantine(other))
        #expect(recorder.notifiedBatches.count == 1)
        #expect(recorder.terminateCount == 1)
        #expect(recorder.windowReopenCount == 0)
        #expect(delegate.consumeColdLaunch() == false)
    }

    @Test("A request reaching a running app brings the main window back, even after it was closed")
    func warmRequestReopensMainWindow() async throws {
        let viaServices = try sandbox.file(quarantined: true)
        let viaURL = try sandbox.file(quarantined: true)
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder, confirming: true)
        let delegate = makeDelegate(model: model)
        delegate.completeLaunch(isDefaultLaunch: true)
        delegate.openMainWindow = { recorder.windowReopenCount += 1 }

        sendServicesRequest([viaServices], to: delegate)
        #expect(recorder.windowReopenCount == 1)
        delegate.handleIncomingURL(try #require(URL(string: "smuggler://process?action=remove&path=\(viaURL.path())")))
        #expect(recorder.windowReopenCount == 2)

        try await model.settle()
        #expect(model.items.map(\.status) == [.clean, .clean])
    }

    @Test("A pasteboard without file items runs nothing and leaves the cold launch unused")
    func servicesRequestWithoutFilesIsIgnored() throws {
        let web = try #require(URL(string: "https://example.com/Users"))
        let model = makeModel()
        let delegate = makeDelegate(model: model)

        sendServicesRequest([web], to: delegate)

        #expect(model.incomingRequestTask == nil)
        #expect(delegate.consumeColdLaunch())
    }

    @Test("A Services request for a protected item is refused and keeps the window up")
    func servicesRequestRefusesProtectedItem() async throws {
        let blocked = URL(filePath: "/usr/bin/true")
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder, confirming: true)
        let delegate = makeDelegate(model: model)

        sendServicesRequest([blocked], to: delegate)

        try await model.settle()
        #expect(model.items.map(\.status) == [.error(.blockedPath(blocked))])
        #expect(recorder.confirmations.isEmpty)
        #expect(recorder.terminateCount == 0)
        #expect(model.serviceMode == nil)
    }
}
