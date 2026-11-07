//
//  ServiceRequestURLTests.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import Foundation
import Testing

@testable import Smuggler

nonisolated private let shapes: [ServiceRequestURLTests.Shape] = [ServiceAction.open, .remove].flatMap { action in
    [true, false].flatMap { quitAfter in
        [UUID().uuidString, nil].map { ServiceRequestURLTests.Shape(action: action, quitAfter: quitAfter, token: $0) }
    }
}

nonisolated private let selections: [[String]] = [
    ["/tmp/a.app"],
    ["/tmp/My App & Co.app", "/tmp/x#y?z+w%.dmg", "/tmp/a=b;c,d.app"],
    ["/tmp/line\nbreak", "/tmp/Ünïcode – name.app", "/tmp/ghost 👻.pkg"],
    ["/tmp/b", "/tmp/a", "/tmp/b"],
]

@Suite("ServiceRequestURL")
struct ServiceRequestURLTests {
    nonisolated struct Shape: Sendable, CustomTestStringConvertible {
        let action: ServiceAction
        let quitAfter: Bool
        let token: String?

        var testDescription: String {
            "\(action.rawValue), quitAfter \(quitAfter), token \(token == nil ? "absent" : "present")"
        }
    }

    private static let oversizedSelection = (0..<150).map { "/tmp/\($0)-" + String(repeating: "a", count: 60) + ".app" }

    let sandbox = TestSandbox()

    private var batchStore: ServiceBatchStore { ServiceBatchStore(containerURL: sandbox.root) }

    @Test(
        "A built request parses back to the paths, action, quit flag and token that went in",
        arguments: selections, shapes)
    func roundTrip(paths: [String], shape: Shape) throws {
        let url = try #require(
            ServiceRequestURL.make(
                paths: paths, action: shape.action, quitAfter: shape.quitAfter, token: shape.token,
                batchStore: batchStore))
        let request = try #require(IncomingRequest(url: url))

        #expect(request.urls.map { $0.path(percentEncoded: false) } == paths)
        #expect(request.action == shape.action)
        #expect(request.quitAfter == shape.quitAfter)
        #expect(request.token == shape.token)
        #expect(request.batchName == nil)
        #expect(IncomingRequest.requestsQuit(url) == shape.quitAfter)
    }

    @Test("The built URL keeps its literal spelling, so a renamed shared constant can't move the format unseen")
    func spellsTheWireFormat() throws {
        let url = try #require(
            ServiceRequestURL.make(
                paths: ["/tmp/a.app", "/tmp/b c.dmg"], action: .remove, quitAfter: true, token: "T",
                batchStore: batchStore))

        #expect(
            url.absoluteString
                == "smuggler://process?path=/tmp/a.app&path=/tmp/b%20c.dmg&action=remove&quitAfter=true&token=T")

        let minimal = try #require(
            ServiceRequestURL.make(
                paths: ["/tmp/a.app"], action: .open, quitAfter: false, token: nil, batchStore: batchStore))
        #expect(minimal.absoluteString == "smuggler://process?path=/tmp/a.app&action=open")
    }

    @Test("A selection too long for a URL travels as a batch that resolves to the same paths in order")
    func oversizedSelectionTravelsAsBatch() async throws {
        let token = UUID().uuidString
        let url = try #require(
            ServiceRequestURL.make(
                paths: Self.oversizedSelection, action: .remove, quitAfter: true, token: token, batchStore: batchStore))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        #expect(url.absoluteString.utf8.count <= ServiceRequestURL.maxDirectLength)
        #expect(!items.contains { $0.name == ServiceRequestURL.pathKey })

        let request = try #require(IncomingRequest(url: url))
        #expect(request.urls.isEmpty)
        #expect(request.batchName != nil)
        #expect(request.action == .remove)
        #expect(request.quitAfter)
        #expect(request.token == token)

        let resolved = await IncomingRequest.requestedURLs(for: request, batchStore: batchStore)
        guard case .urls(let urls) = resolved else {
            Issue.record("Expected the batch to resolve, got \(resolved)")
            return
        }
        #expect(urls.map { $0.path(percentEncoded: false) } == Self.oversizedSelection)
    }

    @Test("When the batch can't be written, the direct URL still goes out and parses")
    func batchWriteFailureFallsBackToTheDirectURL() throws {
        let url = try #require(
            ServiceRequestURL.make(
                paths: Self.oversizedSelection, action: .open, quitAfter: true, token: nil,
                batchStore: ServiceBatchStore(containerURL: nil)))
        let request = try #require(IncomingRequest(url: url))

        #expect(url.absoluteString.utf8.count > ServiceRequestURL.maxDirectLength)
        #expect(request.batchName == nil)
        #expect(request.urls.map { $0.path(percentEncoded: false) } == Self.oversizedSelection)
    }

    @Test("A URL exactly at the limit stays direct, one byte more travels as a batch")
    func limitIsInclusive() throws {
        let overhead = try url(for: "/").absoluteString.utf8.count - 1
        let atLimit = "/" + String(repeating: "a", count: ServiceRequestURL.maxDirectLength - overhead - 1)

        let direct = try url(for: atLimit)
        let batched = try url(for: atLimit + "a")

        #expect(direct.absoluteString.utf8.count == ServiceRequestURL.maxDirectLength)
        #expect(try #require(IncomingRequest(url: direct)).batchName == nil)
        #expect(try #require(IncomingRequest(url: batched)).batchName != nil)
    }

    // 1,005 characters, but every "Ü" leaves the encoder as the six bytes "%C3%9C".
    @Test("The limit counts the encoded URL, not the characters of the paths")
    func limitCountsEncodedBytes() throws {
        let url = try url(for: "/tmp/" + String(repeating: "Ü", count: 1000))

        #expect(try #require(IncomingRequest(url: url)).batchName != nil)
    }

    private func url(for path: String) throws -> URL {
        try #require(
            ServiceRequestURL.make(
                paths: [path], action: .remove, quitAfter: true, token: UUID().uuidString, batchStore: batchStore))
    }
}
