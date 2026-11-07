//
//  AppModelServicesRequestTests.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import Foundation
import Testing

@testable import Smuggler

@Suite("AppModel — Services requests")
@MainActor
struct AppModelServicesRequestTests {
    let sandbox = TestSandbox()

    @Test("A Services request frees its items without asking")
    func servicesRequestRunsWithoutConfirmation() async throws {
        let url = try sandbox.file(quarantined: true)
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder)

        await model.handleServicesRequest([url], isColdLaunch: false).value

        try await model.settle()
        #expect(recorder.confirmations.isEmpty)
        #expect(model.items.map(\.status) == [.clean])
        #expect(!hasQuarantine(url))
    }

    @Test("A Services request drops missing paths and refuses protected ones like any request")
    func servicesRequestFiltersLikeAnyRequest() async throws {
        let real = try sandbox.file(quarantined: true)
        let missing = sandbox.url()
        let blocked = URL(filePath: "/usr/bin/\(UUID().uuidString)")
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder)

        await model.handleServicesRequest([real, missing, blocked], isColdLaunch: false).value

        try await model.settle()
        #expect(recorder.confirmations.isEmpty)
        #expect(model.items.map(\.url) == [blocked, real])
        #expect(model.items.map(\.status) == [.error(.blockedPath(blocked)), .clean])
    }

    @Test("A Services request waits its turn behind a URL request that arrived first")
    func servicesRequestKeepsArrivalOrder() async throws {
        let viaURL = try sandbox.file(quarantined: true)
        let viaServices = try sandbox.file(quarantined: true)
        let model = makeModel(confirming: true)

        let first = model.handleIncomingRequest([viaURL])
        let second = model.handleServicesRequest([viaServices], isColdLaunch: false)
        await first.value
        await second.value

        #expect(model.items.map(\.url) == [viaServices, viaURL])
        try await model.settle()
    }

    @Test("A Services request that launched the app for items that are all gone reports it, then quits")
    func coldServicesRequestWithNothingUsableQuits() async throws {
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder)

        await model.handleServicesRequest([sandbox.url()], isColdLaunch: true).value

        #expect(model.items.isEmpty)
        #expect(recorder.failureNotifications == 1)
        #expect(recorder.terminateCount == 1)
    }

    @Test("A Services request that launched the app shows an item it cannot look at as a row and stays")
    func coldServicesRequestReportsWhatItCannotStat() async throws {
        let lockedFolder = try sandbox.directory()
        let unreachable = try sandbox.file(in: lockedFolder, quarantined: true)
        try sandbox.lock(lockedFolder)
        let dangling = try sandbox.symlink(to: sandbox.url())
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder)

        await model.handleServicesRequest([unreachable, dangling], isColdLaunch: true).value

        try await model.settle()
        #expect(
            model.items.map(\.status) == [.error(.symbolicLink(dangling)), .error(.permissionDenied(unreachable))])
        #expect(recorder.notifiedBatches.count == 1)
        #expect(recorder.failureNotifications == 0)
        #expect(recorder.terminateCount == 0)
        #expect(model.serviceMode == nil)
    }

    @Test("A Services request queued behind a headless launch takes the session over")
    func servicesRequestTakesOverHeadlessLaunch() async throws {
        let launching = try sandbox.file(quarantined: true)
        let later = try sandbox.file(quarantined: true)
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder, confirming: true)

        let launch = model.handleIncomingRequest([launching], quitAfter: true, isColdLaunch: true)
        model.handleServicesRequest([later], isColdLaunch: false)
        await launch.value
        // The takeover leaves the launching batch running; only its own task says when it ends.
        let session = try #require(model.serviceMode)
        await session.processingTask?.value

        try await model.settle()
        #expect(model.items.map(\.status) == [.clean, .clean])
        #expect(recorder.confirmations == [.init(kind: .remove, urls: [launching])])
        #expect(recorder.terminateCount == 0)
        #expect(model.serviceMode == nil)
    }
}
