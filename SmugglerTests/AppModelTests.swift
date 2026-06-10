import Foundation
import Testing

@testable import Smuggler

@Suite("AppModel — URL Parsing")
struct AppModelURLParsingTests {
    @Test("Parses valid smuggler://process URL with single path")
    func parsesSinglePath() throws {
        let url = try #require(URL(string: "smuggler://process?path=/tmp/MyApp.app&action=open&quitAfter=true"))
        let request = AppModel.parseIncomingURL(url)

        #expect(request != nil)
        #expect(request?.urls.count == 1)
        #expect(request?.urls[0].path(percentEncoded: false) == "/tmp/MyApp.app")
        #expect(request?.action == .open)
        #expect(request?.quitAfter == true)
    }

    @Test("Parses URL with multiple path parameters")
    func parsesMultiplePaths() throws {
        let url = try #require(URL(string: "smuggler://process?path=/tmp/a.app&path=/tmp/b.dmg"))
        let request = AppModel.parseIncomingURL(url)

        #expect(request != nil)
        #expect(request?.urls.count == 2)
    }

    @Test("Defaults action to 'open' when missing")
    func defaultsActionToOpen() throws {
        let url = try #require(URL(string: "smuggler://process?path=/tmp/a.app"))
        let request = AppModel.parseIncomingURL(url)

        #expect(request?.action == .open)
    }

    @Test("Defaults quitAfter to false when missing")
    func defaultsQuitAfterToFalse() throws {
        let url = try #require(URL(string: "smuggler://process?path=/tmp/a.app"))
        let request = AppModel.parseIncomingURL(url)

        #expect(request?.quitAfter == false)
    }

    @Test("Returns nil for wrong scheme")
    func returnsNilForWrongScheme() throws {
        let url = try #require(URL(string: "https://process?path=/tmp/a.app"))
        #expect(AppModel.parseIncomingURL(url) == nil)
    }

    @Test("Returns nil for wrong host")
    func returnsNilForWrongHost() throws {
        let url = try #require(URL(string: "smuggler://launch?path=/tmp/a.app"))
        #expect(AppModel.parseIncomingURL(url) == nil)
    }

    @Test("Returns nil when path parameter is missing")
    func returnsNilForMissingPath() throws {
        let url = try #require(URL(string: "smuggler://process?action=open"))
        #expect(AppModel.parseIncomingURL(url) == nil)
    }

    @Test("Parses action=remove correctly")
    func parsesRemoveAction() throws {
        let url = try #require(URL(string: "smuggler://process?path=/tmp/a.app&action=remove"))
        let request = AppModel.parseIncomingURL(url)

        #expect(request?.action == .remove)
    }

    @Test("Rejects unknown action parameter")
    func rejectsUnknownAction() throws {
        let url = try #require(URL(string: "smuggler://process?path=/tmp/a.app&action=delete"))
        #expect(AppModel.parseIncomingURL(url) == nil)
    }

    @Test("Parsing keeps blocked paths — refusal happens in the processing pipeline")
    func parseKeepsBlockedPaths() throws {
        let url = try #require(
            URL(string: "smuggler://process?path=/tmp/a.app&path=/usr/bin/true&action=remove"))
        let request = try #require(AppModel.parseIncomingURL(url))

        #expect(request.urls.count == 2)
    }

    @Test("Parses paths without checking existence (validation happens at call site)")
    func parsesNonExistentPaths() throws {
        let url = try #require(URL(string: "smuggler://process?path=/nonexistent/\(UUID().uuidString)"))
        let request = AppModel.parseIncomingURL(url)
        #expect(request != nil)
        #expect(request?.urls.count == 1)
    }
}

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
}

@Suite("AppModel — Processing")
@MainActor
struct AppModelProcessingTests {
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

    private struct WaitTimeoutError: Error {}

    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let start = ContinuousClock.now
        while !condition() {
            if ContinuousClock.now - start > timeout {
                throw WaitTimeoutError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("process removes quarantine and marks the item clean")
    func processMarksClean() async throws {
        let url = try makeQuarantinedFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel(minimumProcessingDuration: .zero)

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
        let model = AppModel(minimumProcessingDuration: .zero)

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

        let model = AppModel(minimumProcessingDuration: .zero)
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
        let model = AppModel(minimumProcessingDuration: .zero)

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
        let model = AppModel(minimumProcessingDuration: .zero)

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
        let model = AppModel(
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
        let model = AppModel(
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
        let model = AppModel(
            minimumProcessingDuration: .zero,
            confirm: { urls, kind in
                recorder.confirmedURLs = urls
                recorder.confirmedKinds.append(kind)
                return true
            },
            tokenStore: try makeTokenStore()
        )

        model.handleURLRequest(urls: [url], action: .remove, quitAfter: false, token: nil)

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
        let model = AppModel(
            minimumProcessingDuration: .zero,
            confirm: { _, _ in false },
            terminate: { recorder.terminateCount += 1 },
            tokenStore: try makeTokenStore()
        )

        model.handleURLRequest(urls: [url], action: .remove, quitAfter: true, token: nil)

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
        let model = AppModel(
            minimumProcessingDuration: .zero,
            confirm: { _, kind in
                recorder.confirmedKinds.append(kind)
                return true
            },
            tokenStore: store
        )

        model.handleURLRequest(urls: [url], action: .remove, quitAfter: false, token: token)

        try await waitUntil { !model.items.isEmpty && model.items[0].status != .processing }
        #expect(recorder.confirmedKinds.isEmpty)
        #expect(model.items[0].status == .clean)
    }

    @Test("URL remove request with an invalid token asks for confirmation")
    func urlRemoveWithInvalidTokenAsksConfirmation() async throws {
        let url = try makeQuarantinedFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = HandlerRecorder()
        let model = AppModel(
            minimumProcessingDuration: .zero,
            confirm: { _, kind in
                recorder.confirmedKinds.append(kind)
                return false
            },
            tokenStore: try makeTokenStore()
        )

        model.handleURLRequest(urls: [url], action: .remove, quitAfter: false, token: UUID().uuidString)

        #expect(recorder.confirmedKinds == [.remove])
        #expect(model.items.isEmpty)
    }

    @Test("Parsed URL request carries its token through")
    func parseExtractsToken() throws {
        let token = UUID().uuidString
        let url = try #require(
            URL(string: "smuggler://process?path=/tmp/a.app&action=remove&token=\(token)"))
        let request = try #require(AppModel.parseIncomingURL(url))

        #expect(request.token == token)
    }

    @Test("Blocked-only service request shows error rows and notifies without quitting")
    func blockedRequestProducesFeedback() async throws {
        let recorder = HandlerRecorder()
        let model = AppModel(
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
        let model = AppModel(
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
        let model = AppModel(
            minimumProcessingDuration: .zero,
            confirm: { urls, kind in
                recorder.confirmedURLs = urls
                recorder.confirmedKinds.append(kind)
                return false
            },
            tokenStore: try makeTokenStore()
        )

        model.handleURLRequest(urls: [url], action: .open, quitAfter: false, token: nil)

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
        let model = AppModel(
            minimumProcessingDuration: .zero,
            confirm: { _, kind in
                recorder.confirmedKinds.append(kind)
                return true
            },
            open: { recorder.openedURLs = $0 },
            tokenStore: try makeTokenStore()
        )

        model.handleURLRequest(urls: [url], action: .open, quitAfter: false, token: nil)

        try await waitUntil { recorder.openedURLs == [url] }
        #expect(recorder.confirmedKinds == [.remove, .open])
        #expect(model.items.first?.status == .clean)
    }

    @Test("Service-mode batch with errors posts the failure notification")
    func serviceModeErrorPostsNotification() async throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

        let recorder = HandlerRecorder()
        let model = AppModel(
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
        let model = AppModel(minimumProcessingDuration: .zero)

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
        let model = AppModel(
            minimumProcessingDuration: .zero,
            terminate: { recorder.terminateCount += 1 }
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
        let model = AppModel(
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
        let model = AppModel(
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

    @Test("A cancelled run draining after a re-drop must not clobber the new run")
    func cancelledRunDoesNotClobberRedrop() async throws {
        let url = try makeQuarantinedFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel(minimumProcessingDuration: .milliseconds(400))

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
