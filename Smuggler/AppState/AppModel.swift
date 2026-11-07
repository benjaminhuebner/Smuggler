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

    nonisolated struct RunProgress: Equatable, Sendable {
        let done: Int
        let total: Int
    }

    typealias ConfirmHandler = @MainActor ([URL], ConfirmKind) -> Bool
    typealias OpenHandler = @MainActor ([URL]) -> Void
    typealias TerminateHandler = @MainActor () -> Void
    typealias AuthorizeHandler = @MainActor () async -> Void
    typealias NotifyHandler = @MainActor ([FileItem]) async -> Void
    typealias NotifyFailureHandler = @MainActor () async -> Void
    typealias SessionStaysHandler = @MainActor () -> Void

    // Every effect beyond the model's own state — the alert, launching, termination,
    // notifications, what a session that stays starts — arrives injected: the model
    // never meets AppKit, and no test can reach a modal by forgetting a stub.
    struct Handlers {
        let confirm: ConfirmHandler
        let open: OpenHandler
        let terminate: TerminateHandler
        let authorize: AuthorizeHandler
        let notify: NotifyHandler
        let notifyFailure: NotifyFailureHandler
        let sessionStays: SessionStaysHandler
    }

    // Minimum visible processing duration so the user sees the app working.
    let minimumProcessingDuration: Duration

    let processingTimeout: Duration

    // How long a finished or declined headless session lingers before it quits:
    // the result notification has to land, and a follow-up request gets its
    // chance to take the session over instead of dying with it.
    let terminationGrace: Duration

    let handlers: Handlers
    let tokenStore: ServiceTokenStore
    let batchStore: ServiceBatchStore
    private let walkExecutor: any TaskExecutor

    init(
        handlers: Handlers,
        tokenStore: ServiceTokenStore,
        batchStore: ServiceBatchStore,
        minimumProcessingDuration: Duration = .seconds(1),
        processingTimeout: Duration = .seconds(30),
        terminationGrace: Duration = .milliseconds(800),
        walkExecutor: any TaskExecutor = WalkExecutor()
    ) {
        self.handlers = handlers
        self.tokenStore = tokenStore
        self.batchStore = batchStore
        self.minimumProcessingDuration = minimumProcessingDuration
        self.processingTimeout = processingTimeout
        self.terminationGrace = terminationGrace
        self.walkExecutor = walkExecutor
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

    // Every row that entered processing since the model was last idle. `items` can't
    // size a run: it keeps earlier runs' rows and the paths refused at the door.
    private var runRowIDs: Set<UUID> = []

    var runTotal: Int { runRowIDs.count }

    private let service = QuarantineService()
    nonisolated private static let logger = Logger(subsystem: "com.benjaminhuebner.Smuggler", category: "AppModel")

    var isProcessing: Bool { processingCount > 0 }

    // A run of one item has nothing to count.
    var runProgress: RunProgress? {
        runTotal > 1 ? RunProgress(done: runTotal - processingCount, total: runTotal) : nil
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
            let id: UUID
            if let index = existingIndexByURL[url] {
                items[index].status = status
                items[index].processingSince = blocked ? nil : .now
                id = items[index].id
            } else {
                let item = FileItem(url: url, status: status)
                newItems.append(item)
                id = item.id
            }
            entries.append((id, url))
            if blocked {
                Self.logger.warning(
                    "Refusing blocked system path: \(url.path(percentEncoded: false), privacy: .private)")
            } else {
                // Reset as a run starts, not as it ends: the status bar keeps showing
                // the count while the last rows' fills land.
                if processingCount == 0 { runRowIDs.removeAll() }
                itemURLs.insert(url)
                processingCount += 1
                // A settled row dropped again re-enters the run, not a second item of it.
                runRowIDs.insert(id)
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
        let executor = walkExecutor
        let minimumDuration = minimumProcessingDuration
        let timeout = processingTimeout

        // Spawn one Task per item so each can be individually cancelled.
        for (id, url) in taskEntries {
            let runID = UUID()
            let task = Task { [weak self] in
                // Held before the walk, not after it: a cancel inside the hold then
                // stops work that has not begun instead of hiding a result on disk.
                do { try await Task.sleep(for: minimumDuration) } catch { return }
                guard self != nil, !Task.isCancelled else { return }

                let status = await Self.outcome(of: url, service: service, executor: executor, timeout: timeout)

                guard let self, activeTasks[id]?.runID == runID else { return }
                activeTasks.removeValue(forKey: id)
                if let index = items.firstIndex(where: { $0.id == id }) {
                    settle(rowAt: index, as: status)
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

    // The walk stops itself at its deadline and reports what it freed; the backstop is
    // for a walk wedged in one syscall. Both start once the walk has a thread, so time
    // spent queued behind other walks is not charged to it.
    @concurrent
    private nonisolated static func outcome(
        of url: URL, service: QuarantineService, executor: any TaskExecutor, timeout: Duration
    ) async -> FileStatus {
        let (results, continuation) = AsyncStream.makeStream(of: FileStatus.self)
        let walk = Task.detached(executorPreference: executor, priority: .userInitiated) {
            let deadline = ContinuousClock.now + timeout
            // Unstructured on purpose: a child task would inherit the walk executor and
            // wake on the very threads a hung volume is holding.
            let backstop = Task {
                try await Task.sleep(until: deadline + .seconds(5), clock: .continuous)
                continuation.yield(.error(.timeout(url)))
            }
            defer { backstop.cancel() }
            do throws(QuarantineError) {
                let result = try service.removeQuarantineRecursively(url, deadline: deadline)
                continuation.yield(FileStatus(outcomeOf: result, for: url))
            } catch {
                continuation.yield(.error(error))
            }
            continuation.finish()
        }
        // Also when the backstop answered: a walk wedged short of its root, which no
        // deadline guards, would otherwise free it after its row reads as timed out.
        defer { walk.cancel() }
        // A cancelled caller cannot interrupt a syscall, so it abandons the walk
        // instead: finishing the stream returns at once.
        return await withTaskCancellationHandler {
            for await status in results {
                return status
            }
            return .error(.timeout(url))
        } onCancel: {
            walk.cancel()
            continuation.finish()
        }
    }

    // MARK: - Cancel

    func cancelAll() {
        for run in activeTasks.values {
            run.task.cancel()
        }
        activeTasks.removeAll()
        // One pass over the rows, not a lookup per ID, which is quadratic on the main
        // actor for a Finder batch of thousands. It also reaches rows enqueued as
        // `.processing` before their tasks exist.
        for index in items.indices {
            settle(rowAt: index, as: .cancelled)
        }
    }

    func cancel(id: UUID) {
        activeTasks.removeValue(forKey: id)?.task.cancel()
        if let index = items.firstIndex(where: { $0.id == id }) {
            settle(rowAt: index, as: .cancelled)
        }
    }

    // The one way out of `.processing`, so the in-flight count and the duplicate
    // set cannot drift from the rows.
    private func settle(rowAt index: Int, as status: FileStatus) {
        guard items[index].status == .processing else { return }
        items[index].status = status
        items[index].processingSince = nil
        processingCount -= 1
        itemURLs.remove(items[index].url)
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

    var isServiceMode: Bool { serviceMode != nil }

    var hasRequestsInFlight: Bool { !liveRequestTasks.isEmpty }

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
        runRowIDs.removeAll()
    }
}
