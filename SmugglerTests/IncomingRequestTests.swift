//
//  IncomingRequestTests.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 09.08.26.
//

import Foundation
import Testing

@testable import Smuggler

@Suite("IncomingRequest")
struct IncomingRequestTests {
    let sandbox = TestSandbox()

    @Test("Defaults action to 'open' when missing")
    func defaultsActionToOpen() throws {
        let url = try #require(URL(string: "smuggler://process?path=/tmp/a.app"))
        let request = IncomingRequest(url: url)

        #expect(request?.action == .open)
    }

    @Test("Defaults quitAfter to false when missing")
    func defaultsQuitAfterToFalse() throws {
        let url = try #require(URL(string: "smuggler://process?path=/tmp/a.app"))
        let request = IncomingRequest(url: url)

        #expect(request?.quitAfter == false)
    }

    @Test("Returns nil for wrong scheme")
    func returnsNilForWrongScheme() throws {
        let url = try #require(URL(string: "https://process?path=/tmp/a.app"))
        #expect(IncomingRequest(url: url) == nil)
    }

    @Test("Returns nil for wrong host")
    func returnsNilForWrongHost() throws {
        let url = try #require(URL(string: "smuggler://launch?path=/tmp/a.app"))
        #expect(IncomingRequest(url: url) == nil)
    }

    @Test("Returns nil when path parameter is missing")
    func returnsNilForMissingPath() throws {
        let url = try #require(URL(string: "smuggler://process?action=open"))
        #expect(IncomingRequest(url: url) == nil)
    }

    @Test("Rejects unknown action parameter")
    func rejectsUnknownAction() throws {
        let url = try #require(URL(string: "smuggler://process?path=/tmp/a.app&action=delete"))
        #expect(IncomingRequest(url: url) == nil)
    }

    @Test("Parsing keeps blocked paths — refusal happens in the processing pipeline")
    func parseKeepsBlockedPaths() throws {
        let url = try #require(
            URL(string: "smuggler://process?path=/tmp/a.app&path=/usr/bin/true&action=remove"))
        let request = try #require(IncomingRequest(url: url))

        #expect(request.urls.count == 2)
    }

    @Test("Parses paths without checking existence (validation happens at call site)")
    func parsesNonExistentPaths() throws {
        let url = try #require(URL(string: "smuggler://process?path=/nonexistent/\(UUID().uuidString)"))
        let request = IncomingRequest(url: url)
        #expect(request != nil)
        #expect(request?.urls.count == 1)
    }

    @Test("Rejects a request whose only path value is empty")
    func rejectsEmptyPathValue() throws {
        let url = try #require(URL(string: "smuggler://process?path=&action=remove"))
        #expect(IncomingRequest(url: url) == nil)
    }

    @Test("Drops empty and relative path values but keeps absolute ones")
    func dropsNonAbsolutePathValues() throws {
        let url = try #require(
            URL(string: "smuggler://process?path=&path=relative/a.app&path=/tmp/a.app"))
        let request = try #require(IncomingRequest(url: url))

        #expect(request.urls.map { $0.path(percentEncoded: false) } == ["/tmp/a.app"])
    }

    @Test("Accepts scheme and host case-insensitively")
    func acceptsCaseInsensitiveSchemeAndHost() throws {
        let url = try #require(URL(string: "SMUGGLER://Process?path=/tmp/a.app"))
        #expect(IncomingRequest(url: url) != nil)
    }

    @Test("quitAfter accepts true spellings case-insensitively", arguments: ["true", "True", "TRUE", "1"])
    func quitAfterTruthySpellings(value: String) throws {
        let url = try #require(URL(string: "smuggler://process?path=/tmp/a.app&quitAfter=\(value)"))
        #expect(IncomingRequest(url: url)?.quitAfter == true)
    }

    @Test("quitAfter treats non-true values as false", arguments: ["false", "False", "0"])
    func quitAfterFalsySpellings(value: String) throws {
        let url = try #require(URL(string: "smuggler://process?path=/tmp/a.app&quitAfter=\(value)"))
        #expect(IncomingRequest(url: url)?.quitAfter == false)
    }

    @Test("Parsing touches no filesystem, so a directory keeps its plain path form")
    func parsingDoesNotStatPaths() throws {
        let dir = try sandbox.directory()

        let path = dir.path(percentEncoded: false)
        let url = try #require(URL(string: "smuggler://process?path=\(path)&action=remove"))
        let request = try #require(IncomingRequest(url: url))

        #expect(!request.urls[0].hasDirectoryPath)
    }

    @Test("The off-main filter resolves a directory named without a trailing slash")
    func filterYieldsDirectoryURL() async throws {
        let dir = try sandbox.directory()

        let path = dir.path(percentEncoded: false)
        let url = try #require(URL(string: "smuggler://process?path=\(path)&action=remove"))
        let request = try #require(IncomingRequest(url: url))

        let (urls, removableURLs) = await IncomingRequest.resolvedURLs(from: request.urls)

        #expect(urls[0].hasDirectoryPath)
        #expect(urls[0] == URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL)
        #expect(removableURLs == urls)
    }

    @Test("The off-main filter drops a path only when nothing is there")
    func filterDropsOnlyAbsentPaths() async throws {
        let file = try sandbox.file()
        let missing = sandbox.url()
        let underFile = file.appending(path: "child")

        let (urls, removableURLs) = await IncomingRequest.resolvedURLs(from: [missing, underFile, file])

        #expect(urls == [file])
        #expect(removableURLs == [file])
    }

    @Test("The off-main filter keeps what it cannot look at, for the walk to report")
    func filterKeepsWhatItCannotStat() async throws {
        let lockedFolder = try sandbox.directory()
        let unreachable = try sandbox.file(in: lockedFolder)
        try sandbox.lock(lockedFolder)
        let dangling = try sandbox.symlink(to: sandbox.url())

        let (urls, removableURLs) = await IncomingRequest.resolvedURLs(from: [unreachable, dangling])

        #expect(urls == [unreachable, dangling])
        #expect(removableURLs == urls)
    }

    @Test("The off-main filter keeps the Data volume's mount point as a refusal, never as removable")
    func filterKeepsDataVolumeRootAsRefusal() async {
        let (urls, removableURLs) = await IncomingRequest.resolvedURLs(from: [URL(filePath: "/System/Volumes/Data")])

        #expect(urls.map { $0.path(percentEncoded: false) } == ["/System/Volumes/Data/"])
        #expect(removableURLs.isEmpty)
    }

    @Test("The off-main filter yields nothing once its task is cancelled")
    func filterStopsWhenCancelled() async throws {
        let dir = try sandbox.directory()

        let result = try await withThrowingTaskGroup(of: (urls: [URL], removableURLs: [URL]).self) { group in
            // A child added to a cancelled group starts cancelled.
            group.cancelAll()
            group.addTask { await IncomingRequest.resolvedURLs(from: [dir]) }
            return try #require(try await group.next())
        }

        #expect(result.urls.isEmpty)
        #expect(result.removableURLs.isEmpty)
    }

    @Test("quitAfter is readable from a URL the parser rejects")
    func quitAfterReadableWithoutParse() throws {
        let url = try #require(URL(string: "smuggler://process?path=relative/a.app&quitAfter=true"))

        #expect(IncomingRequest(url: url) == nil)
        #expect(IncomingRequest.requestsQuit(url))
    }

    @Test("A batched request resolves to the paths the batch carried")
    func requestedURLsReadsTheBatch() async throws {
        let store = ServiceBatchStore(containerURL: sandbox.root)
        let name = try #require(store.write(paths: ["/tmp/one.app", "relative/skipped", "/tmp/two.dmg"]))
        let url = try #require(URL(string: "smuggler://process?batch=\(name)&action=remove"))
        let request = try #require(IncomingRequest(url: url))

        let resolved = await IncomingRequest.requestedURLs(for: request, batchStore: store)

        guard case .urls(let urls) = resolved else {
            Issue.record("Expected the batch to resolve, got \(resolved)")
            return
        }
        #expect(urls.map { $0.path(percentEncoded: false) } == ["/tmp/one.app", "/tmp/two.dmg"])
    }

    @Test("A request without a batch keeps the paths it carried in the URL")
    func requestedURLsPassesDirectPathsThrough() async throws {
        let url = try #require(URL(string: "smuggler://process?path=/tmp/one.app&action=remove"))
        let request = try #require(IncomingRequest(url: url))
        let store = ServiceBatchStore(containerURL: nil)

        let resolved = await IncomingRequest.requestedURLs(for: request, batchStore: store)

        guard case .urls(let urls) = resolved else {
            Issue.record("Expected the direct paths to pass through, got \(resolved)")
            return
        }
        #expect(urls.map { $0.path(percentEncoded: false) } == ["/tmp/one.app"])
    }

    @Test("An invented batch name reads as a failed handover, not an empty selection")
    func inventedBatchIsUnavailable() async throws {
        let store = ServiceBatchStore(containerURL: sandbox.root)
        let url = try #require(URL(string: "smuggler://process?batch=\(UUID().uuidString)&action=remove"))
        let request = try #require(IncomingRequest(url: url))

        let resolved = await IncomingRequest.requestedURLs(for: request, batchStore: store)

        #expect(resolved.isBatchUnavailable)
    }
}

extension RequestedURLs {
    fileprivate var isBatchUnavailable: Bool {
        if case .batchUnavailable = self { true } else { false }
    }
}
