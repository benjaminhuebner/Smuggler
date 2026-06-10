import AppKit
import Foundation
import Observation
import os

@Observable
@MainActor
final class AppModel {
    nonisolated enum ConfirmKind: Sendable {
        case open
        case remove
    }

    typealias ConfirmHandler = @MainActor ([URL], ConfirmKind) -> Bool
    typealias OpenHandler = @MainActor ([URL]) -> Void
    typealias TerminateHandler = @MainActor () -> Void
    typealias NotifyHandler = @MainActor ([FileItem]) async -> Void

    // Minimum visible processing duration so the user perceives the app working.
    let minimumProcessingDuration: Duration

    let processingTimeout: Duration

    // Side-effect boundaries (alert, NSWorkspace, app termination) are injectable
    // so the service-mode flows can be tested with recording handlers.
    private let confirm: ConfirmHandler
    private let open: OpenHandler
    private let terminate: TerminateHandler
    private let notify: NotifyHandler
    private let tokenStore: ServiceTokenStore

    init(
        minimumProcessingDuration: Duration = .seconds(1.0),
        processingTimeout: Duration = .seconds(30),
        confirm: ConfirmHandler? = nil,
        open: OpenHandler? = nil,
        terminate: TerminateHandler? = nil,
        notify: NotifyHandler? = nil,
        tokenStore: ServiceTokenStore = ServiceTokenStore()
    ) {
        self.minimumProcessingDuration = minimumProcessingDuration
        self.processingTimeout = processingTimeout
        self.tokenStore = tokenStore
        self.confirm = confirm ?? Self.confirmViaAlert
        self.open =
            open ?? { urls in
                for url in urls {
                    NSWorkspace.shared.open(url)
                }
            }
        self.terminate = terminate ?? { NSApp.terminate(nil) }
        self.notify = notify ?? { await NotificationService.postResult(items: $0) }
    }

    var items: [FileItem] = []

    // Pairs each task with a per-run identity: a cancelled task can keep
    // draining after its item was re-enqueued, and only the registered run
    // may apply its result.
    private struct ActiveRun {
        let runID: UUID
        let task: Task<Void, Never>
    }

    private var activeTasks: [UUID: ActiveRun] = [:]

    // Tracks URLs with a row still in flight, for O(1) duplicate detection.
    // Terminal rows leave the set so a re-drop can re-process the same URL.
    private var itemURLs: Set<URL> = []

    // Maintained separately so `isProcessing` is O(1).
    private(set) var processingCount: Int = 0

    private let service = QuarantineService()
    nonisolated private static let logger = Logger(subsystem: "com.benjaminhuebner.Smuggler", category: "AppModel")

    var isProcessing: Bool { processingCount > 0 }

    var cleanedCount: Int {
        items.count(where: \.status.isSuccessful)
    }

    var failedCount: Int {
        items.count(where: \.status.hasErrors)
    }

    var allCancelled: Bool {
        !items.isEmpty && items.allSatisfy { $0.status == .cancelled }
    }

    // MARK: - Enqueue & Process

    @discardableResult
    func enqueue(urls: [URL]) -> [(id: UUID, url: URL)] {
        var entries: [(id: UUID, url: URL)] = []
        for url in urls where !itemURLs.contains(url) {
            // Classifying blocked system paths here covers every entry point —
            // URL scheme, Services menu, drag-and-drop, and the open panel.
            let blocked = QuarantineService.isBlockedPath(url)
            let status: FileStatus = blocked ? .error(.blockedPath(url)) : .processing
            if let idx = items.firstIndex(where: { $0.url == url }) {
                items[idx].status = status
                entries.append((items[idx].id, url))
            } else {
                let item = FileItem(url: url, status: status)
                items.insert(item, at: 0)
                entries.append((item.id, url))
            }
            if blocked {
                Self.logger.warning(
                    "Refusing blocked system path: \(url.path(percentEncoded: false), privacy: .private)")
            } else {
                itemURLs.insert(url)
                processingCount += 1
            }
        }
        return entries
    }

    func process(urls: [URL]) async {
        // Collect entries from `items`, not from enqueue's return value — some
        // URLs may already have been enqueued by handleServiceURLs.
        enqueue(urls: urls)
        var seenIDs = Set<UUID>()
        let taskEntries: [(id: UUID, url: URL)] = urls.compactMap { url in
            // Skip items that already have a running task — a second concurrent
            // process(urls:) for a still-processing URL must not spawn a duplicate.
            guard let item = items.first(where: { $0.url == url }),
                item.status == .processing,
                activeTasks[item.id] == nil,
                seenIDs.insert(item.id).inserted
            else { return nil }
            return (item.id, url)
        }
        guard !taskEntries.isEmpty else { return }

        let service = self.service
        let minimumDuration = minimumProcessingDuration
        let timeout = processingTimeout

        // Spawn one Task per item so each can be individually cancelled.
        // Capture handles directly so the await loop doesn't miss completed tasks.
        var spawnedTasks: [(id: UUID, task: Task<Void, Never>)] = []

        for (id, url) in taskEntries {
            let runID = UUID()
            let task = Task { [weak self] in
                let start = ContinuousClock.now

                let status: FileStatus = await withTaskGroup(of: FileStatus.self) { inner in
                    inner.addTask {
                        // The recursive walk is blocking synchronous I/O — run it on a
                        // detached task so it cannot starve the cooperative pool, and
                        // forward cancellation so the walk aborts its enumeration.
                        let walk = Task.detached(priority: .userInitiated) {
                            try service.removeQuarantineRecursively(url)
                        }
                        return await withTaskCancellationHandler {
                            do {
                                let result = try await walk.value
                                if result.errors.isEmpty {
                                    return result.cleaned > 0 ? .clean : .alreadyClean
                                } else if result.cleaned > 0 {
                                    return .partialSuccess(cleaned: result.cleaned, errors: result.errors)
                                } else {
                                    return .error(result.errors[0].error)
                                }
                            } catch let error as QuarantineError {
                                return .error(error)
                            } catch {
                                return .error(.systemError(url, -1))
                            }
                        } onCancel: {
                            walk.cancel()
                        }
                    }

                    inner.addTask {
                        try? await Task.sleep(for: timeout)
                        return .error(.timeout(url))
                    }

                    guard let first = await inner.next() else {
                        return .error(.systemError(url, -1))
                    }
                    inner.cancelAll()
                    return first
                }

                guard let self else { return }

                let elapsed = ContinuousClock.now - start
                if elapsed < minimumDuration {
                    try? await Task.sleep(for: minimumDuration - elapsed)
                }

                guard activeTasks[id]?.runID == runID else { return }
                activeTasks.removeValue(forKey: id)
                if let idx = items.firstIndex(where: { $0.id == id }),
                    items[idx].status == .processing
                {
                    items[idx].status = status
                    processingCount -= 1
                    itemURLs.remove(url)
                }
            }
            activeTasks[id] = ActiveRun(runID: runID, task: task)
            spawnedTasks.append((id, task))
        }

        // Callers rely on process() not returning until every item finished.
        for (_, task) in spawnedTasks {
            await task.value
        }
    }

    // MARK: - Cancel

    func cancelAll() {
        for id in Array(activeTasks.keys) {
            cancel(id: id)
        }
    }

    func cancel(id: UUID) {
        activeTasks[id]?.task.cancel()
        activeTasks.removeValue(forKey: id)
        if let idx = items.firstIndex(where: { $0.id == id }),
            items[idx].status == .processing
        {
            items[idx].status = .cancelled
            processingCount -= 1
            itemURLs.remove(items[idx].url)
        }
    }

    // MARK: - URL Scheme Parsing

    nonisolated struct IncomingRequest: Sendable {
        let urls: [URL]
        let action: ServiceAction
        let quitAfter: Bool
        let token: String?
    }

    nonisolated static func parseIncomingURL(_ url: URL) -> IncomingRequest? {
        guard url.scheme == "smuggler", url.host == "process" else {
            logger.warning("Received unknown URL: \(url, privacy: .private)")
            return nil
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        let paths = queryItems.filter { $0.name == "path" }.compactMap(\.value)
        guard !paths.isEmpty else {
            logger.warning("URL missing path parameter(s): \(url, privacy: .private)")
            return nil
        }

        let rawAction = queryItems.first(where: { $0.name == "action" })?.value ?? ServiceAction.open.rawValue
        guard let action = ServiceAction(rawValue: rawAction) else {
            logger.warning("Invalid action in URL: \(rawAction)")
            return nil
        }

        let quitAfter = queryItems.first(where: { $0.name == "quitAfter" })?.value == "true"
        let token = queryItems.first(where: { $0.name == "token" })?.value

        return IncomingRequest(
            urls: paths.map { URL(fileURLWithPath: $0).standardizedFileURL },
            action: action,
            quitAfter: quitAfter,
            token: token
        )
    }

    func handleIncomingRequest(_ request: IncomingRequest, isColdLaunch: Bool) {
        // Blocked paths skip the existence filter — a refused path must surface
        // as a refusal row, never silently vanish.
        let urls = request.urls.filter { url in
            QuarantineService.isBlockedPath(url)
                || FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        }
        guard !urls.isEmpty else { return }
        handleURLRequest(
            urls: urls,
            action: request.action,
            quitAfter: request.quitAfter && isColdLaunch,
            token: request.token
        )
    }

    // Unlike the OS-mediated Services flow, a smuggler:// URL can come from any
    // process or website, and both actions strip quarantine — every untrusted
    // request needs human approval; only a valid Finder-extension token skips it.
    func handleURLRequest(urls: [URL], action: ServiceAction, quitAfter: Bool, token: String?) {
        let trusted = token.map { tokenStore.consumeToken($0) } ?? false
        if !trusted {
            // Blocked paths are refused by the pipeline anyway; only paths that
            // would actually be processed need approval.
            let removableURLs = urls.filter { !QuarantineService.isBlockedPath($0) }
            if !removableURLs.isEmpty, !confirm(removableURLs, .remove) {
                if quitAfter { terminate() }
                return
            }
        }
        handleServiceURLs(urls, action: action, quitAfter: quitAfter)
    }

    // MARK: - Service Mode

    private(set) var serviceMode: ServiceModeCoordinator?

    // Tracks the handler task for non-quitAfter service requests so `clear()`
    // can cancel it; quitAfter tasks live on their coordinator instead.
    private var serviceHandlerTask: Task<Void, Never>?

    func handleServiceURLs(_ urls: [URL], action: ServiceAction, quitAfter: Bool) {
        let entries = enqueue(urls: urls)
        let entryIDs = Set(entries.map(\.id))

        if quitAfter {
            // A superseded batch must not fire its termination or notification.
            serviceMode?.cancel()
            let coordinator = ServiceModeCoordinator(
                entryIDs: entryIDs,
                action: action,
                quitAfter: true
            )
            coordinator.authorizationTask = Task { await NotificationService.requestAuthorization() }
            serviceMode = coordinator

            coordinator.processingTask = Task { [weak self] in
                guard let self else { return }
                await process(urls: urls)
                guard !Task.isCancelled else { return }
                await finishServiceMode(coordinator)
            }
        } else {
            serviceHandlerTask = Task { [weak self] in
                guard let self else { return }
                await process(urls: urls)
                guard !Task.isCancelled, action == .open else { return }
                let urlsToOpen =
                    items
                    .filter { entryIDs.contains($0.id) && $0.status.isSuccessful }
                    .map(\.url)
                confirmAndOpen(urlsToOpen)
            }
        }
    }

    // The notify suspension and the confirmation's nested modal run loop are
    // supersession points: a second batch can replace `serviceMode` meanwhile,
    // so every later step must re-check identity before clearing or terminating.
    private func finishServiceMode(_ coordinator: ServiceModeCoordinator) async {
        let batchItems = items.filter { coordinator.entryIDs.contains($0.id) }
        let hasErrors = batchItems.contains(where: \.status.hasErrors)

        if hasErrors {
            // Tell the user why the window lingers instead of failing silently.
            await notify(batchItems)
            if serviceMode === coordinator {
                serviceMode = nil
            }
            return
        }

        if coordinator.action == .open {
            let urlsToOpen = batchItems.filter(\.status.isSuccessful).map(\.url)
            confirmAndOpen(urlsToOpen)
        }

        guard serviceMode === coordinator else { return }
        coordinator.terminationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            if coordinator.action != .open {
                await self?.notify(batchItems)
            }
            if coordinator.quitAfter {
                self?.terminate()
            } else if self?.serviceMode === coordinator {
                self?.serviceMode = nil
            }
        }
    }

    // MARK: - Open (confirmed)

    // Removing the quarantine attribute strips macOS's own Gatekeeper launch check,
    // and a smuggler:// request can come from any process, so a human must
    // approve the launch before we open anything on the request's behalf.
    private func confirmAndOpen(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard confirm(urls, .open) else { return }
        open(urls)
    }

    private static func confirmViaAlert(_ urls: [URL], kind: ConfirmKind) -> Bool {
        // The dialog may be triggered while another app is frontmost (URL scheme,
        // headless service launch) — without activation it would appear behind.
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        switch kind {
        case .open:
            alert.messageText =
                urls.count == 1
                ? String(
                    localized: "Open \(urls[0].lastPathComponent)?",
                    comment: "Confirm dialog title: open a single file after removing quarantine")
                : String(
                    localized: "Open \(urls.count) items?",
                    comment: "Confirm dialog title: open multiple files after removing quarantine")
            alert.informativeText = String(
                localized: "Quarantine was removed. Only open items you trust.",
                comment: "Confirm dialog body: warn before opening files after quarantine removal")
            alert.addButton(withTitle: String(localized: "Open", comment: "Confirm dialog: open button"))
        case .remove:
            alert.messageText =
                urls.count == 1
                ? String(
                    localized: "Remove quarantine from \(urls[0].lastPathComponent)?",
                    comment: "Confirm dialog title: external request to remove quarantine from one file")
                : String(
                    localized: "Remove quarantine from \(urls.count) items?",
                    comment: "Confirm dialog title: external request to remove quarantine from multiple files")
            let displayedPaths = urls.prefix(10).map { $0.path(percentEncoded: false) }
            var pathList = displayedPaths.joined(separator: "\n")
            if urls.count > displayedPaths.count {
                let more = urls.count - displayedPaths.count
                pathList +=
                    "\n"
                    + String(
                        localized: "and \(more) more",
                        comment: "Confirm dialog: suffix when the path list is truncated")
            }
            alert.informativeText = String(
                localized: """
                    Smuggler could not verify that this request came from its Finder extension. \
                    Only continue if you initiated it.

                    \(pathList)
                    """,
                comment: "Confirm dialog body: warn about an external quarantine-removal request")
            alert.addButton(
                withTitle: String(
                    localized: "Remove Quarantine",
                    comment: "Confirm dialog: remove quarantine button"))
        }
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Confirm dialog: cancel button"))

        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Clear

    func clear() {
        for (_, run) in activeTasks {
            run.task.cancel()
        }
        activeTasks.removeAll()
        serviceHandlerTask?.cancel()
        serviceHandlerTask = nil
        serviceMode?.cancel()
        serviceMode = nil
        items.removeAll()
        itemURLs.removeAll()
        processingCount = 0
    }
}
