//
//  ServiceBatchStoreTests.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 10.08.26.
//

import Foundation
import Testing

@testable import Smuggler

@Suite("ServiceBatchStore")
struct ServiceBatchStoreTests {
    private func makeStore() throws -> (store: ServiceBatchStore, container: URL) {
        let container = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        return (ServiceBatchStore(containerURL: container), container)
    }

    @Test("A written batch reads back once, a replay yields nothing")
    func replayedBatchIsEmpty() throws {
        let (store, container) = try makeStore()
        defer { try? FileManager.default.removeItem(at: container) }

        let paths = ["/tmp/one.app", "/tmp/two.dmg"]
        let name = try #require(store.write(paths: paths))

        #expect(store.consume(name) == paths)
        #expect(store.consume(name).isEmpty)
    }

    @Test("Order and duplicates survive the round trip")
    func payloadRoundTripsExactly() throws {
        let (store, container) = try makeStore()
        defer { try? FileManager.default.removeItem(at: container) }

        let paths = ["/tmp/b", "/tmp/a", "/tmp/b", "/tmp/Ünïcode – name.app", "/tmp/with\nnewline"]
        let name = try #require(store.write(paths: paths))

        #expect(store.consume(name) == paths)
    }

    @Test("A stale batch is rejected")
    func staleBatchIsEmpty() throws {
        let (store, container) = try makeStore()
        defer { try? FileManager.default.removeItem(at: container) }

        let name = try #require(store.write(paths: ["/tmp/one.app"]))
        let file = container.appending(path: "ServiceBatches").appending(path: name)
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSinceNow: -(ServiceBatchStore.defaultMaxAge + 60))],
            ofItemAtPath: file.path(percentEncoded: false)
        )

        #expect(store.consume(name).isEmpty)
    }

    @Test("A batch whose file cannot be deleted is refused rather than served")
    func undeletableBatchFailsClosed() throws {
        let (store, container) = try makeStore()
        let batchesDir = container.appending(path: "ServiceBatches")
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: batchesDir.path(percentEncoded: false))
            try? FileManager.default.removeItem(at: container)
        }

        let name = try #require(store.write(paths: ["/tmp/one.app"]))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: batchesDir.path(percentEncoded: false))

        #expect(store.consume(name).isEmpty)
    }

    @Test("Malformed batch names are rejected without touching the filesystem")
    func malformedNameIsEmpty() throws {
        let (store, container) = try makeStore()
        defer { try? FileManager.default.removeItem(at: container) }

        #expect(store.consume("not-a-uuid").isEmpty)
        #expect(store.consume("../../../etc/passwd").isEmpty)
        #expect(store.consume("").isEmpty)
    }

    @Test("A batch that was never written is rejected")
    func missingBatchIsEmpty() throws {
        let (store, container) = try makeStore()
        defer { try? FileManager.default.removeItem(at: container) }

        #expect(store.consume(UUID().uuidString).isEmpty)
    }

    @Test("An empty path list is not written")
    func emptyPathsAreNotWritten() throws {
        let (store, container) = try makeStore()
        defer { try? FileManager.default.removeItem(at: container) }

        #expect(store.write(paths: []) == nil)
    }

    @Test("Writing prunes stale batch files")
    func writePrunesStaleBatches() throws {
        let (store, container) = try makeStore()
        defer { try? FileManager.default.removeItem(at: container) }

        let stale = try #require(store.write(paths: ["/tmp/stale"]))
        let staleFile = container.appending(path: "ServiceBatches").appending(path: stale)
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSinceNow: -(ServiceBatchStore.defaultMaxAge + 60))],
            ofItemAtPath: staleFile.path(percentEncoded: false)
        )

        _ = try #require(store.write(paths: ["/tmp/fresh"]))

        #expect(!FileManager.default.fileExists(atPath: staleFile.path(percentEncoded: false)))
    }

    @Test("An unavailable group container fails safe")
    func unavailableContainerFailsSafe() {
        let store = ServiceBatchStore(containerURL: nil)

        #expect(store.write(paths: ["/tmp/one.app"]) == nil)
        #expect(store.consume(UUID().uuidString).isEmpty)
    }

    @Test("Consuming prunes stale batches left by flows that never came back")
    func consumePrunesStaleBatches() throws {
        let (store, container) = try makeStore()
        defer { try? FileManager.default.removeItem(at: container) }

        let stale = try #require(store.write(paths: ["/tmp/stale"]))
        let staleFile = container.appending(path: "ServiceBatches").appending(path: stale)
        let fresh = try #require(store.write(paths: ["/tmp/fresh"]))
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSinceNow: -(ServiceBatchStore.defaultMaxAge + 60))],
            ofItemAtPath: staleFile.path(percentEncoded: false)
        )

        #expect(store.consume(fresh) == ["/tmp/fresh"])

        #expect(!FileManager.default.fileExists(atPath: staleFile.path(percentEncoded: false)))
    }

    @Test("A batch whose payload cannot be decoded leaves no path list behind")
    func unreadablePayloadIsRemoved() throws {
        let (store, container) = try makeStore()
        defer { try? FileManager.default.removeItem(at: container) }

        let name = try #require(store.write(paths: ["/tmp/one.app"]))
        let file = container.appending(path: "ServiceBatches").appending(path: name)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: file.path(percentEncoded: false))

        #expect(store.consume(name).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    }

    @Test("A batched request resolves to the paths the batch carried")
    func requestedURLsReadsTheBatch() async throws {
        let (store, container) = try makeStore()
        defer { try? FileManager.default.removeItem(at: container) }

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

        let resolved = await IncomingRequest.requestedURLs(for: request)

        guard case .urls(let urls) = resolved else {
            Issue.record("Expected the direct paths to pass through, got \(resolved)")
            return
        }
        #expect(urls.map { $0.path(percentEncoded: false) } == ["/tmp/one.app"])
    }

    @Test("An invented batch name reads as a failed handover, not an empty selection")
    func invemtedBatchIsUnavailable() async throws {
        let (store, container) = try makeStore()
        defer { try? FileManager.default.removeItem(at: container) }

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
