//
//  AppModelRequestQueueTests.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import Foundation
import Testing

@testable import Smuggler

@Suite("AppModel — Request queue")
@MainActor
struct AppModelRequestQueueTests {
    let sandbox = TestSandbox()

    @Test("Rapid incoming requests apply in arrival order")
    func incomingRequestsKeepArrivalOrder() async throws {
        let urlA = try sandbox.file(quarantined: true)
        let urlB = try sandbox.file(quarantined: true)
        let model = makeModel(confirming: true)

        let first = model.handleIncomingRequest([urlA])
        let second = model.handleIncomingRequest([urlB])
        await first.value
        await second.value

        #expect(model.items.map(\.url) == [urlB, urlA])
        try await waitUntil { model.items.allSatisfy { $0.status != .processing } }
    }

    @Test("A queued request's token is consumed on arrival, not when the queue drains")
    func incomingRequestConsumesTokenOnArrival() async throws {
        let url = try sandbox.file(quarantined: true)
        let store = ServiceTokenStore(containerURL: sandbox.root)
        let token = try #require(store.issueToken())
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder, confirming: true, tokenStore: store)

        let release = model.parkRequestQueue()
        let task = model.handleIncomingRequest([url], token: token)

        // Already consumed: presenting the same token again must fail.
        #expect(store.consumeToken(token) == false)
        release.finish()
        await task.value
        try await model.settle()
        #expect(model.items.first?.status == .clean)
        #expect(recorder.confirmations.isEmpty)
    }

    @Test("Clear cancels a queued incoming request before it can run")
    func clearCancelsQueuedIncomingRequest() async throws {
        let url = try sandbox.file(quarantined: true)
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder, confirming: true)

        let release = model.parkRequestQueue()
        let task = model.handleIncomingRequest([url])
        model.clear()
        release.finish()
        await task.value

        #expect(model.items.isEmpty)
        #expect(recorder.confirmations.isEmpty)
    }

    @Test("Clear cancels every queued request, not only the newest")
    func clearCancelsEveryQueuedRequest() async throws {
        let first = try sandbox.file(quarantined: true)
        let second = try sandbox.file(quarantined: true)
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder, confirming: true)

        let release = model.parkRequestQueue()
        let earlier = model.handleIncomingRequest([first])
        let later = model.handleIncomingRequest([second])
        model.clear()
        release.finish()
        await earlier.value
        await later.value

        #expect(model.items.isEmpty)
        #expect(recorder.confirmations.isEmpty)
    }

    @Test("An empty cold-launch request does not quit while a later request is queued")
    func emptyColdLaunchDefersToQueuedSuccessor() async throws {
        let missing = sandbox.url()
        let real = try sandbox.file(quarantined: true)
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder, confirming: true)

        let empty = model.handleIncomingRequest([missing], quitAfter: true, isColdLaunch: true)
        let successor = model.handleIncomingRequest([real])
        await empty.value
        await successor.value

        try await model.settle()
        #expect(recorder.terminateCount == 0)
        #expect(model.items.first?.status == .clean)
    }

    @Test("A request still waiting its turn when the quit grace ends keeps the session")
    func pendingQuitDefersToQueuedRequest() async throws {
        let first = try sandbox.file(quarantined: true)
        let second = try sandbox.file(quarantined: true)
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder, confirming: true)

        model.handleServiceURLs([first], action: .remove, quitAfter: true)
        let session = try #require(model.serviceMode)
        await session.processingTask?.value
        let pendingQuit = try #require(session.terminationTask)
        let release = model.parkRequestQueue()
        let queued = model.handleIncomingRequest([second])

        await pendingQuit.value
        #expect(recorder.terminateCount == 0)
        #expect(model.serviceMode == nil)

        release.finish()
        await queued.value
        try await model.settle()
        #expect(model.items.map(\.status) == [.clean, .clean])
        #expect(recorder.notifiedBatches.count == 1)
        #expect(recorder.terminateCount == 0)
    }

    @Test("A URL the parser rejects still honors a cold launch's quit contract")
    func rejectedColdLaunchRequestTerminates() throws {
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder)
        let quitting = try #require(URL(string: "smuggler://process?path=relative/a.app&quitAfter=true"))
        let staying = try #require(URL(string: "smuggler://process?path=relative/a.app"))

        model.rejectIncomingRequest(staying, isColdLaunch: true)
        model.rejectIncomingRequest(quitting, isColdLaunch: false)
        #expect(recorder.terminateCount == 0)

        model.rejectIncomingRequest(quitting, isColdLaunch: true)
        #expect(recorder.terminateCount == 1)
    }

    @Test("A cold-launch quitAfter request whose paths are all gone reports it, then quits")
    func coldLaunchQuitAfterEmptyRequestTerminates() async throws {
        let missing = sandbox.url()
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder)

        await model.handleIncomingRequest([missing], quitAfter: true, isColdLaunch: true).value

        #expect(recorder.failureNotifications == 1)
        #expect(recorder.terminateCount == 1)
        #expect(model.items.isEmpty)
    }

    @Test("A cold-launch request whose paths are all gone does not quit over work dropped into the window")
    func emptyColdLaunchKeepsSessionForDroppedWork() async throws {
        let dropped = try sandbox.file(quarantined: true)
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder, minimumProcessingDuration: .milliseconds(400))

        let drop = Task { await model.process(urls: [dropped]) }
        try await waitUntil { model.isProcessing }
        await model.handleIncomingRequest([sandbox.url()], quitAfter: true, isColdLaunch: true).value

        #expect(recorder.terminateCount == 0)
        #expect(recorder.sessionStaysCount == 1)
        await drop.value
        #expect(model.items.map(\.status) == [.clean])
        #expect(recorder.terminateCount == 0)
    }
}
