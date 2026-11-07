//
//  AppModelURLRequestTests.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import Foundation
import Testing

@testable import Smuggler

@Suite("AppModel — URL requests")
@MainActor
struct AppModelURLRequestTests {
    let sandbox = TestSandbox()

    @Test("URL remove request without a token asks for confirmation")
    func urlRemoveWithoutTokenAsksConfirmation() async throws {
        let url = try sandbox.file(quarantined: true)

        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder, confirming: true)

        await model.handleIncomingRequest([url]).value

        try await model.settle()
        #expect(recorder.confirmations == [.init(kind: .remove, urls: [url])])
        #expect(model.items.map(\.status) == [.clean])
    }

    @Test("URL remove request with a valid token runs without confirmation")
    func urlRemoveWithValidTokenIsSilent() async throws {
        let url = try sandbox.file(quarantined: true)

        let recorder = HandlerRecorder()
        let store = ServiceTokenStore(containerURL: sandbox.root)
        let token = try #require(store.issueToken())
        let model = makeModel(recorder: recorder, confirming: true, tokenStore: store)

        await model.handleIncomingRequest([url], token: token).value

        try await model.settle()
        #expect(recorder.confirmations.isEmpty)
        #expect(model.items.map(\.status) == [.clean])
    }

    @Test("URL remove request with an invalid token asks for confirmation")
    func urlRemoveWithInvalidTokenAsksConfirmation() async throws {
        let url = try sandbox.file(quarantined: true)

        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder, tokenStore: ServiceTokenStore(containerURL: sandbox.root))

        await model.handleIncomingRequest([url], token: UUID().uuidString).value

        #expect(recorder.confirmations == [.init(kind: .remove, urls: [url])])
        #expect(model.items.isEmpty)
    }

    @Test("A token replayed through the entry point falls back to the dialog")
    func urlRemoveWithReplayedTokenAsksConfirmation() async throws {
        let first = try sandbox.file(quarantined: true)
        let second = try sandbox.file(quarantined: true)
        let store = ServiceTokenStore(containerURL: sandbox.root)
        let token = try #require(store.issueToken())

        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder, tokenStore: store)

        await model.handleIncomingRequest([first], token: token).value
        try await model.settle()
        #expect(recorder.confirmations.isEmpty)

        await model.handleIncomingRequest([second], token: token).value

        #expect(recorder.confirmations == [.init(kind: .remove, urls: [second])])
        #expect(model.items.map(\.url) == [first])
        #expect(model.items.map(\.status) == [.clean])
        #expect(hasQuarantine(second))
    }

    @Test("Untrusted open request asks before any quarantine is removed")
    func urlOpenWithoutTokenGatesProcessing() async throws {
        let url = try sandbox.file(quarantined: true)

        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder)

        await model.handleIncomingRequest([url], action: .open).value

        #expect(recorder.confirmations == [.init(kind: .remove, urls: [url])])
        #expect(model.items.isEmpty)
        #expect(hasQuarantine(url))
    }

    @Test("Untrusted open request processes and opens only after approval")
    func urlOpenWithoutTokenRunsAfterApproval() async throws {
        let url = try sandbox.file(quarantined: true)

        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder, confirming: true)

        await model.handleIncomingRequest([url], action: .open).value

        try await model.settle()
        #expect(recorder.openedURLs == [url])
        #expect(recorder.confirmations == [.init(kind: .remove, urls: [url]), .init(kind: .open, urls: [url])])
        #expect(model.items.first?.status == .clean)
    }

    @Test("A tokened Remove-and-Open still asks before launching", arguments: [true, false], [true, false])
    func tokenedOpenStillAsksBeforeLaunching(isColdLaunch: Bool, approves: Bool) async throws {
        let url = try sandbox.file(quarantined: true)
        let store = ServiceTokenStore(containerURL: sandbox.root)
        let token = try #require(store.issueToken())

        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder, confirming: approves, tokenStore: store)

        await model.handleIncomingRequest(
            [url], action: .open, quitAfter: true, token: token, isColdLaunch: isColdLaunch
        ).value

        try await model.settle()
        #expect(recorder.confirmations == [.init(kind: .open, urls: [url])])
        #expect(recorder.openedURLs == (approves ? [url] : []))
        #expect(!hasQuarantine(url))
        #expect(recorder.terminateCount == (isColdLaunch ? 1 : 0))
    }

    @Test("An open request confirms and launches only what it freed", arguments: [true, false])
    func openRequestLaunchesOnlyWhatWasFreed(isColdLaunch: Bool) async throws {
        let real = try sandbox.file(quarantined: true)
        let blocked = URL(filePath: "/usr/bin/\(UUID().uuidString)")

        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder, confirming: true)

        await model.handleIncomingRequest(
            [real, blocked], action: .open, quitAfter: true, isColdLaunch: isColdLaunch
        ).value

        try await model.settle()
        #expect(recorder.confirmations == [.init(kind: .remove, urls: [real]), .init(kind: .open, urls: [real])])
        #expect(recorder.openedURLs == [real])
        #expect(model.items.map(\.status) == [.error(.blockedPath(blocked)), .clean])
        #expect(recorder.terminateCount == 0)
    }

    @Test("Incoming request drops nonexistent paths without asking, and reports that nothing was left")
    func incomingRequestDropsNonexistentPaths() async throws {
        let missing = sandbox.url()
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder, confirming: true)

        await model.handleIncomingRequest([missing]).value

        #expect(model.items.isEmpty)
        #expect(recorder.confirmations.isEmpty)
        #expect(recorder.failureNotifications == 1)
    }

    @Test("Incoming request keeps blocked paths as refusal rows even when nonexistent")
    func incomingRequestKeepsBlockedPaths() async throws {
        let blocked = URL(filePath: "/usr/bin/\(UUID().uuidString)")
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder, confirming: true)

        await model.handleIncomingRequest([blocked]).value

        #expect(model.items.first?.status == .error(.blockedPath(blocked)))
        #expect(recorder.confirmations.isEmpty)
    }

    @Test("A request through a kernel lookup alias is refused without asking")
    func kernelAliasRequestIsRefused() async throws {
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder, confirming: true)
        let url = try #require(URL(string: "smuggler://process?path=/.nofollow/usr/bin/true&action=remove"))

        await model.handleIncomingRequest(try #require(IncomingRequest(url: url)), isColdLaunch: false).value

        #expect(model.items.map(\.status) == [.error(.blockedPath(URL(filePath: "/.nofollow/usr/bin/true")))])
        #expect(recorder.confirmations.isEmpty)
    }

    @Test("quitAfter from a warm request does not enter service mode or terminate")
    func incomingRequestSquashesQuitAfterWhenWarm() async throws {
        let url = try sandbox.file(quarantined: true)
        let store = ServiceTokenStore(containerURL: sandbox.root)
        let token = try #require(store.issueToken())
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder, confirming: true, tokenStore: store)

        await model.handleIncomingRequest([url], quitAfter: true, token: token).value

        #expect(model.serviceMode == nil)
        try await model.settle()
        #expect(model.items.first?.status == .clean)
        #expect(recorder.terminateCount == 0)
        #expect(recorder.confirmations.isEmpty)
    }

    @Test("A cold-launch tokened remove processes silently, notifies, and terminates")
    func coldLaunchTokenedRemoveRunsToTermination() async throws {
        let url = try sandbox.file(quarantined: true)
        let store = ServiceTokenStore(containerURL: sandbox.root)
        let token = try #require(store.issueToken())
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder, confirming: true, tokenStore: store)

        await model.handleIncomingRequest([url], quitAfter: true, token: token, isColdLaunch: true).value

        try await model.settle()
        #expect(recorder.terminateCount == 1)
        #expect(recorder.sessionStaysCount == 0)
        #expect(recorder.confirmations.isEmpty)
        #expect(model.items.first?.status == .clean)
        #expect(recorder.notifiedBatches.count == 1)
    }

    @Test("A cold request that never asked to quit hands its session to the window")
    func coldInteractiveRequestHandsBack() async throws {
        let url = try sandbox.file(quarantined: true)
        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder, confirming: true)

        await model.handleIncomingRequest([url], isColdLaunch: true).value

        #expect(recorder.sessionStaysCount == 1)
        try await model.settle()
    }

    @Test("An untrusted symlink alias into a blocked tree skips the dialog and surfaces a refusal")
    func symlinkAliasSkipsConfirmation() async throws {
        let link = try sandbox.symlink(to: URL(filePath: "/usr/bin"))
        let alias = link.appending(path: "true")

        let recorder = HandlerRecorder()
        let model = makeModel(recorder: recorder, confirming: true)

        await model.handleIncomingRequest([alias]).value

        try await model.settle()
        #expect(recorder.confirmations.isEmpty)
        #expect(model.items.map(\.status) == [.error(.blockedPath(alias))])
    }
}
