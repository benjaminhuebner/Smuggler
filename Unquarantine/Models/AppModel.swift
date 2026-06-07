//
//  AppModel.swift
//  Unquarantine
//
//  Created by Benjamin Hübner on 21.03.26.
//

import AppKit
import Foundation
import Observation
import os

@Observable
@MainActor
final class AppModel {
    /// Minimum visible processing duration so the user perceives the app working.
    let minimumProcessingDuration: Duration

    /// Timeout for processing a single item.
    let processingTimeout: Duration

    init(
        minimumProcessingDuration: Duration = .seconds(1.0),
        processingTimeout: Duration = .seconds(30)
    ) {
        self.minimumProcessingDuration = minimumProcessingDuration
        self.processingTimeout = processingTimeout
    }

    var items: [FileItem] = []

    /// Active processing tasks keyed by FileItem id, used for cancellation.
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

    /// Tracks URLs already in `items` for O(1) duplicate detection.
    private var itemURLs: Set<URL> = []

    /// Number of items currently being processed, for O(1) `isProcessing`.
    private(set) var processingCount: Int = 0

    private let service = QuarantineService()
    nonisolated private static let logger = Logger(subsystem: "com.benjaminhuebner.Unquarantine", category: "AppModel")

    var isProcessing: Bool { processingCount > 0 }

    var cleanedCount: Int {
        items.count(where: \.status.isSuccessful)
    }

    var allCancelled: Bool {
        !items.isEmpty && items.allSatisfy { $0.status == .cancelled }
    }

    // MARK: - Enqueue & Process

    @discardableResult
    func enqueue(urls: [URL]) -> [(id: UUID, url: URL)] {
        var entries: [(id: UUID, url: URL)] = []
        for url in urls where !itemURLs.contains(url) {
            let item = FileItem(url: url, status: .processing)
            items.insert(item, at: 0)
            itemURLs.insert(url)
            processingCount += 1
            entries.append((item.id, url))
        }
        return entries
    }

    func process(urls: [URL]) async {
        // Enqueue new URLs, then collect all entries that are still in .processing state
        // (handles both fresh enqueues and URLs already enqueued by handleServiceURLs).
        enqueue(urls: urls)
        var seenIDs = Set<UUID>()
        let taskEntries: [(id: UUID, url: URL)] = urls.compactMap { url in
            guard let item = items.first(where: { $0.url == url }),
                item.status == .processing,
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
            let task = Task { [weak self] in
                let start = ContinuousClock.now

                let status: FileStatus = await withTaskGroup(of: FileStatus.self) { inner in
                    inner.addTask { [weak self] in
                        do {
                            let result = try service.removeQuarantineRecursively(url) { [weak self] processed in
                                guard processed <= 1 || processed % 50 == 0 else { return }
                                Task { @MainActor in
                                    guard let self,
                                        let idx = self.items.firstIndex(where: { $0.id == id }),
                                        self.items[idx].status == .processing
                                    else { return }
                                    var progress = self.items[idx].progress
                                    progress.processed = processed
                                    if processed > progress.total { progress.total = processed }
                                    self.items[idx].progress = progress
                                }
                            }
                            if result.errors.isEmpty {
                                return .clean
                            } else if result.cleaned > 0 {
                                return .partialSuccess(cleaned: result.cleaned, failed: result.errors.count)
                            } else {
                                return .error(result.errors[0].error)
                            }
                        } catch let error as QuarantineError {
                            return .error(error)
                        } catch {
                            return .error(.systemError(url, -1))
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

                if let idx = items.firstIndex(where: { $0.id == id }),
                    items[idx].status == .processing
                {
                    var item = items[idx]
                    item.status = status
                    item.progress.processed = item.progress.total
                    items[idx] = item
                    processingCount -= 1
                }
                activeTasks.removeValue(forKey: id)
            }
            activeTasks[id] = task
            spawnedTasks.append((id, task))
        }

        // Await all spawned tasks so callers can depend on completion.
        for (_, task) in spawnedTasks {
            await task.value
        }
    }

    // MARK: - Cancel

    func cancel(id: UUID) {
        activeTasks[id]?.cancel()
        activeTasks.removeValue(forKey: id)
        if let idx = items.firstIndex(where: { $0.id == id }),
            items[idx].status == .processing
        {
            items[idx].status = .cancelled
            processingCount -= 1
        }
    }

    // MARK: - URL Scheme Parsing

    nonisolated struct IncomingRequest: Sendable {
        let urls: [URL]
        let action: String
        let quitAfter: Bool
    }

    nonisolated private static let allowedActions: Set<String> = ["open", "remove"]

    nonisolated static func parseIncomingURL(_ url: URL) -> IncomingRequest? {
        guard url.scheme == "unquarantine", url.host == "process" else {
            logger.warning("Received unknown URL: \(url)")
            return nil
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        let paths = queryItems.filter { $0.name == "path" }.compactMap(\.value)
        guard !paths.isEmpty else {
            logger.warning("URL missing path parameter(s): \(url)")
            return nil
        }

        let action = queryItems.first(where: { $0.name == "action" })?.value ?? "open"
        guard allowedActions.contains(action) else {
            logger.warning("Invalid action in URL: \(action)")
            return nil
        }

        let quitAfter = queryItems.first(where: { $0.name == "quitAfter" })?.value == "true"

        return IncomingRequest(
            urls: paths.map { URL(fileURLWithPath: $0).standardizedFileURL },
            action: action,
            quitAfter: quitAfter
        )
    }

    // MARK: - Service Mode

    private(set) var serviceMode: ServiceModeCoordinator?

    func handleServiceURLs(_ urls: [URL], action: String, quitAfter: Bool) {
        let entries = enqueue(urls: urls)
        let entryIDs = Set(entries.map(\.id))

        if quitAfter {
            serviceMode = ServiceModeCoordinator(
                entryIDs: entryIDs,
                action: action,
                quitAfter: true
            )
            Task { await NotificationService.requestAuthorization() }
        }

        let coordinator = serviceMode
        let task = Task { [weak self] in
            guard let self else { return }
            await process(urls: urls)

            if let coordinator, coordinator.quitAfter {
                await finishServiceMode(coordinator)
            } else if action == "open" {
                for item in items where entryIDs.contains(item.id) && item.status.isSuccessful {
                    NSWorkspace.shared.open(item.url)
                }
            }
        }
        coordinator?.processingTask = task
    }

    private func finishServiceMode(_ coordinator: ServiceModeCoordinator) async {
        let batchItems = items.filter { coordinator.entryIDs.contains($0.id) }
        let hasErrors = batchItems.contains(where: \.status.hasErrors)

        if hasErrors {
            serviceMode = nil
            return
        }

        if coordinator.action == "open" {
            for item in batchItems where item.status.isSuccessful {
                NSWorkspace.shared.open(item.url)
            }
        }

        serviceMode?.terminationTask?.cancel()
        serviceMode?.terminationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            if coordinator.action != "open" {
                await NotificationService.postResult(items: batchItems)
            }
            if coordinator.quitAfter {
                NSApp.terminate(nil)
            } else {
                self?.serviceMode = nil
            }
        }
    }

    // MARK: - Clear

    func clear() {
        for (_, task) in activeTasks {
            task.cancel()
        }
        activeTasks.removeAll()
        serviceMode?.cancel()
        serviceMode = nil
        items.removeAll()
        itemURLs.removeAll()
        processingCount = 0
    }
}
