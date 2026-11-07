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
    let sandbox = TestSandbox()

    private var store: ServiceBatchStore { ServiceBatchStore(containerURL: sandbox.root) }
    private var batchesDirectory: URL { sandbox.root.appending(path: "ServiceBatches") }

    @Test("A written batch reads back once, a replay yields nothing")
    func replayedBatchIsEmpty() throws {
        let paths = ["/tmp/one.app", "/tmp/two.dmg"]
        let name = try #require(store.write(paths: paths))

        #expect(store.consume(name) == paths)
        #expect(store.consume(name).isEmpty)
    }

    @Test("Order and duplicates survive the round trip")
    func payloadRoundTripsExactly() throws {
        let paths = ["/tmp/b", "/tmp/a", "/tmp/b", "/tmp/Ünïcode – name.app", "/tmp/with\nnewline"]
        let name = try #require(store.write(paths: paths))

        #expect(store.consume(name) == paths)
    }

    @Test("A stale batch is rejected")
    func staleBatchIsEmpty() throws {
        let name = try #require(store.write(paths: ["/tmp/one.app"]))
        let file = batchesDirectory.appending(path: name)
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSinceNow: -(ServiceBatchStore.maxAge + 60))],
            ofItemAtPath: file.path(percentEncoded: false)
        )

        #expect(store.consume(name).isEmpty)
    }

    @Test("An empty path list is not written")
    func emptyPathsAreNotWritten() throws {
        #expect(store.write(paths: []) == nil)
    }

    @Test("A batch whose payload is not a path list yields nothing and is gone")
    func undecodablePayloadYieldsNothing() throws {
        let name = UUID().uuidString
        let file = try sandbox.directory("ServiceBatches").appending(path: name)
        try Data("not a path list".utf8).write(to: file)

        #expect(store.consume(name).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    }
}
