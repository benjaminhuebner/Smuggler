import Foundation
import Testing

@testable import Smuggler

@Suite("AppModel — Enqueue")
@MainActor
struct AppModelEnqueueTests {
    @Test("Enqueue adds items with processing status")
    func enqueueAddsItems() {
        let model = makeModel()
        let urls = [URL(filePath: "/tmp/a.app"), URL(filePath: "/tmp/b.app")]

        model.enqueue(urls: urls)

        #expect(model.items.count == 2)
        #expect(model.items.allSatisfy { $0.status == .processing })
    }

    @Test("Enqueue does not duplicate existing URLs")
    func enqueueDeduplicates() {
        let model = makeModel()
        let url = URL(filePath: "/tmp/a.app")

        model.enqueue(urls: [url])
        model.enqueue(urls: [url])

        #expect(model.items.count == 1)
    }

    @Test("Enqueue inserts at the beginning")
    func enqueueInsertsAtBeginning() {
        let model = makeModel()
        model.enqueue(urls: [URL(filePath: "/tmp/first.app")])
        model.enqueue(urls: [URL(filePath: "/tmp/second.app")])

        #expect(model.items.map(\.name) == ["second.app", "first.app"])
    }

    @Test("Clear removes all items")
    func clearRemovesAllItems() {
        let model = makeModel()
        model.enqueue(urls: [URL(filePath: "/tmp/a.app")])

        model.clear()

        #expect(model.items.isEmpty)
    }

    @Test("Enqueue refuses blocked system paths with a terminal error row")
    func enqueueRefusesBlockedPaths() {
        let model = makeModel()
        let blocked = URL(filePath: "/usr/bin/true")

        model.enqueue(urls: [blocked, URL(filePath: "/tmp/a.app")])

        #expect(model.items.count == 2)
        let blockedItem = model.items.first(where: { $0.url == blocked })
        #expect(blockedItem?.status == .error(.blockedPath(blocked)))
        #expect(model.processingCount == 1)
    }

    @Test(
        "Enqueue refuses a folder holding a protected tree and a kernel alias into one",
        arguments: ["/", "/Library/", "/System/Volumes/Data/", "/.nofollow/usr/local/bin/tool"])
    func enqueueRefusesAncestorsAndAliases(path: String) {
        let model = makeModel()
        let url = URL(filePath: path)

        model.enqueue(urls: [url])

        #expect(model.items.map(\.status) == [.error(.blockedPath(url))])
        #expect(model.processingCount == 0)
    }

    @Test("A single batch inserts newest-first like sequential enqueues")
    func enqueueBatchOrdersNewestFirst() {
        let model = makeModel()
        model.enqueue(urls: [URL(filePath: "/tmp/first.app"), URL(filePath: "/tmp/second.app")])

        #expect(model.items.map(\.name) == ["second.app", "first.app"])
    }

    @Test("cancel marks a processing item as cancelled")
    func cancelMarksCancelled() throws {
        let model = makeModel()
        let entries = model.enqueue(urls: [URL(filePath: "/tmp/pending.app")])
        let id = try #require(entries.first).id

        #expect(model.isProcessing == true)
        model.cancel(id: id)

        #expect(model.items.map(\.status) == [.cancelled])
        #expect(model.isProcessing == false)
    }

    @Test("A row is stamped as it starts processing, keeps the stamp while it runs and loses it once settled")
    func processingStamp() async throws {
        let model = makeModel()
        let url = URL(filePath: "/tmp/stamped.app")
        let id = try #require(model.enqueue(urls: [url]).first).id
        let started = try #require(model.items.first?.processingSince)

        model.enqueue(urls: [url])
        #expect(model.items.map(\.processingSince) == [started])

        model.cancel(id: id)
        #expect(model.items.map(\.processingSince) == [nil])

        // Past the clock's resolution, so a re-stamp cannot equal the first one.
        try await Task.sleep(for: .milliseconds(1))
        model.enqueue(urls: [url])
        let restarted = try #require(model.items.first?.processingSince)
        #expect(model.items.map(\.id) == [id])
        #expect(restarted > started)
    }

    @Test("A refused path never starts processing and carries no stamp")
    func blockedPathIsNotStamped() {
        let model = makeModel()

        model.enqueue(urls: [URL(filePath: "/usr/bin/true")])

        #expect(model.items.map(\.processingSince) == [nil])
    }
}

@Suite("AppModel — Run progress")
@MainActor
struct AppModelRunProgressTests {
    let sandbox = TestSandbox()

    @Test("A run counts the rows it started and how many of them are done")
    func countsTheRun() throws {
        let model = makeModel()
        let entries = model.enqueue(urls: [sandbox.url(), sandbox.url(), sandbox.url()])
        #expect(model.runProgress == AppModel.RunProgress(done: 0, total: 3))

        model.cancel(id: try #require(entries.first).id)

        #expect(model.runProgress == AppModel.RunProgress(done: 1, total: 3))
    }

    @Test("A drop arriving mid-run joins it, without recounting an in-flight row or a refused path")
    func midRunDropJoins() throws {
        let model = makeModel()
        let first = sandbox.url()
        let second = sandbox.url()
        let entries = model.enqueue(urls: [first, second])

        model.enqueue(urls: [first, URL(filePath: "/usr/bin/true"), sandbox.url()])
        #expect(model.runProgress == AppModel.RunProgress(done: 0, total: 3))

        // A finished row dropped again re-enters the run instead of counting as a
        // second item: the count stays with the rows it sums up.
        model.cancel(id: try #require(entries.first { $0.url == second }).id)
        #expect(model.runProgress == AppModel.RunProgress(done: 1, total: 3))
        model.enqueue(urls: [second])
        #expect(model.runProgress == AppModel.RunProgress(done: 0, total: 3))
    }

    @Test("A finished run keeps its count for the landing, and the next drop starts a run of its own")
    func idleDropStartsNewRun() async throws {
        let model = makeModel()
        await model.process(urls: [try sandbox.file(), try sandbox.file(), try sandbox.file()])
        #expect(model.runProgress == AppModel.RunProgress(done: 3, total: 3))

        model.enqueue(urls: [sandbox.url(), sandbox.url()])

        #expect(model.runProgress == AppModel.RunProgress(done: 0, total: 2))
    }

    @Test("A run of one item has nothing to count")
    func singleItemRunHasNoCount() {
        let model = makeModel()

        model.enqueue(urls: [sandbox.url()])

        #expect(model.runProgress == nil)
    }

    @Test("Clear ends the run")
    func clearEndsTheRun() {
        let model = makeModel()
        model.enqueue(urls: [sandbox.url(), sandbox.url()])

        model.clear()

        #expect(model.runTotal == 0)
        #expect(model.runProgress == nil)
    }
}

@Suite("AppModel — Processing")
@MainActor
struct AppModelProcessingTests {
    let sandbox = TestSandbox()

    @Test("Cancel All reaches rows enqueued before their tasks exist")
    func cancelAllReachesTasklessRows() {
        let model = makeModel()
        let url = sandbox.url()

        model.enqueue(urls: [url])
        #expect(model.isProcessing)

        model.cancelAll()

        #expect(model.items.first?.status == .cancelled)
        #expect(!model.isProcessing)
    }

    @Test("process removes quarantine and marks the item clean")
    func processMarksClean() async throws {
        let url = try sandbox.file(quarantined: true)
        let model = makeModel()

        await model.process(urls: [url])

        #expect(model.items.map(\.status) == [.clean])
        #expect(model.isProcessing == false)
        #expect(model.items.freedCount == 1)
    }

    @Test("File without quarantine attribute maps to alreadyClean, not clean")
    func processWithoutQuarantineMapsToAlreadyClean() async throws {
        let url = try sandbox.file()
        let model = makeModel()

        await model.process(urls: [url])

        #expect(model.items.map(\.status) == [.alreadyClean])
        #expect(model.items.first?.status.isSuccessful == true)
    }

    @Test("Partial success carries the failing files, not just a count")
    func partialSuccessCarriesFailingFiles() async throws {
        let dir = try sandbox.directory()
        try sandbox.file("fine", in: dir, quarantined: true)
        let locked = try sandbox.file("locked", in: dir, quarantined: true)
        try sandbox.lock(locked)

        let model = makeModel()
        await model.process(urls: [dir])

        let item = try #require(model.items.first)
        guard case .partialSuccess(let cleaned, let errors) = item.status else {
            Issue.record("Expected partialSuccess, got \(item.status)")
            return
        }
        #expect(cleaned == 1)
        #expect(errors.map(\.url.lastPathComponent) == ["locked"])
    }

    @Test("Duplicate URLs in one batch produce a single item")
    func processDeduplicatesBatch() async throws {
        let url = try sandbox.file(quarantined: true)
        let model = makeModel()

        await model.process(urls: [url, url])

        #expect(model.items.map(\.status) == [.clean])
    }

    @Test("A failed file can be re-dropped and is re-processed in place")
    func redropAfterFailureReprocesses() async throws {
        let name = UUID().uuidString
        let url = sandbox.url(name)
        let model = makeModel()

        await model.process(urls: [url])
        #expect(model.items.count == 1)
        let failed = try #require(model.items.first)
        #expect(failed.status.hasErrors)

        try sandbox.file(name, quarantined: true)

        await model.process(urls: [url])
        #expect(model.items.map(\.id) == [failed.id])
        #expect(model.items.first?.status == .clean)
    }

    @Test("A walk that outlives the timeout yields a timeout row")
    func processAppliesTimeout() async throws {
        let dir = try sandbox.directory(files: 1)

        let model = makeModel(processingTimeout: .zero)
        await model.process(urls: [dir])

        #expect(model.items.first?.status == .error(.timeout(dir)))
        #expect(model.isProcessing == false)
    }

    @Test("A walk's time limit starts when it gets a thread, not when it was queued")
    func timeoutStartsWithTheWalk() async throws {
        let dir = try sandbox.directory(files: 3, quarantined: true)
        let executor = GatedExecutor()
        let model = makeModel(processingTimeout: .milliseconds(250), walkExecutor: executor)

        let run = Task { await model.process(urls: [dir]) }
        try await waitUntil { executor.receivedJobs == 1 }
        // Queued well past the limit: a clock started at spawn would already have run
        // out, and the walk would stop before its first file.
        try await Task.sleep(for: .milliseconds(500))
        executor.open()
        await run.value

        #expect(model.items.map(\.status) == [.clean])
    }

    @Test("A cancel during the minimum hold stops the run before its walk begins")
    func cancelDuringHoldLeavesQuarantine() async throws {
        let url = try sandbox.file(quarantined: true)
        let executor = GatedExecutor()
        executor.open()
        let model = makeModel(minimumProcessingDuration: .seconds(5), walkExecutor: executor)

        let run = Task { await model.process(urls: [url]) }
        try await waitUntil { model.isProcessing }
        let id = try #require(model.items.first?.id)
        model.cancel(id: id)
        await run.value

        #expect(model.items.map(\.status) == [.cancelled])
        #expect(model.isProcessing == false)
        #expect(executor.receivedJobs == 0)
        #expect(hasQuarantine(url))
    }

    @Test("A cancelled run draining after a re-drop must not clobber the new run")
    func cancelledRunDoesNotClobberRedrop() async throws {
        let url = try sandbox.file(quarantined: true)
        let executor = GatedExecutor()
        let model = makeModel(walkExecutor: executor)

        let firstRun = Task { await model.process(urls: [url]) }
        // Handed off but held, so the cancel lands inside the walk and the run
        // drains with a stale result instead of stopping in its hold.
        try await waitUntil { executor.receivedJobs == 1 }
        let id = try #require(model.items.first?.id)
        model.cancel(id: id)
        #expect(model.items.map(\.status) == [.cancelled])

        // Opened once the cancelled run has drained, so its stale result always meets
        // the re-drop's run. The timer only keeps a regression from hanging the suite.
        Task {
            await firstRun.value
            executor.open()
        }
        let failsafe = Task {
            try? await Task.sleep(for: .seconds(5))
            executor.open()
        }
        defer { failsafe.cancel() }
        // Called directly, not through a Task: the re-drop registers its run in this
        // main-actor turn, before the cancelled run can resume.
        await model.process(urls: [url])

        #expect(model.items.map(\.status) == [.clean])
        #expect(model.isProcessing == false)
        #expect(!hasQuarantine(url))
    }

    @Test("Cancel All during the hold cancels every in-flight item and leaves the files untouched")
    func cancelAllCancelsInFlightItems() async throws {
        let url1 = try sandbox.file(quarantined: true)
        let url2 = try sandbox.file(quarantined: true)
        let executor = GatedExecutor()
        executor.open()
        let model = makeModel(minimumProcessingDuration: .seconds(5), walkExecutor: executor)

        let run = Task { await model.process(urls: [url1, url2]) }
        try await waitUntil { model.items.count == 2 && model.isProcessing }
        model.cancelAll()
        await run.value

        #expect(model.items.map(\.status) == [.cancelled, .cancelled])
        #expect(model.isProcessing == false)
        #expect(executor.receivedJobs == 0)
        #expect(hasQuarantine(url1))
        #expect(hasQuarantine(url2))
    }

    @Test("Cancel All settles only in-flight rows and frees their URLs for a re-drop")
    func cancelAllSettlesOnlyInFlightRows() throws {
        let model = makeModel()
        let blocked = URL(filePath: "/usr/bin/true")
        let first = sandbox.url()
        let second = sandbox.url()
        let third = sandbox.url()
        model.enqueue(urls: [blocked, first])
        model.enqueue(urls: [second, third])
        let secondID = try #require(model.items.first { $0.url == second }).id
        model.cancel(id: secondID)

        model.cancelAll()

        #expect(model.items.map(\.url) == [third, second, first, blocked])
        #expect(model.items.map(\.status) == [.cancelled, .cancelled, .cancelled, .error(.blockedPath(blocked))])
        #expect(model.processingCount == 0)

        let firstID = try #require(model.items.first { $0.url == first }).id
        #expect(model.enqueue(urls: [first]).map(\.id) == [firstID])
        #expect(model.items.first { $0.url == first }?.status == .processing)
        #expect(model.isProcessing)
    }
}
