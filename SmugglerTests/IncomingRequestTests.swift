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
    @Test("Parses valid smuggler://process URL with single path")
    func parsesSinglePath() throws {
        let url = try #require(URL(string: "smuggler://process?path=/tmp/MyApp.app&action=open&quitAfter=true"))
        let request = IncomingRequest(url: url)

        #expect(request != nil)
        #expect(request?.urls.count == 1)
        #expect(request?.urls[0].path(percentEncoded: false) == "/tmp/MyApp.app")
        #expect(request?.action == .open)
        #expect(request?.quitAfter == true)
    }

    @Test("Parses URL with multiple path parameters")
    func parsesMultiplePaths() throws {
        let url = try #require(URL(string: "smuggler://process?path=/tmp/a.app&path=/tmp/b.dmg"))
        let request = IncomingRequest(url: url)

        #expect(request != nil)
        #expect(request?.urls.count == 2)
    }

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

    @Test("Parses action=remove correctly")
    func parsesRemoveAction() throws {
        let url = try #require(URL(string: "smuggler://process?path=/tmp/a.app&action=remove"))
        let request = IncomingRequest(url: url)

        #expect(request?.action == .remove)
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

    @Test("Parsed URL request carries its token through")
    func parseExtractsToken() throws {
        let token = UUID().uuidString
        let url = try #require(
            URL(string: "smuggler://process?path=/tmp/a.app&action=remove&token=\(token)"))
        let request = try #require(IncomingRequest(url: url))

        #expect(request.token == token)
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

    // The Finder extension percent-encodes every path via URLComponents, so any
    // file name with a space or query-delimiter character takes this route.
    @Test("Percent-encoded path values decode to their filesystem path")
    func decodesPercentEncodedPaths() throws {
        let url = try #require(
            URL(string: "smuggler://process?path=/tmp/My%20App%20%26%20Co.app&action=remove"))
        let request = try #require(IncomingRequest(url: url))

        #expect(request.urls.map { $0.path(percentEncoded: false) } == ["/tmp/My App & Co.app"])
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
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.path(percentEncoded: false)
        let url = try #require(URL(string: "smuggler://process?path=\(path)&action=remove"))
        let request = try #require(IncomingRequest(url: url))

        #expect(!request.urls[0].hasDirectoryPath)
    }

    @Test("The off-main filter resolves a directory named without a trailing slash")
    func filterYieldsDirectoryURL() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.path(percentEncoded: false)
        let url = try #require(URL(string: "smuggler://process?path=\(path)&action=remove"))
        let request = try #require(IncomingRequest(url: url))

        let (urls, removableURLs) = await IncomingRequest.resolvedURLs(from: request.urls)

        #expect(urls[0].hasDirectoryPath)
        #expect(urls[0] == URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL)
        #expect(removableURLs == urls)
    }

    @Test("quitAfter is readable from a URL the parser rejects")
    func quitAfterReadableWithoutParse() throws {
        let url = try #require(URL(string: "smuggler://process?path=relative/a.app&quitAfter=true"))

        #expect(IncomingRequest(url: url) == nil)
        #expect(IncomingRequest.requestsQuit(url))
    }
}
