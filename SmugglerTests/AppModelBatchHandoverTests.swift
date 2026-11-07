//
//  AppModelBatchHandoverTests.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import Foundation
import Testing

@testable import Smuggler

@Suite("AppModel — Batch handover")
@MainActor
struct AppModelBatchHandoverTests {
    let sandbox = TestSandbox()

    @Test("A handover that cannot be read is reported instead of passing as an empty request")
    func unreadableBatchNotifiesFailure() async throws {
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder, confirming: true)

        await model.handleIncomingRequest([], quitAfter: true, batchName: UUID().uuidString, isColdLaunch: true).value

        #expect(recorder.confirmations.isEmpty)
        #expect(recorder.failureNotifications == 1)
        #expect(recorder.notifiedBatches.isEmpty)
        #expect(recorder.terminateCount == 1)
        #expect(model.items.isEmpty)
    }

    @Test("A failed handover behind a queued successor reports without quitting")
    func unreadableBatchDefersToQueuedSuccessor() async throws {
        let real = try sandbox.file(quarantined: true)
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder, confirming: true)

        let failing = model.handleIncomingRequest([], quitAfter: true, batchName: UUID().uuidString, isColdLaunch: true)
        let successor = model.handleIncomingRequest([real])
        await failing.value
        await successor.value

        try await model.settle()
        #expect(recorder.failureNotifications == 1)
        #expect(recorder.terminateCount == 0)
        #expect(model.items.first?.status == .clean)
    }

    @Test("A failed handover that launched the app does not quit over work dropped into the window")
    func unreadableBatchKeepsSessionForDroppedWork() async throws {
        let dropped = try sandbox.file(quarantined: true)
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder, minimumProcessingDuration: .milliseconds(400))

        let drop = Task { await model.process(urls: [dropped]) }
        try await waitUntil { model.isProcessing }
        await model.handleIncomingRequest([], quitAfter: true, batchName: UUID().uuidString, isColdLaunch: true).value

        #expect(recorder.failureNotifications == 1)
        #expect(recorder.terminateCount == 0)
        #expect(recorder.sessionStaysCount == 1)
        await drop.value
        #expect(model.items.map(\.status) == [.clean])
        #expect(recorder.terminateCount == 0)
    }

    @Test("A batch grants no trust: its paths are confirmed and blocked ones refused")
    func batchedRequestGrantsNoTrust() async throws {
        let real = try sandbox.file(quarantined: true)
        let blocked = URL(filePath: "/usr/bin/\(UUID().uuidString)")
        let batchStore = ServiceBatchStore(containerURL: sandbox.root)
        let batch = try #require(batchStore.write(paths: [real, blocked].map { $0.path(percentEncoded: false) }))
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder, confirming: true, batchStore: batchStore)

        await model.handleIncomingRequest([], batchName: batch).value

        try await model.settle()
        #expect(recorder.confirmations == [.init(kind: .remove, urls: [real])])
        #expect(model.items.map(\.url) == [blocked, real])
        #expect(model.items.map(\.status) == [.error(.blockedPath(blocked)), .clean])
    }

    @Test("A tokened batch from a cold launch runs silently, notifies, and terminates")
    func batchedTokenedColdLaunchRunsToTermination() async throws {
        let url = try sandbox.file(quarantined: true)
        let tokenStore = ServiceTokenStore(containerURL: sandbox.root)
        let batchStore = ServiceBatchStore(containerURL: sandbox.root)
        let token = try #require(tokenStore.issueToken())
        let batch = try #require(batchStore.write(paths: [url.path(percentEncoded: false)]))
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder, confirming: true, tokenStore: tokenStore, batchStore: batchStore)

        await model.handleIncomingRequest([], quitAfter: true, token: token, batchName: batch, isColdLaunch: true).value

        try await model.settle()
        #expect(recorder.confirmations.isEmpty)
        #expect(model.items.map(\.status) == [.clean])
        #expect(recorder.notifiedBatches.count == 1)
        #expect(recorder.terminateCount == 1)
    }

    @Test("A queued request's batch is read on arrival, not when the queue drains")
    func incomingRequestReadsBatchOnArrival() async throws {
        let url = try sandbox.file(quarantined: true)
        let batchStore = ServiceBatchStore(containerURL: sandbox.root)
        let batch = try #require(batchStore.write(paths: [url.path(percentEncoded: false)]))
        let batchFile = sandbox.root.appending(path: "ServiceBatches").appending(path: batch)
        let model = makeModel(confirming: true, batchStore: batchStore)

        let release = model.parkRequestQueue()
        let task = model.handleIncomingRequest([], batchName: batch)

        try await waitUntil { !FileManager.default.fileExists(atPath: batchFile.path(percentEncoded: false)) }
        release.finish()
        await task.value
        try await model.settle()
        #expect(model.items.map(\.status) == [.clean])
    }
}
