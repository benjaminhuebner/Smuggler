import Foundation
import Testing

@testable import Smuggler

@Suite("Scope guard")
struct ScopeGuardTests {
    @Test(
        "Blocked system paths are refused",
        arguments: [
            "/System/Library/CoreServices/Finder.app",
            "/Library/LaunchDaemons/com.example.plist",
            "/Library/LaunchAgents/com.example.plist",
            "/Library/Extensions/Foo.kext",
            "/usr/bin/true",
            "/bin/ls",
            "/sbin/mount",
        ])
    func blocksSystemPaths(path: String) {
        #expect(QuarantineService.isBlockedPath(URL(filePath: path)))
    }

    @Test(
        "Differently-cased blocked paths are refused (case-insensitive default volume)",
        arguments: [
            "/system/Library/CoreServices/Finder.app",
            "/library/launchdaemons/com.example.plist",
            "/USR/bin/true",
        ])
    func blocksCaseVariants(path: String) {
        #expect(QuarantineService.isBlockedPath(URL(filePath: path)))
    }

    @Test("Regular user paths are allowed")
    func allowsUserPaths() {
        #expect(!QuarantineService.isBlockedPath(URL(filePath: "/tmp/MyApp.app")))
        #expect(!QuarantineService.isBlockedPath(URL(filePath: "/Users/me/Downloads/a.dmg")))
        #expect(!QuarantineService.isBlockedPath(URL(filePath: "/Library/Fonts/MyFont.ttf")))
    }

    @Test("A symlink into a blocked tree is refused")
    func blocksSymlinkAlias() throws {
        let link = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: URL(filePath: "/usr/bin"))
        defer { try? FileManager.default.removeItem(at: link) }

        #expect(QuarantineService.isBlockedPath(link.appending(path: "true")))
    }

    @Test("Lexical prefix check refuses blocked paths and normalizes parent traversal")
    func lexicalCheckRefusesBlockedPrefixes() {
        #expect(QuarantineService.hasBlockedPrefix(URL(filePath: "/System/Library/Foo.kext")))
        #expect(QuarantineService.hasBlockedPrefix(URL(filePath: "/USR/bin/true")))
        #expect(QuarantineService.hasBlockedPrefix(URL(filePath: "/tmp/../usr/bin/true")))
        #expect(!QuarantineService.hasBlockedPrefix(URL(filePath: "/System/../tmp/foo")))
        #expect(!QuarantineService.hasBlockedPrefix(URL(filePath: "/Users/me/Downloads/a.dmg")))
    }

    @Test("A user path in its Data-volume firmlink form is allowed")
    func allowsDataVolumeFirmlinkForm() {
        let download = URL(filePath: "/System/Volumes/Data/Users/me/Downloads/a.dmg")
        #expect(!QuarantineService.hasBlockedPrefix(download))
        #expect(!QuarantineService.isBlockedPath(download))

        // The firmlink cuts both ways: /System/Volumes/Data/usr is /usr.
        #expect(QuarantineService.hasBlockedPrefix(URL(filePath: "/System/Volumes/Data/usr/local/bin/tool")))
        // The bare mount point stays refused — that is the whole volume.
        #expect(QuarantineService.hasBlockedPrefix(URL(filePath: "/System/Volumes/Data")))
    }

    @Test("A symlink alias passes the lexical check but is caught by the resolved check")
    func symlinkAliasFallsToResolvedCheck() throws {
        let link = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: URL(filePath: "/usr/bin"))
        defer { try? FileManager.default.removeItem(at: link) }

        #expect(!QuarantineService.hasBlockedPrefix(link.appending(path: "true")))
        #expect(QuarantineService.isBlockedPath(link.appending(path: "true")))
    }

    @Test("Recursive removal refuses blocked paths as defense in depth")
    func recursiveRemovalThrowsOnBlockedPath() {
        let blocked = URL(filePath: "/usr/bin/true")
        #expect(throws: QuarantineError.blockedPath(blocked)) {
            try QuarantineService().removeQuarantineRecursively(blocked)
        }
    }
}

@Suite("AppModel — Enqueue")
@MainActor
struct AppModelEnqueueTests {
    @Test("Enqueue adds items with processing status")
    func enqueueAddsItems() {
        let model = AppModel()
        let urls = [URL(filePath: "/tmp/a.app"), URL(filePath: "/tmp/b.app")]

        model.enqueue(urls: urls)

        #expect(model.items.count == 2)
        #expect(model.items.allSatisfy { $0.status == .processing })
    }

    @Test("Enqueue does not duplicate existing URLs")
    func enqueueDeduplicates() {
        let model = AppModel()
        let url = URL(filePath: "/tmp/a.app")

        model.enqueue(urls: [url])
        model.enqueue(urls: [url])

        #expect(model.items.count == 1)
    }

    @Test("Enqueue inserts at the beginning")
    func enqueueInsertsAtBeginning() {
        let model = AppModel()
        model.enqueue(urls: [URL(filePath: "/tmp/first.app")])
        model.enqueue(urls: [URL(filePath: "/tmp/second.app")])

        #expect(model.items[0].name == "second.app")
        #expect(model.items[1].name == "first.app")
    }

    @Test("Clear removes all items")
    func clearRemovesAllItems() {
        let model = AppModel()
        model.enqueue(urls: [URL(filePath: "/tmp/a.app")])

        model.clear()

        #expect(model.items.isEmpty)
    }

    @Test("Enqueue refuses blocked system paths with a terminal error row")
    func enqueueRefusesBlockedPaths() {
        let model = AppModel()
        let blocked = URL(filePath: "/usr/bin/true")

        model.enqueue(urls: [blocked, URL(filePath: "/tmp/a.app")])

        #expect(model.items.count == 2)
        let blockedItem = model.items.first(where: { $0.url == blocked })
        #expect(blockedItem?.status == .error(.blockedPath(blocked)))
        #expect(model.processingCount == 1)
    }

    @Test("A single batch inserts newest-first like sequential enqueues")
    func enqueueBatchOrdersNewestFirst() {
        let model = AppModel()
        model.enqueue(urls: [URL(filePath: "/tmp/first.app"), URL(filePath: "/tmp/second.app")])

        #expect(model.items.map(\.name) == ["second.app", "first.app"])
    }

    @Test("cancel marks a processing item as cancelled")
    func cancelMarksCancelled() {
        let model = AppModel()
        let entries = model.enqueue(urls: [URL(filePath: "/tmp/pending.app")])
        let id = entries[0].id

        #expect(model.isProcessing == true)
        model.cancel(id: id)

        #expect(model.items[0].status == .cancelled)
        #expect(model.isProcessing == false)
        #expect(model.allCancelled == true)
    }
}

@Suite("AppModel — Processing")
@MainActor
struct AppModelProcessingTests {
    // `authorize` is always stubbed: its real implementation raises the system
    // notification prompt on the machine running the suite.
    private func makeModel(
        minimumProcessingDuration: Duration = .zero,
        processingTimeout: Duration = .seconds(30),
        confirm: AppModel.ConfirmHandler? = nil,
        open: AppModel.OpenHandler? = nil,
        terminate: AppModel.TerminateHandler? = nil,
        notify: AppModel.NotifyHandler? = nil,
        tokenStore: ServiceTokenStore = ServiceTokenStore()
    ) -> AppModel {
        AppModel(
            minimumProcessingDuration: minimumProcessingDuration,
            processingTimeout: processingTimeout,
            confirm: confirm,
            open: open,
            terminate: terminate,
            authorize: {},
            notify: notify,
            tokenStore: tokenStore
        )
    }

    @Test("Cancel All reaches rows enqueued before their tasks exist")
    func cancelAllReachesTasklessRows() {
        let model = makeModel(minimumProcessingDuration: .zero)
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

        model.enqueue(urls: [url])
        #expect(model.isProcessing)

        model.cancelAll()

        #expect(model.items[0].status == .cancelled)
        #expect(!model.isProcessing)
    }

    private func makeQuarantinedFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try "test".write(to: url, atomically: true, encoding: .utf8)
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            let value = "0001;00000000;Test;"
            _ = value.withCString { setxattr(path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
        }
        return url
    }

    @Test("process removes quarantine and marks the item clean")
    func processMarksClean() async throws {
        let url = try makeQuarantinedFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = makeModel(minimumProcessingDuration: .zero)

        await model.process(urls: [url])

        #expect(model.items.count == 1)
        #expect(model.items[0].status == .clean)
        #expect(model.isProcessing == false)
        #expect(model.cleanedCount == 1)
    }

    @Test("File without quarantine attribute maps to alreadyClean, not clean")
    func processWithoutQuarantineMapsToAlreadyClean() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try "test".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = makeModel(minimumProcessingDuration: .zero)

        await model.process(urls: [url])

        #expect(model.items.count == 1)
        #expect(model.items[0].status == .alreadyClean)
        #expect(model.items[0].status.isSuccessful)
    }

    @Test("Partial success carries the failing files, not just a count")
    func partialSuccessCarriesFailingFiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: dir.appending(path: "locked").path())
            try? FileManager.default.removeItem(at: dir)
        }

        func writeQuarantined(_ name: String) throws -> URL {
            let url = dir.appending(path: name)
            try "test".write(to: url, atomically: true, encoding: .utf8)
            url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return }
                let value = "0001;00000000;Test;"
                _ = value.withCString { setxattr(path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
            }
            return url
        }
        _ = try writeQuarantined("fine")
        let locked = try writeQuarantined("locked")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: locked.path(percentEncoded: false))

        let model = makeModel(minimumProcessingDuration: .zero)
        await model.process(urls: [dir])

        guard case .partialSuccess(let cleaned, let errors) = model.items[0].status else {
            Issue.record("Expected partialSuccess, got \(model.items[0].status)")
            return
        }
        #expect(cleaned == 1)
        #expect(errors.count == 1)
        #expect(errors[0].url.lastPathComponent == "locked")
    }

    @Test("Duplicate URLs in one batch produce a single item")
    func processDeduplicatesBatch() async throws {
        let url = try makeQuarantinedFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = makeModel(minimumProcessingDuration: .zero)

        await model.process(urls: [url, url])

        #expect(model.items.count == 1)
        #expect(model.items[0].status == .clean)
    }

    // Regression: when the app is already open, the Services / Finder path passes
    // quitAfter == false. The processing task must still run.
    @Test("handleServiceURLs processes items when the app is already open")
    func serviceURLsProcessWhenAlreadyOpen() async throws {
        let url = try makeQuarantinedFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = makeModel(minimumProcessingDuration: .zero)

        model.handleServiceURLs([url], action: .remove, quitAfter: false)

        try await waitUntil { !model.items.isEmpty && model.items[0].status != .processing }
        #expect(model.items[0].status == .clean)
        #expect(model.isProcessing == false)
    }

    @MainActor
    private final class HandlerRecorder {
        var confirmedURLs: [URL] = []
        var confirmedKinds: [AppModel.ConfirmKind] = []
        var openedURLs: [URL] = []
        var terminated = false
        var terminateCount = 0
        var notifiedBatches: [[FileItem]] = []
        var statusAtTerminate: FileStatus?
        var injectedSecondBatch = false
    }

    // Lets handler closures reach the model they are installed on, since the
    // model cannot capture itself during its own init.
    @MainActor
    private final class ModelBox {
        var model: AppModel?
    }

    @Test("quitAfter service flow confirms, opens, and terminates")
    func serviceQuitAfterPathRunsToTermination() async throws {
        let url = try makeQuarantinedFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = HandlerRecorder()
        let model = makeModel(
            minimumProcessingDuration: .zero,
            confirm: { urls, kind in
                recorder.confirmedURLs = urls
                recorder.confirmedKinds.append(kind)
                return true
            },
            open: { recorder.openedURLs = $0 },
            terminate: { recorder.terminated = true }
        )

        model.handleServiceURLs([url], action: .open, quitAfter: true)

        try await waitUntil { recorder.terminated }
        #expect(model.items.first?.status == .clean)
        #expect(recorder.confirmedURLs == [url])
        #expect(recorder.confirmedKinds == [.open])
        #expect(recorder.openedURLs == [url])
    }

    @Test("quitAfter service flow does not open when confirmation is declined")
    func serviceQuitAfterPathRespectsDeclinedConfirmation() async throws {
        let url = try makeQuarantinedFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = HandlerRecorder()
        let model = makeModel(
            minimumProcessingDuration: .zero,
            confirm: { _, _ in false },
            open: { recorder.openedURLs = $0 },
            terminate: { recorder.terminated = true }
        )

        model.handleServiceURLs([url], action: .open, quitAfter: true)

        try await waitUntil { recorder.terminated }
        #expect(recorder.openedURLs.isEmpty)
    }

    private func makeTokenStore() throws -> ServiceTokenStore {
        let container = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        return ServiceTokenStore(containerURL: container)
    }

    @Test("URL remove request without a token asks for confirmation")
    func urlRemoveWithoutTokenAsksConfirmation() async throws {
        let url = try makeQuarantinedFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = HandlerRecorder()
        let model = makeModel(
            minimumProcessingDuration: .zero,
            confirm: { urls, kind in
                recorder.confirmedURLs = urls
                recorder.confirmedKinds.append(kind)
                return true
            },
            tokenStore: try makeTokenStore()
        )

        model.handleURLRequest(
            urls: [url], removableURLs: [url], action: .remove, quitAfter: false, trusted: false)

        try await waitUntil { !model.items.isEmpty && model.items[0].status != .processing }
        #expect(recorder.confirmedKinds == [.remove])
        #expect(recorder.confirmedURLs == [url])
        #expect(model.items[0].status == .clean)
    }

    @Test("Declined confirmation processes nothing and quits in headless mode")
    func urlRemoveDeclinedProcessesNothing() async throws {
        let url = try makeQuarantinedFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = HandlerRecorder()
        let model = makeModel(
            minimumProcessingDuration: .zero,
            confirm: { _, _ in false },
            terminate: { recorder.terminateCount += 1 },
            tokenStore: try makeTokenStore()
        )

        model.handleURLRequest(
            urls: [url], removableURLs: [url], action: .remove, quitAfter: true, trusted: false)

        try await waitUntil { recorder.terminateCount > 0 }
        #expect(model.items.isEmpty)
    }

    @Test("URL remove request with a valid token runs without confirmation")
    func urlRemoveWithValidTokenIsSilent() async throws {
        let url = try makeQuarantinedFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = HandlerRecorder()
        let store = try makeTokenStore()
        let token = try #require(store.issueToken())
        let model = makeModel(
            minimumProcessingDuration: .zero,
            confirm: { _, kind in
                recorder.confirmedKinds.append(kind)
                return true
            },
            tokenStore: store
        )

        await model.handleIncomingRequest(
            IncomingRequest(urls: [url], action: .remove, quitAfter: false, token: token),
            isColdLaunch: false
        ).value

        try await waitUntil { !model.items.isEmpty && model.items[0].status != .processing }
        #expect(recorder.confirmedKinds.isEmpty)
        #expect(model.items[0].status == .clean)
    }

    @Test("URL remove request with an invalid token asks for confirmation")
    func urlRemoveWithInvalidTokenAsksConfirmation() async throws {
        let url = try makeQuarantinedFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = HandlerRecorder()
        let model = makeModel(
            minimumProcessingDuration: .zero,
            confirm: { _, kind in
                recorder.confirmedKinds.append(kind)
                return false
            },
            tokenStore: try makeTokenStore()
        )

        await model.handleIncomingRequest(
            IncomingRequest(urls: [url], action: .remove, quitAfter: false, token: UUID().uuidString),
            isColdLaunch: false
        ).value

        #expect(recorder.confirmedKinds == [.remove])
        #expect(model.items.isEmpty)
    }

    @Test("Blocked-only service request shows error rows and notifies without quitting")
    func blockedRequestProducesFeedback() async throws {
        let recorder = HandlerRecorder()
        let model = makeModel(
            minimumProcessingDuration: .zero,
            terminate: { recorder.terminateCount += 1 },
            notify: { recorder.notifiedBatches.append($0) }
        )
        let blocked = URL(filePath: "/System/Library/CoreServices/Finder.app")

        model.handleServiceURLs([blocked], action: .remove, quitAfter: true)

        try await waitUntil { !recorder.notifiedBatches.isEmpty }
        #expect(model.items.count == 1)
        #expect(model.items[0].status == .error(.blockedPath(blocked)))
        #expect(recorder.notifiedBatches.first?.count == 1)
        #expect(recorder.terminateCount == 0)
    }

    @Test("Mixed request reports blocked paths instead of silently dropping them")
    func mixedRequestReportsBlockedPaths() async throws {
        let url = try makeQuarantinedFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let blocked = URL(filePath: "/usr/bin/true")

        let recorder = HandlerRecorder()
        let model = makeModel(
            minimumProcessingDuration: .zero,
            terminate: { recorder.terminateCount += 1 },
            notify: { recorder.notifiedBatches.append($0) }
        )

        model.handleServiceURLs([url, blocked], action: .remove, quitAfter: true)

        try await waitUntil { !recorder.notifiedBatches.isEmpty }
        let batch = try #require(recorder.notifiedBatches.first)
        #expect(batch.contains(where: { $0.status == .error(.blockedPath(blocked)) }))
        #expect(batch.contains(where: { $0.status == .clean }))
        #expect(recorder.terminateCount == 0)
    }

    @Test("Untrusted open request asks before any quarantine is removed")
    func urlOpenWithoutTokenGatesProcessing() async throws {
        let url = try makeQuarantinedFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = HandlerRecorder()
        let model = makeModel(
            minimumProcessingDuration: .zero,
            confirm: { urls, kind in
                recorder.confirmedURLs = urls
                recorder.confirmedKinds.append(kind)
                return false
            },
            tokenStore: try makeTokenStore()
        )

        model.handleURLRequest(
            urls: [url], removableURLs: [url], action: .open, quitAfter: false, trusted: false)

        #expect(recorder.confirmedKinds == [.remove])
        #expect(recorder.confirmedURLs == [url])
        #expect(model.items.isEmpty)
        #expect(QuarantineService().hasQuarantine(url))
    }

    @Test("Untrusted open request processes and opens only after approval")
    func urlOpenWithoutTokenRunsAfterApproval() async throws {
        let url = try makeQuarantinedFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = HandlerRecorder()
        let model = makeModel(
            minimumProcessingDuration: .zero,
            confirm: { _, kind in
                recorder.confirmedKinds.append(kind)
                return true
            },
            open: { recorder.openedURLs = $0 },
            tokenStore: try makeTokenStore()
        )

        model.handleURLRequest(
            urls: [url], removableURLs: [url], action: .open, quitAfter: false, trusted: false)

        try await waitUntil { recorder.openedURLs == [url] }
        #expect(recorder.confirmedKinds == [.remove, .open])
        #expect(model.items.first?.status == .clean)
    }

    @Test("Service-mode batch with errors posts the failure notification")
    func serviceModeErrorPostsNotification() async throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

        let recorder = HandlerRecorder()
        let model = makeModel(
            minimumProcessingDuration: .zero,
            terminate: { recorder.terminateCount += 1 },
            notify: { recorder.notifiedBatches.append($0) }
        )

        model.handleServiceURLs([missing], action: .remove, quitAfter: true)

        try await waitUntil { !recorder.notifiedBatches.isEmpty }
        #expect(model.serviceMode == nil)
        #expect(recorder.terminateCount == 0)
        let batch = try #require(recorder.notifiedBatches.first)
        #expect(batch.count == 1)
        #expect(batch[0].status.hasErrors)
    }

    @Test("A failed file can be re-dropped and is re-processed in place")
    func redropAfterFailureReprocesses() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let model = makeModel(minimumProcessingDuration: .zero)

        await model.process(urls: [url])
        #expect(model.items.count == 1)
        #expect(model.items[0].status.hasErrors)
        let originalID = model.items[0].id

        try "test".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            let value = "0001;00000000;Test;"
            _ = value.withCString { setxattr(path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
        }

        await model.process(urls: [url])
        #expect(model.items.count == 1)
        #expect(model.items[0].id == originalID)
        #expect(model.items[0].status == .clean)
    }

    @Test("Rapid double service invocation terminates exactly once")
    func doubleServiceInvocationSupersedesFirstBatch() async throws {
        let url1 = try makeQuarantinedFile()
        let url2 = try makeQuarantinedFile()
        defer {
            try? FileManager.default.removeItem(at: url1)
            try? FileManager.default.removeItem(at: url2)
        }

        let recorder = HandlerRecorder()
        let model = makeModel(
            minimumProcessingDuration: .zero,
            terminate: { recorder.terminateCount += 1 },
            notify: { recorder.notifiedBatches.append($0) }
        )

        model.handleServiceURLs([url1], action: .remove, quitAfter: true)
        let firstCoordinator = try #require(model.serviceMode)
        model.handleServiceURLs([url2], action: .remove, quitAfter: true)
        let secondCoordinator = try #require(model.serviceMode)
        #expect(firstCoordinator !== secondCoordinator)

        try await waitUntil { recorder.terminateCount > 0 }
        // Give a stale termination from the superseded batch a chance to fire — it must not.
        try await Task.sleep(for: .milliseconds(1200))
        #expect(recorder.terminateCount == 1)
    }

    @Test("A batch superseded during the open confirmation must not terminate the successor mid-batch")
    func supersededBatchDoesNotTerminateSuccessor() async throws {
        let url1 = try makeQuarantinedFile()
        let url2 = try makeQuarantinedFile()
        defer {
            try? FileManager.default.removeItem(at: url1)
            try? FileManager.default.removeItem(at: url2)
        }

        let box = ModelBox()
        let recorder = HandlerRecorder()
        // Long enough that a stale 800ms termination timer from batch 1 would
        // fire while batch 2 is still processing.
        let model = makeModel(
            minimumProcessingDuration: .milliseconds(1200),
            confirm: { _, kind in
                // Stand-in for the nested modal run loop: a second batch
                // arrives while the first is suspended in its confirmation.
                if kind == .open, recorder.injectedSecondBatch == false {
                    recorder.injectedSecondBatch = true
                    box.model?.handleServiceURLs([url2], action: .remove, quitAfter: true)
                }
                return true
            },
            open: { recorder.openedURLs = $0 },
            terminate: {
                recorder.terminateCount += 1
                recorder.statusAtTerminate = box.model?.items.first(where: { $0.url == url2 })?.status
            },
            notify: { recorder.notifiedBatches.append($0) }
        )
        box.model = model

        model.handleServiceURLs([url1], action: .open, quitAfter: true)

        try await waitUntil(timeout: .seconds(10)) { recorder.terminateCount > 0 }
        #expect(recorder.statusAtTerminate == .clean)
        #expect(recorder.terminateCount == 1)
    }

    @Test("A batch superseded during the error notification must not orphan the successor")
    func supersededErrorBatchDoesNotOrphanSuccessor() async throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url2 = try makeQuarantinedFile()
        defer { try? FileManager.default.removeItem(at: url2) }

        let recorder = HandlerRecorder()
        let model = makeModel(
            minimumProcessingDuration: .milliseconds(500),
            terminate: { recorder.terminateCount += 1 },
            notify: { batch in
                recorder.notifiedBatches.append(batch)
                // Hold the error notification open so the second batch can
                // supersede the first one mid-suspension.
                if recorder.notifiedBatches.count == 1 {
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
        )

        model.handleServiceURLs([missing], action: .remove, quitAfter: true)
        try await waitUntil { !recorder.notifiedBatches.isEmpty }
        model.handleServiceURLs([url2], action: .remove, quitAfter: true)

        try await waitUntil(timeout: .seconds(10)) { recorder.terminateCount > 0 }
        #expect(recorder.terminateCount == 1)
    }

    @Test("A warm batch arriving during a pending quit takes over the session")
    func warmBatchCancelsPendingQuit() async throws {
        let url1 = try makeQuarantinedFile()
        let url2 = try makeQuarantinedFile()
        defer {
            try? FileManager.default.removeItem(at: url1)
            try? FileManager.default.removeItem(at: url2)
        }

        let recorder = HandlerRecorder()
        let model = makeModel(
            minimumProcessingDuration: .zero,
            terminate: { recorder.terminateCount += 1 },
            notify: { recorder.notifiedBatches.append($0) }
        )

        model.handleServiceURLs([url1], action: .remove, quitAfter: true)
        try await waitUntil { model.items.first?.status == .clean }
        model.handleServiceURLs([url2], action: .remove, quitAfter: false)

        #expect(model.serviceMode == nil)
        try await waitUntil { model.items.count == 2 && model.items.allSatisfy { $0.status == .clean } }
        // Give the stale 800ms termination from batch 1 a chance to fire — it must not.
        try await Task.sleep(for: .milliseconds(1000))
        #expect(recorder.terminateCount == 0)
        // The takeover cancels the quit, not the finished batch's notification.
        #expect(recorder.notifiedBatches.count == 1)
        #expect(recorder.notifiedBatches.first?.contains { $0.url == url1 } == true)
    }

    @Test("A warm batch during a quitAfter batch's processing keeps its notification")
    func warmTakeoverDuringProcessingKeepsNotification() async throws {
        let url1 = try makeQuarantinedFile()
        let url2 = try makeQuarantinedFile()
        defer {
            try? FileManager.default.removeItem(at: url1)
            try? FileManager.default.removeItem(at: url2)
        }

        let recorder = HandlerRecorder()
        let model = makeModel(
            minimumProcessingDuration: .milliseconds(300),
            terminate: { recorder.terminateCount += 1 },
            notify: { recorder.notifiedBatches.append($0) }
        )

        model.handleServiceURLs([url1], action: .remove, quitAfter: true)
        model.handleServiceURLs([url2], action: .remove, quitAfter: false)
        #expect(model.serviceMode == nil)

        try await waitUntil { !recorder.notifiedBatches.isEmpty }
        #expect(recorder.notifiedBatches.first?.contains { $0.url == url1 } == true)
        try await Task.sleep(for: .milliseconds(1200))
        #expect(recorder.terminateCount == 0)
    }

    @Test("A walk that outlives the timeout yields a timeout row")
    func processAppliesTimeout() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for index in 0..<500 {
            try "x".write(to: dir.appending(path: "f\(index)"), atomically: false, encoding: .utf8)
        }

        let model = makeModel(minimumProcessingDuration: .zero, processingTimeout: .zero)
        await model.process(urls: [dir])

        #expect(model.items.first?.status == .error(.timeout(dir)))
        #expect(model.isProcessing == false)
    }

    @Test("A cancelled run draining after a re-drop must not clobber the new run")
    func cancelledRunDoesNotClobberRedrop() async throws {
        let url = try makeQuarantinedFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = makeModel(minimumProcessingDuration: .milliseconds(400))

        let firstRun = Task { await model.process(urls: [url]) }
        try await waitUntil { model.items.first?.status == .processing }
        // Let the walk finish so the first run parks in its minimum-duration
        // sleep holding a stale .clean result.
        try await Task.sleep(for: .milliseconds(100))

        let id = try #require(model.items.first?.id)
        model.cancel(id: id)
        #expect(model.items.first?.status == .cancelled)

        // Re-drop the same URL while the cancelled run is still draining. The
        // quarantine is already gone, so only a stale write can produce .clean.
        let secondRun = Task { await model.process(urls: [url]) }
        await secondRun.value
        await firstRun.value

        #expect(model.items.count == 1)
        #expect(model.items.first?.status == .alreadyClean)
        #expect(model.isProcessing == false)
    }

    @Test("cancelAll cancels every in-flight item and keeps the rows")
    func cancelAllCancelsInFlightItems() async throws {
        let url1 = try makeQuarantinedFile()
        let url2 = try makeQuarantinedFile()
        defer {
            try? FileManager.default.removeItem(at: url1)
            try? FileManager.default.removeItem(at: url2)
        }
        let model = makeModel(minimumProcessingDuration: .seconds(5))

        let run = Task { await model.process(urls: [url1, url2]) }
        try await waitUntil { model.items.count == 2 && model.isProcessing }
        model.cancelAll()

        #expect(model.items.count == 2)
        #expect(model.items.allSatisfy { $0.status == .cancelled })
        #expect(model.isProcessing == false)
        #expect(model.allCancelled == true)
        await run.value
    }

    @Test("Incoming request drops nonexistent paths without asking for confirmation")
    func incomingRequestDropsNonexistentPaths() async throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let recorder = HandlerRecorder()
        let model = makeModel(
            minimumProcessingDuration: .zero,
            confirm: { _, kind in
                recorder.confirmedKinds.append(kind)
                return true
            },
            tokenStore: try makeTokenStore()
        )

        await model.handleIncomingRequest(
            IncomingRequest(urls: [missing], action: .remove, quitAfter: false, token: nil),
            isColdLaunch: false
        ).value

        #expect(model.items.isEmpty)
        #expect(recorder.confirmedKinds.isEmpty)
    }

    @Test("Incoming request keeps blocked paths as refusal rows even when nonexistent")
    func incomingRequestKeepsBlockedPaths() async throws {
        let blocked = URL(filePath: "/usr/bin/\(UUID().uuidString)")
        let recorder = HandlerRecorder()
        let model = makeModel(
            minimumProcessingDuration: .zero,
            confirm: { _, kind in
                recorder.confirmedKinds.append(kind)
                return true
            },
            tokenStore: try makeTokenStore()
        )

        await model.handleIncomingRequest(
            IncomingRequest(urls: [blocked], action: .remove, quitAfter: false, token: nil),
            isColdLaunch: false
        ).value

        #expect(model.items.first?.status == .error(.blockedPath(blocked)))
        #expect(recorder.confirmedKinds.isEmpty)
    }

    @Test("Rapid incoming requests apply in arrival order")
    func incomingRequestsKeepArrivalOrder() async throws {
        let urlA = try makeQuarantinedFile()
        let urlB = try makeQuarantinedFile()
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }
        let model = makeModel(
            minimumProcessingDuration: .zero,
            confirm: { _, _ in true },
            tokenStore: try makeTokenStore()
        )

        let first = model.handleIncomingRequest(
            IncomingRequest(urls: [urlA], action: .remove, quitAfter: false, token: nil),
            isColdLaunch: false
        )
        let second = model.handleIncomingRequest(
            IncomingRequest(urls: [urlB], action: .remove, quitAfter: false, token: nil),
            isColdLaunch: false
        )
        await first.value
        await second.value

        #expect(model.items.map(\.url) == [urlB, urlA])
        try await waitUntil { model.items.allSatisfy { $0.status != .processing } }
    }

    @Test("quitAfter from a warm request does not enter service mode or terminate")
    func incomingRequestSquashesQuitAfterWhenWarm() async throws {
        let url = try makeQuarantinedFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try makeTokenStore()
        let token = try #require(store.issueToken())
        let recorder = HandlerRecorder()
        let model = makeModel(
            minimumProcessingDuration: .zero,
            confirm: { _, kind in
                recorder.confirmedKinds.append(kind)
                return true
            },
            terminate: { recorder.terminateCount += 1 },
            tokenStore: store
        )

        await model.handleIncomingRequest(
            IncomingRequest(urls: [url], action: .remove, quitAfter: true, token: token),
            isColdLaunch: false
        ).value

        #expect(model.serviceMode == nil)
        try await waitUntil { model.items.first?.status == .clean }
        #expect(recorder.terminateCount == 0)
        #expect(recorder.confirmedKinds.isEmpty)
    }

    @Test("A queued request's token is consumed on arrival, not when the queue drains")
    func incomingRequestConsumesTokenOnArrival() async throws {
        let url = try makeQuarantinedFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try makeTokenStore()
        let token = try #require(store.issueToken())
        let recorder = HandlerRecorder()
        let model = makeModel(
            minimumProcessingDuration: .zero,
            confirm: { _, kind in
                recorder.confirmedKinds.append(kind)
                return true
            },
            tokenStore: store
        )

        // Park the queue behind a slow predecessor so timing is observable.
        model.incomingRequestTask = Task { try? await Task.sleep(for: .milliseconds(200)) }
        let task = model.handleIncomingRequest(
            IncomingRequest(urls: [url], action: .remove, quitAfter: false, token: token),
            isColdLaunch: false
        )

        // Already consumed: presenting the same token again must fail.
        #expect(store.consumeToken(token) == false)
        await task.value
        try await waitUntil { model.items.first?.status == .clean }
        #expect(recorder.confirmedKinds.isEmpty)
    }

    @Test("Clear cancels a queued incoming request before it can run")
    func clearCancelsQueuedIncomingRequest() async throws {
        let url = try makeQuarantinedFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = HandlerRecorder()
        let model = makeModel(
            minimumProcessingDuration: .zero,
            confirm: { _, kind in
                recorder.confirmedKinds.append(kind)
                return true
            },
            tokenStore: try makeTokenStore()
        )

        model.incomingRequestTask = Task { try? await Task.sleep(for: .milliseconds(200)) }
        let task = model.handleIncomingRequest(
            IncomingRequest(urls: [url], action: .remove, quitAfter: false, token: nil),
            isColdLaunch: false
        )
        model.clear()
        await task.value

        #expect(model.items.isEmpty)
        #expect(recorder.confirmedKinds.isEmpty)
    }

    @Test("Clear cancels every queued request, not only the newest")
    func clearCancelsEveryQueuedRequest() async throws {
        let first = try makeQuarantinedFile()
        let second = try makeQuarantinedFile()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let recorder = HandlerRecorder()
        let model = makeModel(
            minimumProcessingDuration: .zero,
            confirm: { _, kind in
                recorder.confirmedKinds.append(kind)
                return true
            },
            tokenStore: try makeTokenStore()
        )

        // Park the chain so both requests are still queued when clear() lands.
        model.incomingRequestTask = Task { try? await Task.sleep(for: .milliseconds(200)) }
        let earlier = model.handleIncomingRequest(
            IncomingRequest(urls: [first], action: .remove, quitAfter: false, token: nil),
            isColdLaunch: false
        )
        let later = model.handleIncomingRequest(
            IncomingRequest(urls: [second], action: .remove, quitAfter: false, token: nil),
            isColdLaunch: false
        )
        model.clear()
        await earlier.value
        await later.value

        #expect(model.items.isEmpty)
        #expect(recorder.confirmedKinds.isEmpty)
    }

    @Test("An empty cold-launch request does not quit while a later request is queued")
    func emptyColdLaunchDefersToQueuedSuccessor() async throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let real = try makeQuarantinedFile()
        defer { try? FileManager.default.removeItem(at: real) }
        let recorder = HandlerRecorder()
        let model = makeModel(
            minimumProcessingDuration: .zero,
            confirm: { _, kind in
                recorder.confirmedKinds.append(kind)
                return true
            },
            terminate: { recorder.terminateCount += 1 },
            notify: { recorder.notifiedBatches.append($0) },
            tokenStore: try makeTokenStore()
        )

        let empty = model.handleIncomingRequest(
            IncomingRequest(urls: [missing], action: .remove, quitAfter: true, token: nil),
            isColdLaunch: true
        )
        let successor = model.handleIncomingRequest(
            IncomingRequest(urls: [real], action: .remove, quitAfter: false, token: nil),
            isColdLaunch: false
        )
        await empty.value
        await successor.value

        #expect(recorder.terminateCount == 0)
        try await waitUntil { model.items.first?.status == .clean }
    }

    @Test("A URL the parser rejects still honors a cold launch's quit contract")
    func rejectedColdLaunchRequestTerminates() throws {
        let recorder = HandlerRecorder()
        let model = makeModel(
            terminate: { recorder.terminateCount += 1 },
            tokenStore: try makeTokenStore()
        )
        let quitting = try #require(URL(string: "smuggler://process?path=relative/a.app&quitAfter=true"))
        let staying = try #require(URL(string: "smuggler://process?path=relative/a.app"))

        model.rejectIncomingRequest(staying, isColdLaunch: true)
        model.rejectIncomingRequest(quitting, isColdLaunch: false)
        #expect(recorder.terminateCount == 0)

        model.rejectIncomingRequest(quitting, isColdLaunch: true)
        #expect(recorder.terminateCount == 1)
    }

    @Test("A cold-launch quitAfter request with no processable paths still quits")
    func coldLaunchQuitAfterEmptyRequestTerminates() async throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let recorder = HandlerRecorder()
        let model = makeModel(
            minimumProcessingDuration: .zero,
            terminate: { recorder.terminateCount += 1 },
            tokenStore: try makeTokenStore()
        )

        await model.handleIncomingRequest(
            IncomingRequest(urls: [missing], action: .remove, quitAfter: true, token: nil),
            isColdLaunch: true
        ).value

        #expect(recorder.terminateCount == 1)
        #expect(model.items.isEmpty)
    }

    @Test("A cold-launch tokened remove processes silently, notifies, and terminates")
    func coldLaunchTokenedRemoveRunsToTermination() async throws {
        let url = try makeQuarantinedFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try makeTokenStore()
        let token = try #require(store.issueToken())
        let recorder = HandlerRecorder()
        let model = makeModel(
            minimumProcessingDuration: .zero,
            confirm: { _, kind in
                recorder.confirmedKinds.append(kind)
                return true
            },
            terminate: { recorder.terminateCount += 1 },
            notify: { recorder.notifiedBatches.append($0) },
            tokenStore: store
        )

        await model.handleIncomingRequest(
            IncomingRequest(urls: [url], action: .remove, quitAfter: true, token: token),
            isColdLaunch: true
        ).value

        try await waitUntil { recorder.terminateCount > 0 }
        #expect(recorder.confirmedKinds.isEmpty)
        #expect(model.items.first?.status == .clean)
        #expect(recorder.notifiedBatches.count == 1)
    }

    @Test("An untrusted symlink alias into a blocked tree skips the dialog and surfaces a refusal")
    func symlinkAliasSkipsConfirmation() async throws {
        let link = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: URL(filePath: "/usr/bin"))
        defer { try? FileManager.default.removeItem(at: link) }
        let alias = link.appending(path: "true")

        let recorder = HandlerRecorder()
        let model = makeModel(
            minimumProcessingDuration: .zero,
            confirm: { _, kind in
                recorder.confirmedKinds.append(kind)
                return true
            },
            tokenStore: try makeTokenStore()
        )

        await model.handleIncomingRequest(
            IncomingRequest(urls: [alias], action: .remove, quitAfter: false, token: nil),
            isColdLaunch: false
        ).value

        try await waitUntil { !model.items.isEmpty && model.items[0].status != .processing }
        #expect(recorder.confirmedKinds.isEmpty)
        #expect(model.items[0].status == .error(.blockedPath(alias)))
    }

    @Test("A warm open request for an in-flight URL opens it once it finishes")
    func warmOpenRequestAdoptsInFlightItem() async throws {
        let url = try makeQuarantinedFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = HandlerRecorder()
        let model = makeModel(
            minimumProcessingDuration: .milliseconds(300),
            confirm: { urls, kind in
                recorder.confirmedURLs = urls
                recorder.confirmedKinds.append(kind)
                return true
            },
            open: { recorder.openedURLs = $0 }
        )

        let firstRun = Task { await model.process(urls: [url]) }
        try await waitUntil { !model.items.isEmpty }
        model.handleServiceURLs([url], action: .open, quitAfter: false)

        try await waitUntil { recorder.openedURLs == [url] }
        #expect(model.items.count == 1)
        #expect(recorder.confirmedKinds == [.open])
        await firstRun.value
    }
}
