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
    typealias AuthorizeHandler = @MainActor () async -> Void
    typealias NotifyHandler = @MainActor ([FileItem]) async -> Void

    // Minimum visible processing duration so the user sees the app working.
    let minimumProcessingDuration: Duration

    let processingTimeout: Duration

    // Side-effect boundaries (alert, NSWorkspace, app termination) are injectable
    // so the service-mode flows can be tested with recording handlers.
    let confirm: ConfirmHandler
    let open: OpenHandler
    let terminate: TerminateHandler
    let authorize: AuthorizeHandler
    let notify: NotifyHandler
    let tokenStore: ServiceTokenStore

    init(
        minimumProcessingDuration: Duration = .seconds(1.0),
        processingTimeout: Duration = .seconds(30),
        confirm: ConfirmHandler? = nil,
        open: OpenHandler? = nil,
        terminate: TerminateHandler? = nil,
        authorize: AuthorizeHandler? = nil,
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
                    if !NSWorkspace.shared.open(url) {
                        Self.logger.error(
                            "Failed to open \(url.path(percentEncoded: false), privacy: .private)")
                    }
                }
            }
        self.terminate = terminate ?? { NSApp.terminate(nil) }
        self.authorize = authorize ?? { await NotificationService.requestAuthorization() }
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
        // Indexed once instead of a scan per URL: a Finder-extension batch of
        // thousands must not hold the main actor for O(items × urls) lookups.
        var existingIndexByURL: [URL: Int] = [:]
        existingIndexByURL.reserveCapacity(items.count)
        for (index, item) in items.enumerated() where existingIndexByURL[item.url] == nil {
            existingIndexByURL[item.url] = index
        }
        var newItems: [FileItem] = []
        var seenInBatch: Set<URL> = []
        for url in urls where seenInBatch.insert(url).inserted {
            // An in-flight row is adopted untouched — callers get an entry for
            // every requested URL without disturbing the row's running task.
            if itemURLs.contains(url) {
                if let index = existingIndexByURL[url] {
                    entries.append((items[index].id, url))
                }
                continue
            }
            // The lexical classification covers every entry point without
            // main-actor syscalls; the symlink-resolving check in the worker
            // stays the authoritative gate for anything a prefix cannot catch.
            let blocked = QuarantineService.hasBlockedPrefix(url)
            let status: FileStatus = blocked ? .error(.blockedPath(url)) : .processing
            if let index = existingIndexByURL[url] {
                items[index].status = status
                entries.append((items[index].id, url))
            } else {
                let item = FileItem(url: url, status: status)
                newItems.append(item)
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
        // Reversed so the batch reads newest-first, like one-at-a-time drops.
        // Guarded: an all-adopted batch would otherwise invalidate every observer
        // of `items` for a write that changes nothing.
        if !newItems.isEmpty {
            items.insert(contentsOf: newItems.reversed(), at: 0)
        }
        return entries
    }

    func process(urls: [URL]) async {
        var taskEntries: [(id: UUID, url: URL)] = []
        // A URL that already has a running task is awaited, not respawned —
        // callers still rely on returning only once every item finished.
        var tasksToAwait: [Task<Void, Never>] = []
        for (id, url) in enqueue(urls: urls) {
            if let run = activeTasks[id] {
                tasksToAwait.append(run.task)
            } else if itemURLs.contains(url) {
                taskEntries.append((id, url))
            }
        }
        guard !taskEntries.isEmpty || !tasksToAwait.isEmpty else { return }

        let service = self.service
        let minimumDuration = minimumProcessingDuration
        let timeout = processingTimeout

        // Spawn one Task per item so each can be individually cancelled.
        for (id, url) in taskEntries {
            let runID = UUID()
            let task = Task { [weak self] in
                let start = ContinuousClock.now

                let status: FileStatus = await withTaskGroup(of: FileStatus.self) { inner in
                    inner.addTask {
                        // The blocking walk runs detached — off-main, cancellation
                        // forwarded, one pool thread held per walk. The stream lets a
                        // cancelled child abandon a walk wedged in a syscall.
                        let (results, continuation) = AsyncStream.makeStream(of: FileStatus.self)
                        let walk = Task.detached(priority: .userInitiated) {
                            let status: FileStatus
                            do {
                                let result = try service.removeQuarantineRecursively(url)
                                if result.errors.isEmpty {
                                    status = result.cleaned > 0 ? .clean : .alreadyClean
                                } else if result.cleaned > 0 {
                                    status = .partialSuccess(cleaned: result.cleaned, errors: result.errors)
                                } else {
                                    status = .error(result.errors[0].error)
                                }
                            } catch let error as QuarantineError {
                                status = .error(error)
                            } catch {
                                status = .error(.systemError(url, -1))
                            }
                            continuation.yield(status)
                            continuation.finish()
                        }
                        return await withTaskCancellationHandler {
                            await results.first(where: { _ in true }) ?? .error(.timeout(url))
                        } onCancel: {
                            walk.cancel()
                            continuation.finish()
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
            // Held directly, not looked up again: a finished task removes its own
            // `activeTasks` entry, so the await loop would miss it.
            tasksToAwait.append(task)
        }

        // Callers rely on process() not returning until every item finished.
        for task in tasksToAwait {
            await task.value
        }
    }

    // MARK: - Cancel

    func cancelAll() {
        // Rows are enqueued as `.processing` before their tasks exist, so a batch
        // cancelled in that window is reachable only through `items`.
        var ids = Set(activeTasks.keys)
        ids.formUnion(items.lazy.filter { $0.status == .processing }.map(\.id))
        for id in ids {
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

    // MARK: - Service-Mode State

    // The tail of the request chain: each arrival waits on it to keep supersession
    // in arrival order.
    var incomingRequestTask: Task<Void, Never>?

    // Every request still in flight, keyed by arrival. The chain tail alone is not
    // enough — a predecessor is reachable only through its successor's capture, so
    // cancelling the tail would leave the request doing the actual work running.
    var liveRequestTasks: [Int: Task<Void, Never>] = [:]

    // Arrival counter: a request that is no longer the newest must not act for the
    // session as a whole, such as honoring its quit contract.
    var lastRequestID = 0

    var serviceMode: ServiceModeCoordinator?

    // Tracks the handler task for non-quitAfter service requests so `clear()`
    // can cancel it; quitAfter tasks live on their coordinator instead.
    var serviceHandlerTask: Task<Void, Never>?

    // MARK: - Clear

    func clear() {
        for run in activeTasks.values {
            run.task.cancel()
        }
        activeTasks.removeAll()
        for task in liveRequestTasks.values {
            task.cancel()
        }
        liveRequestTasks.removeAll()
        incomingRequestTask?.cancel()
        incomingRequestTask = nil
        serviceHandlerTask?.cancel()
        serviceHandlerTask = nil
        serviceMode?.cancel()
        serviceMode = nil
        items.removeAll()
        itemURLs.removeAll()
        processingCount = 0
    }
}
