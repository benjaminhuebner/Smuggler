//
//  AppModelServiceModeTests.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import Foundation
import Testing

@testable import Smuggler

@Suite("AppModel — Service mode")
@MainActor
struct AppModelServiceModeTests {
    let sandbox = TestSandbox()

    // Regression: when the app is already open, the Services / Finder path passes
    // quitAfter == false. The processing task must still run.
    @Test("handleServiceURLs processes items when the app is already open")
    func serviceURLsProcessWhenAlreadyOpen() async throws {
        let url = try sandbox.file(quarantined: true)
        let model = makeModel()

        model.handleServiceURLs([url], action: .remove, quitAfter: false)

        try await model.settle()
        #expect(model.items.map(\.status) == [.clean])
        #expect(model.isProcessing == false)
    }

    @Test("quitAfter service flow confirms, opens, and terminates")
    func serviceQuitAfterPathRunsToTermination() async throws {
        let url = try sandbox.file(quarantined: true)

        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder, confirming: true)

        model.handleServiceURLs([url], action: .open, quitAfter: true)

        try await model.settle()
        #expect(recorder.terminateCount == 1)
        #expect(model.items.first?.status == .clean)
        #expect(recorder.confirmations == [.init(kind: .open, urls: [url])])
        #expect(recorder.openedURLs == [url])
    }

    @Test("quitAfter service flow does not open when confirmation is declined")
    func serviceQuitAfterPathRespectsDeclinedConfirmation() async throws {
        let url = try sandbox.file(quarantined: true)

        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder)

        model.handleServiceURLs([url], action: .open, quitAfter: true)

        try await model.settle()
        #expect(recorder.terminateCount == 1)
        #expect(recorder.openedURLs.isEmpty)
    }

    @Test("Only a headless session asks for notification permission", arguments: [true, false])
    func onlyHeadlessSessionsAskForNotificationPermission(quitAfter: Bool) async throws {
        let url = try sandbox.file(quarantined: true)
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder)

        model.handleServiceURLs([url], action: .remove, quitAfter: quitAfter)

        try await model.settle()
        #expect(recorder.authorizeCount == (quitAfter ? 1 : 0))
    }

    @Test("Blocked-only service request shows error rows and notifies without quitting")
    func blockedRequestProducesFeedback() async throws {
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder)
        let blocked = URL(filePath: "/System/Library/CoreServices/Finder.app")

        model.handleServiceURLs([blocked], action: .remove, quitAfter: true)

        try await model.settle()
        #expect(model.items.map(\.status) == [.error(.blockedPath(blocked))])
        #expect(recorder.notifiedBatches.count == 1)
        #expect(recorder.notifiedBatches.first?.count == 1)
        #expect(recorder.terminateCount == 0)
        #expect(recorder.sessionStaysCount == 1)
        #expect(model.serviceMode == nil)
    }

    @Test("Mixed request reports blocked paths instead of silently dropping them")
    func mixedRequestReportsBlockedPaths() async throws {
        let url = try sandbox.file(quarantined: true)
        let blocked = URL(filePath: "/usr/bin/true")

        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder)

        model.handleServiceURLs([url, blocked], action: .remove, quitAfter: true)

        try await model.settle()
        let batch = try #require(recorder.notifiedBatches.first)
        #expect(batch.contains(where: { $0.status == .error(.blockedPath(blocked)) }))
        #expect(batch.contains(where: { $0.status == .clean }))
        #expect(recorder.terminateCount == 0)
        #expect(model.serviceMode == nil)
    }

    @Test("Service-mode batch with errors posts the failure notification")
    func serviceModeErrorPostsNotification() async throws {
        let missing = sandbox.url()

        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder)

        model.handleServiceURLs([missing], action: .remove, quitAfter: true)

        try await model.settle()
        #expect(model.serviceMode == nil)
        #expect(recorder.terminateCount == 0)
        // Handed back with its rows: the window stays up to show them.
        #expect(model.items.map(\.url) == [missing])
        let batch = try #require(recorder.notifiedBatches.first)
        #expect(batch.count == 1)
        #expect(batch.first?.status.hasErrors == true)
    }

    @Test("A skipped subtree does not hold a headless session open")
    func skippedSubtreeDoesNotHoldTheSessionOpen() async throws {
        let root = try sandbox.directory(files: 1, quarantined: true)
        let locked = try sandbox.directory("locked", in: root)
        // Write and search without read: the folder's own attribute call succeeds and
        // only the descent fails, so the batch's one error is the skip.
        try sandbox.lock(locked, permissions: 0o300)

        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder)

        model.handleServiceURLs([root], action: .remove, quitAfter: true)

        try await model.settle()
        guard case .partialSuccess(let cleaned, let errors) = model.items.first?.status else {
            Issue.record("Expected a partial success, got \(String(describing: model.items.first?.status))")
            return
        }
        #expect(cleaned == 1)
        #expect(errors.map(\.error.isSkippedDirectory) == [true])
        #expect(errors.map(\.url.lastPathComponent) == ["locked"])
        #expect(recorder.notifiedBatches.count == 1)
        #expect(recorder.terminateCount == 1)
    }

    @Test("An open batch offers what it freed whatever else failed", arguments: [true, false])
    func openBatchWithFailureStillOffersFreedItems(quitAfter: Bool) async throws {
        let url = try sandbox.file(quarantined: true)
        let missing = sandbox.url()

        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder, confirming: true)

        model.handleServiceURLs([url, missing], action: .open, quitAfter: quitAfter)

        try await model.settle()
        #expect(recorder.confirmations == [.init(kind: .open, urls: [url])])
        #expect(recorder.openedURLs == [url])
        #expect(recorder.terminateCount == 0)
        #expect(model.serviceMode == nil)
        #expect(recorder.notifiedBatches.count == (quitAfter ? 1 : 0))
    }

    @Test("A headless open batch that freed nothing asks nothing and stays to show why")
    func headlessOpenBatchWithNothingFreedAsksNothing() async throws {
        let missing = sandbox.url()

        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder, confirming: true)

        model.handleServiceURLs([missing], action: .open, quitAfter: true)

        try await model.settle()
        #expect(recorder.confirmations.isEmpty)
        #expect(recorder.openedURLs.isEmpty)
        #expect(recorder.notifiedBatches.count == 1)
        #expect(recorder.terminateCount == 0)
        #expect(model.serviceMode == nil)
    }

    @Test("Rapid double service invocation terminates exactly once")
    func doubleServiceInvocationSupersedesFirstBatch() async throws {
        let url1 = try sandbox.file(quarantined: true)
        let url2 = try sandbox.file(quarantined: true)

        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder)

        model.handleServiceURLs([url1], action: .remove, quitAfter: true)
        let first = try #require(model.serviceMode)
        // Taken before the takeover: superseding a session drops its task handles.
        let firstRun = try #require(first.processingTask)
        model.handleServiceURLs([url2], action: .remove, quitAfter: true)
        let second = try #require(model.serviceMode)
        #expect(second !== first)

        await firstRun.value
        await first.terminationTask?.value
        try await model.settle()
        #expect(recorder.terminateCount == 1)
        // The superseded batch reports nothing; only the successor's result is posted.
        #expect(recorder.notifiedBatches.map { $0.map(\.url) } == [[url2]])
    }

    @Test("A quitAfter batch arriving during the quit grace cancels the pending quit")
    func quitAfterBatchDuringGraceCancelsPendingQuit() async throws {
        let url1 = try sandbox.file(quarantined: true)
        let url2 = try sandbox.file(quarantined: true)

        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder)

        model.handleServiceURLs([url1], action: .remove, quitAfter: true)
        let first = try #require(model.serviceMode)
        await first.processingTask?.value
        let pendingQuit = try #require(first.terminationTask)

        model.handleServiceURLs([url2], action: .remove, quitAfter: true)
        await pendingQuit.value
        #expect(recorder.terminateCount == 0)

        let second = try #require(model.serviceMode)
        #expect(second !== first)
        try await model.settle()
        #expect(recorder.terminateCount == 1)
        #expect(recorder.notifiedBatches.count == 2)
    }

    @Test("A pending quit hands the session back while work outside the request chain still runs")
    func pendingQuitDefersToWorkOutsideTheRequestChain() async throws {
        let url = try sandbox.file(quarantined: true)
        let dropped = try sandbox.file(quarantined: true)

        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder)
        // A drop the headless batch knows nothing about, still in flight at its end.
        model.enqueue(urls: [dropped])

        model.handleServiceURLs([url], action: .remove, quitAfter: true)
        let session = try #require(model.serviceMode)
        await session.processingTask?.value
        let pendingQuit = try #require(session.terminationTask)
        await pendingQuit.value

        #expect(recorder.terminateCount == 0)
        #expect(recorder.sessionStaysCount == 1)
        #expect(model.serviceMode == nil)
        #expect(recorder.notifiedBatches.map { $0.map(\.url) } == [[url]])
    }

    @Test("A batch superseded during the open confirmation must not terminate the successor mid-batch")
    func supersededBatchDoesNotTerminateSuccessor() async throws {
        let url1 = try sandbox.file(quarantined: true)
        let url2 = try sandbox.file(quarantined: true)

        let box = ModelBox()
        let recorder = HandlerRecorder()
        // Long enough that a stale termination timer from batch 1 would fire
        // while batch 2 is still processing.
        let model = makeModel(
            recorder: recorder,
            minimumProcessingDuration: .milliseconds(300),
            confirm: { _, kind in
                // Stand-in for the nested modal run loop: a second batch
                // arrives while the first is suspended in its confirmation.
                if kind == .open, recorder.injectedSecondBatch == false {
                    recorder.injectedSecondBatch = true
                    box.model?.handleServiceURLs([url2], action: .remove, quitAfter: true)
                }
                return true
            },
            terminate: {
                recorder.statusAtTerminate = box.model?.items.first(where: { $0.url == url2 })?.status
            }
        )
        box.model = model

        model.handleServiceURLs([url1], action: .open, quitAfter: true)

        try await model.settle()
        #expect(recorder.statusAtTerminate == .clean)
        #expect(recorder.terminateCount == 1)
    }

    @Test("A batch superseded during the error notification must not orphan the successor")
    func supersededErrorBatchDoesNotOrphanSuccessor() async throws {
        let missing = sandbox.url()
        let url2 = try sandbox.file(quarantined: true)

        let box = ModelBox()
        let recorder = HandlerRecorder()
        let model = makeModel(
            recorder: recorder,
            notify: { _ in
                // The second batch arrives while the first is suspended in its
                // error notification.
                if recorder.notifiedBatches.count == 1 {
                    box.model?.handleServiceURLs([url2], action: .remove, quitAfter: true)
                }
            }
        )
        box.model = model

        model.handleServiceURLs([missing], action: .remove, quitAfter: true)
        let first = try #require(model.serviceMode)
        let firstRun = try #require(first.processingTask)

        await firstRun.value
        let successor = try #require(model.serviceMode)
        #expect(successor !== first)
        try await model.settle()
        #expect(recorder.notifiedBatches.count == 2)
        #expect(recorder.terminateCount == 1)
    }

    @Test("A warm batch arriving during a pending quit takes over the session")
    func warmBatchCancelsPendingQuit() async throws {
        let url1 = try sandbox.file(quarantined: true)
        let url2 = try sandbox.file(quarantined: true)

        let recorder = HandlerRecorder()
        // A grace no scheduling delay outlasts, so the quit is still pending when
        // the warm batch lands; once cancelled it ends at once.
        let model = makeModel(recorder: recorder, terminationGrace: .seconds(5))

        model.handleServiceURLs([url1], action: .remove, quitAfter: true)
        let first = try #require(model.serviceMode)
        await first.processingTask?.value
        let pendingQuit = try #require(first.terminationTask)
        model.handleServiceURLs([url2], action: .remove, quitAfter: false)

        #expect(model.serviceMode == nil)
        await pendingQuit.value
        try await model.settle()
        #expect(model.items.count == 2)
        #expect(model.items.allSatisfy { $0.status == .clean })
        #expect(recorder.terminateCount == 0)
        // The takeover cancels the quit, not the finished batch's notification.
        #expect(recorder.notifiedBatches.count == 1)
        #expect(recorder.notifiedBatches.first?.contains { $0.url == url1 } == true)
    }

    @Test("A warm batch during a quitAfter batch's processing keeps its notification")
    func warmTakeoverDuringProcessingKeepsNotification() async throws {
        let url1 = try sandbox.file(quarantined: true)
        let url2 = try sandbox.file(quarantined: true)

        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder)

        model.handleServiceURLs([url1], action: .remove, quitAfter: true)
        #expect(recorder.sessionStaysCount == 0)
        let first = try #require(model.serviceMode)
        let firstRun = try #require(first.processingTask)
        model.handleServiceURLs([url2], action: .remove, quitAfter: false)
        #expect(model.serviceMode == nil)
        #expect(recorder.sessionStaysCount == 1)

        await firstRun.value
        await first.terminationTask?.value
        try await model.settle()
        #expect(recorder.notifiedBatches.first?.contains { $0.url == url1 } == true)
        #expect(recorder.terminateCount == 0)
        #expect(recorder.sessionStaysCount == 1)
    }

    @Test("A warm open request for an in-flight URL opens it once it finishes")
    func warmOpenRequestAdoptsInFlightItem() async throws {
        let url = try sandbox.file(quarantined: true)
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder, confirming: true, minimumProcessingDuration: .milliseconds(300))

        let firstRun = Task { await model.process(urls: [url]) }
        try await waitUntil { !model.items.isEmpty }
        model.handleServiceURLs([url], action: .open, quitAfter: false)

        try await model.settle()
        #expect(recorder.openedURLs == [url])
        #expect(model.items.count == 1)
        #expect(recorder.confirmations == [.init(kind: .open, urls: [url])])
        await firstRun.value
    }
}
