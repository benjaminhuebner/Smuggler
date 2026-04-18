//
//  AppModelTests.swift
//  Unquarantine
//
//  Created by Benjamin Hübner on 21.03.26.
//

import Testing
import Foundation
@testable import Unquarantine

@Suite("AppModel — URL Parsing")
struct AppModelURLParsingTests {

    @Test("Parses valid unquarantine://process URL with single path")
    func parsesSinglePath() {
        let url = URL(string: "unquarantine://process?path=/tmp/MyApp.app&action=open&quitAfter=true")!
        let request = AppModel.parseIncomingURL(url)

        #expect(request != nil)
        #expect(request?.urls.count == 1)
        #expect(request?.urls[0].path(percentEncoded: false) == "/tmp/MyApp.app")
        #expect(request?.action == "open")
        #expect(request?.quitAfter == true)
    }

    @Test("Parses URL with multiple path parameters")
    func parsesMultiplePaths() {
        let url = URL(string: "unquarantine://process?path=/tmp/a.app&path=/tmp/b.dmg")!
        let request = AppModel.parseIncomingURL(url)

        #expect(request != nil)
        #expect(request?.urls.count == 2)
    }

    @Test("Defaults action to 'open' when missing")
    func defaultsActionToOpen() {
        let url = URL(string: "unquarantine://process?path=/tmp/a.app")!
        let request = AppModel.parseIncomingURL(url)

        #expect(request?.action == "open")
    }

    @Test("Defaults quitAfter to false when missing")
    func defaultsQuitAfterToFalse() {
        let url = URL(string: "unquarantine://process?path=/tmp/a.app")!
        let request = AppModel.parseIncomingURL(url)

        #expect(request?.quitAfter == false)
    }

    @Test("Returns nil for wrong scheme")
    func returnsNilForWrongScheme() {
        let url = URL(string: "https://process?path=/tmp/a.app")!
        #expect(AppModel.parseIncomingURL(url) == nil)
    }

    @Test("Returns nil for wrong host")
    func returnsNilForWrongHost() {
        let url = URL(string: "unquarantine://launch?path=/tmp/a.app")!
        #expect(AppModel.parseIncomingURL(url) == nil)
    }

    @Test("Returns nil when path parameter is missing")
    func returnsNilForMissingPath() {
        let url = URL(string: "unquarantine://process?action=open")!
        #expect(AppModel.parseIncomingURL(url) == nil)
    }

    @Test("Parses action=remove correctly")
    func parsesRemoveAction() {
        let url = URL(string: "unquarantine://process?path=/tmp/a.app&action=remove")!
        let request = AppModel.parseIncomingURL(url)

        #expect(request?.action == "remove")
    }

    @Test("Rejects unknown action parameter")
    func rejectsUnknownAction() {
        let url = URL(string: "unquarantine://process?path=/tmp/a.app&action=delete")!
        #expect(AppModel.parseIncomingURL(url) == nil)
    }

    @Test("Parses paths without checking existence (validation happens at call site)")
    func parsesNonExistentPaths() {
        let url = URL(string: "unquarantine://process?path=/nonexistent/\(UUID().uuidString)")!
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
