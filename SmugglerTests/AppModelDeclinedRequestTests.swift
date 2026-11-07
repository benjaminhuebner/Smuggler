//
//  AppModelDeclinedRequestTests.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import Foundation
import Testing

@testable import Smuggler

@Suite("AppModel — Declined requests")
@MainActor
struct AppModelDeclinedRequestTests {
    let sandbox = TestSandbox()

    @Test("A declined headless request processes nothing and quits once its grace has passed")
    func urlRemoveDeclinedProcessesNothing() async throws {
        let url = try sandbox.file(quarantined: true)

        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder)

        await model.handleIncomingRequest([url], quitAfter: true, isColdLaunch: true).value

        #expect(recorder.confirmations == [.init(kind: .remove, urls: [url])])
        #expect(recorder.terminateCount == 1)
        #expect(model.items.isEmpty)
        #expect(hasQuarantine(url))
    }

    @Test("A declined headless request does not quit while a request sent during its dialog waits")
    func declinedRequestDefersToSuccessorSentDuringDialog() async throws {
        let declined = try sandbox.file(quarantined: true)
        let successor = try sandbox.file(quarantined: true)

        let box = ModelBox()
        let recorder = HandlerRecorder()
        let model = makeModel(
            recorder: recorder,
            confirm: { urls, _ in
                guard urls == [declined] else { return true }
                box.model?.handleIncomingRequest([successor])
                return false
            }
        )
        box.model = model

        await model.handleIncomingRequest([declined], quitAfter: true, isColdLaunch: true).value

        try await model.settle()
        #expect(recorder.terminateCount == 0)
        #expect(model.items.map(\.url) == [successor])
        #expect(model.items.map(\.status) == [.clean])
        #expect(hasQuarantine(declined))
    }

    @Test("A request delivered only once the dialog has closed still takes over a declined headless launch")
    func declinedRequestWaitsForSuccessorDeliveredAfterDialog() async throws {
        let declined = try sandbox.file(quarantined: true)
        let successor = try sandbox.file(quarantined: true)

        let box = ModelBox()
        let recorder = HandlerRecorder()
        let model = makeModel(
            recorder: recorder,
            confirm: { urls, _ in
                guard urls == [declined] else { return true }
                // Delivered on a later turn of the main actor, after the modal returned.
                Task {
                    box.model?.handleIncomingRequest([successor])
                }
                return false
            }
        )
        box.model = model

        await model.handleIncomingRequest([declined], quitAfter: true, isColdLaunch: true).value

        try await model.settle()
        #expect(recorder.terminateCount == 0)
        #expect(model.items.map(\.status) == [.clean])
        #expect(hasQuarantine(declined))
    }

    @Test("Work dropped into the window during a declined launch's grace keeps the session")
    func declinedLaunchKeepsSessionForDroppedWork() async throws {
        let declined = try sandbox.file(quarantined: true)
        let dropped = try sandbox.file(quarantined: true)

        let box = ModelBox()
        let recorder = HandlerRecorder()
        let model = makeModel(
            recorder: recorder,
            minimumProcessingDuration: .milliseconds(400),
            confirm: { _, _ in
                Task { await box.model?.process(urls: [dropped]) }
                return false
            }
        )
        box.model = model

        await model.handleIncomingRequest([declined], quitAfter: true, isColdLaunch: true).value

        #expect(model.isProcessing)
        #expect(recorder.terminateCount == 0)
        #expect(recorder.sessionStaysCount == 1)
        try await waitUntil { !model.isProcessing }
        #expect(recorder.terminateCount == 0)
        #expect(model.items.map(\.status) == [.clean])
        #expect(hasQuarantine(declined))
    }

    @Test("A declined request that cannot end the session holds up nothing behind it")
    func warmDeclineDoesNotWaitOutTheGrace() async throws {
        let url = try sandbox.file(quarantined: true)
        let model = makeModel(terminationGrace: .seconds(10))

        let elapsed = await ContinuousClock().measure {
            await model.handleIncomingRequest([url], quitAfter: true).value
        }

        #expect(elapsed < .seconds(5))
    }
}
