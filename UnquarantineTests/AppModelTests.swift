//
//  AppModelTests.swift
//  Unquarantine
//
//  Created by Benjamin Hübner on 21.03.26.
//

import Foundation
import Testing

@testable import Unquarantine

@Suite("AppModel — URL Parsing")
struct AppModelURLParsingTests {
    @Test("Parses valid unquarantine://process URL with single path")
    func parsesSinglePath() throws {
        let url = try #require(URL(string: "unquarantine://process?path=/tmp/MyApp.app&action=open&quitAfter=true"))
        let request = AppModel.parseIncomingURL(url)

        #expect(request != nil)
        #expect(request?.urls.count == 1)
        #expect(request?.urls[0].path(percentEncoded: false) == "/tmp/MyApp.app")
        #expect(request?.action == "open")
        #expect(request?.quitAfter == true)
    }

    @Test("Parses URL with multiple path parameters")
    func parsesMultiplePaths() throws {
        let url = try #require(URL(string: "unquarantine://process?path=/tmp/a.app&path=/tmp/b.dmg"))
        let request = AppModel.parseIncomingURL(url)

        #expect(request != nil)
        #expect(request?.urls.count == 2)
    }

    @Test("Defaults action to 'open' when missing")
    func defaultsActionToOpen() throws {
        let url = try #require(URL(string: "unquarantine://process?path=/tmp/a.app"))
        let request = AppModel.parseIncomingURL(url)

        #expect(request?.action == "open")
    }

    @Test("Defaults quitAfter to false when missing")
    func defaultsQuitAfterToFalse() throws {
        let url = try #require(URL(string: "unquarantine://process?path=/tmp/a.app"))
        let request = AppModel.parseIncomingURL(url)

        #expect(request?.quitAfter == false)
    }

    @Test("Returns nil for wrong scheme")
    func returnsNilForWrongScheme() throws {
        let url = try #require(URL(string: "https://process?path=/tmp/a.app"))
        #expect(AppModel.parseIncomingURL(url) == nil)
    }

    @Test("Returns nil for wrong host")
    func returnsNilForWrongHost() throws {
        let url = try #require(URL(string: "unquarantine://launch?path=/tmp/a.app"))
        #expect(AppModel.parseIncomingURL(url) == nil)
    }

    @Test("Returns nil when path parameter is missing")
    func returnsNilForMissingPath() throws {
        let url = try #require(URL(string: "unquarantine://process?action=open"))
        #expect(AppModel.parseIncomingURL(url) == nil)
    }

    @Test("Parses action=remove correctly")
    func parsesRemoveAction() throws {
        let url = try #require(URL(string: "unquarantine://process?path=/tmp/a.app&action=remove"))
        let request = AppModel.parseIncomingURL(url)

        #expect(request?.action == "remove")
    }

    @Test("Rejects unknown action parameter")
    func rejectsUnknownAction() throws {
        let url = try #require(URL(string: "unquarantine://process?path=/tmp/a.app&action=delete"))
        #expect(AppModel.parseIncomingURL(url) == nil)
    }

    @Test("Parses paths without checking existence (validation happens at call site)")
    func parsesNonExistentPaths() throws {
        let url = try #require(URL(string: "unquarantine://process?path=/nonexistent/\(UUID().uuidString)"))
        let request = AppModel.parseIncomingURL(url)
        #expect(request != nil)
        #expect(request?.urls.count == 1)
    }
}

@Suite("AppModel — Enqueue")
@MainActor
struct AppModelEnqueueTests {
    @Test("Enqueue adds items with processing status")
    func enqueueAddsItems() {
        let model = AppModel()
        let urls = [URL(filePath: "/tmp/a.app"), URL(filePath: "/tmp/b.app")]

        model.enqueue(urls: urls)

        #expect(model.items.count == 2)
        #expect(model.items.allSatisfy { $0.status == .processing })
    }

    @Test("Enqueue does not duplicate existing URLs")
    func enqueueDeduplicates() {
        let model = AppModel()
        let url = URL(filePath: "/tmp/a.app")

        model.enqueue(urls: [url])
        model.enqueue(urls: [url])

        #expect(model.items.count == 1)
    }

    @Test("Enqueue inserts at the beginning")
    func enqueueInsertsAtBeginning() {
        let model = AppModel()
        model.enqueue(urls: [URL(filePath: "/tmp/first.app")])
        model.enqueue(urls: [URL(filePath: "/tmp/second.app")])

        #expect(model.items[0].name == "second.app")
        #expect(model.items[1].name == "first.app")
    }

    @Test("Clear removes all items")
    func clearRemovesAllItems() {
        let model = AppModel()
        model.enqueue(urls: [URL(filePath: "/tmp/a.app")])

        model.clear()

        #expect(model.items.isEmpty)
    }
}

@Suite("AppModel — Processing")
@MainActor
struct AppModelProcessingTests {
    private func makeQuarantinedFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try "test".write(to: url, atomically: true, encoding: .utf8)
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            let value = "0001;00000000;Test;"
            _ = value.withCString { setxattr(path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
        }
        return url
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let start = ContinuousClock.now
        while !condition() {
            if ContinuousClock.now - start > timeout {
                Issue.record("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("process removes quarantine and marks the item clean")
    func processMarksClean() async throws {
        let url = try makeQuarantinedFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel(minimumProcessingDuration: .zero)

        await model.process(urls: [url])

        #expect(model.items.count == 1)
        #expect(model.items[0].status == .clean)
        #expect(model.isProcessing == false)
        #expect(model.cleanedCount == 1)
    }

    @Test("Duplicate URLs in one batch produce a single item")
    func processDeduplicatesBatch() async throws {
        let url = try makeQuarantinedFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel(minimumProcessingDuration: .zero)

        await model.process(urls: [url, url])

        #expect(model.items.count == 1)
        #expect(model.items[0].status == .clean)
    }

    // Regression: when the app is already open, the Services / Finder path passes
    // quitAfter == false. The processing task must still run.
    @Test("handleServiceURLs processes items when the app is already open")
    func serviceURLsProcessWhenAlreadyOpen() async throws {
        let url = try makeQuarantinedFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel(minimumProcessingDuration: .zero)

        model.handleServiceURLs([url], action: "remove", quitAfter: false)

        try await waitUntil { !model.items.isEmpty && model.items[0].status != .processing }
        #expect(model.items[0].status == .clean)
        #expect(model.isProcessing == false)
    }

    @Test("cancel marks a processing item as cancelled")
    func cancelMarksCancelled() {
        let model = AppModel()
        let entries = model.enqueue(urls: [URL(filePath: "/tmp/pending.app")])
        let id = entries[0].id

        #expect(model.isProcessing == true)
        model.cancel(id: id)

        #expect(model.items[0].status == .cancelled)
        #expect(model.isProcessing == false)
        #expect(model.allCancelled == true)
    }
}
