//
//  SingleUseFileStoreTests.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import Foundation
import Testing

@testable import Smuggler

@Suite("SingleUseFileStore")
struct SingleUseFileStoreTests {
    private static let maxAge: TimeInterval = 60

    let sandbox = TestSandbox()

    private var store: SingleUseFileStore {
        SingleUseFileStore(containerURL: sandbox.root, subdirectory: "Store", maxAge: Self.maxAge)
    }

    private var directory: URL { sandbox.root.appending(path: "Store") }

    private func backdate(_ name: String, by age: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSinceNow: -age)],
            ofItemAtPath: directory.appending(path: name).path(percentEncoded: false))
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appending(path: name).path(percentEncoded: false))
    }

    @Test("A payload reads back once, a replay yields nothing")
    func payloadIsServedOnce() throws {
        let payload = Data("payload".utf8)
        let name = try #require(store.issue(payload))

        #expect(store.consume(name) == payload)
        #expect(store.consume(name) == nil)
    }

    @Test(
        "A file inside its age limit is served, one past it is not",
        arguments: [(offsetFromLimit: -5.0, served: true), (offsetFromLimit: 60.0, served: false)])
    func ageLimitDecidesService(offsetFromLimit: TimeInterval, served: Bool) throws {
        let name = try #require(store.issue(Data("payload".utf8)))
        try backdate(name, by: Self.maxAge + offsetFromLimit)

        #expect((store.consume(name) != nil) == served)
    }

    @Test(
        "A file dated ahead of the clock is served only within the slack, and never survives",
        arguments: [(aheadBy: 1.0, served: true), (aheadBy: 3600.0, served: false)])
    func futureDateDecidesService(aheadBy: TimeInterval, served: Bool) throws {
        let name = try #require(store.issue(Data("payload".utf8)))
        try backdate(name, by: -aheadBy)

        #expect((store.consume(name) != nil) == served)
        #expect(!exists(name))
    }

    @Test("A file that cannot be deleted is refused rather than risk serving it twice")
    func undeletableFileIsRefused() throws {
        let name = try #require(store.issue(Data("payload".utf8)))
        try sandbox.lock(directory, permissions: 0o555)

        #expect(store.consume(name) == nil)
    }

    @Test(
        "A name that is not a UUID is refused and leaves the store alone",
        arguments: ["", "not-a-uuid", "../../../etc/passwd"])
    func malformedNameIsRefused(name: String) throws {
        let sibling = try #require(store.issue(Data("payload".utf8)))

        #expect(store.consume(name) == nil)
        #expect(exists(sibling))
    }

    @Test("A file planted under a name that is not a UUID is never served")
    func plantedFileUnderMalformedNameIsRefused() throws {
        try sandbox.file("not-a-uuid", in: directory)

        #expect(store.consume("not-a-uuid") == nil)
        #expect(exists("not-a-uuid"))
    }

    @Test("A name that was never issued is refused")
    func missingFileIsRefused() {
        #expect(store.consume(UUID().uuidString) == nil)
    }

    @Test("Without a container nothing is issued or served")
    func missingContainerFailsSafe() {
        let store = SingleUseFileStore(containerURL: nil, subdirectory: "Store", maxAge: Self.maxAge)

        #expect(store.issue(Data("payload".utf8)) == nil)
        #expect(store.consume(UUID().uuidString) == nil)
    }

    @Test("Issuing prunes files past their age limit")
    func issuePrunesStaleFiles() throws {
        let stale = try #require(store.issue(Data("stale".utf8)))
        try backdate(stale, by: Self.maxAge + 60)

        _ = try #require(store.issue(Data("fresh".utf8)))

        #expect(!exists(stale))
    }

    @Test("Issuing prunes files dated ahead of the clock")
    func issuePrunesFutureDatedFiles() throws {
        let future = try #require(store.issue(Data("future".utf8)))
        try backdate(future, by: -3600)

        _ = try #require(store.issue(Data("fresh".utf8)))

        #expect(!exists(future))
    }

    @Test("Consuming prunes files left by flows that never came back")
    func consumePrunesStaleFiles() throws {
        let stale = try #require(store.issue(Data("stale".utf8)))
        let fresh = try #require(store.issue(Data("fresh".utf8)))
        try backdate(stale, by: Self.maxAge + 60)

        #expect(store.consume(fresh) == Data("fresh".utf8))
        #expect(!exists(stale))
    }

    @Test("An unreadable file is refused and removed")
    func unreadableFileIsRemoved() throws {
        let name = try #require(store.issue(Data("payload".utf8)))
        try sandbox.lock(directory.appending(path: name))

        #expect(store.consume(name) == nil)
        #expect(!exists(name))
    }

    @Test("A folder planted under a valid name is refused")
    func folderUnderValidNameIsRefused() throws {
        let name = UUID().uuidString
        _ = try sandbox.directory(name, in: directory)

        #expect(store.consume(name) == nil)
    }
}
