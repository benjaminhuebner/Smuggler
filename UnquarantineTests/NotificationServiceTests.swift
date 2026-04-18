//
//  NotificationServiceTests.swift
//  Unquarantine
//
//  Created by Benjamin Hübner on 21.03.26.
//

import Testing
import Foundation
@testable import Unquarantine

@Suite("NotificationService — Content Building")
struct NotificationServiceTests {

    // MARK: - Success

    @Test("Single successful item shows file name")
    func singleSuccess() {
        let items = [FileItem(url: URL(filePath: "/tmp/MyApp.app"), status: .clean)]
        let (title, body) = NotificationService.buildContent(for: items)
        let name = "MyApp.app"
        #expect(title == String(localized: "Quarantine Removed", comment: "Notification title: success"))
        #expect(body == String(localized: "\(name) is ready to use.", comment: "Notification body: single file success"))
    }

    @Test("Multiple successful items shows count")
    func multipleSuccess() {
        let items = [
            FileItem(url: URL(filePath: "/tmp/a.app"), status: .clean),
            FileItem(url: URL(filePath: "/tmp/b.dmg"), status: .clean),
            FileItem(url: URL(filePath: "/tmp/c.zip"), status: .clean),
        ]
        let (title, body) = NotificationService.buildContent(for: items)
        #expect(title == String(localized: "Quarantine Removed", comment: "Notification title: success"))
        #expect(body == String(localized: "\(3) items are ready to use.", comment: "Notification body: multiple files success"))
    }

    // MARK: - Failure

    @Test("Single failed item shows file name")
    func singleFailure() {
        let items = [
            FileItem(url: URL(filePath: "/tmp/MyApp.app"), status: .error(.permissionDenied(URL(filePath: "/tmp/MyApp.app")))),
        ]
        let (title, body) = NotificationService.buildContent(for: items)
        let name = "MyApp.app"
        #expect(title == String(localized: "Quarantine Removal Failed", comment: "Notification title: failure"))
        #expect(body == String(localized: "Could not remove quarantine from \(name).", comment: "Notification body: single file failure"))
    }

    @Test("Multiple failed items shows count")
    func multipleFailure() {
        let items = [
            FileItem(url: URL(filePath: "/tmp/a.app"), status: .error(.permissionDenied(URL(filePath: "/tmp/a.app")))),
            FileItem(url: URL(filePath: "/tmp/b.dmg"), status: .error(.permissionDenied(URL(filePath: "/tmp/b.dmg")))),
        ]
        let (title, body) = NotificationService.buildContent(for: items)
        #expect(title == String(localized: "Quarantine Removal Failed", comment: "Notification title: failure"))
        #expect(body == String(localized: "Could not remove quarantine from \(2) items.", comment: "Notification body: multiple files failure"))
    }

    // MARK: - Partial

    @Test("Mixed results shows partial title with counts")
    func partialSuccess() {
        let items = [
            FileItem(url: URL(filePath: "/tmp/a.app"), status: .clean),
            FileItem(url: URL(filePath: "/tmp/b.app"), status: .clean),
            FileItem(url: URL(filePath: "/tmp/c.app"), status: .error(.permissionDenied(URL(filePath: "/tmp/c.app")))),
        ]
        let (title, body) = NotificationService.buildContent(for: items)
        #expect(title == String(localized: "Quarantine Partially Removed", comment: "Notification title: partial success"))
        #expect(body == String(localized: "\(2) of \(3) items cleaned. Some items had errors.", comment: "Notification body: partial success"))
    }

    @Test("Partial success item counts as successful")
    func partialSuccessItem() {
        let items = [
            FileItem(url: URL(filePath: "/tmp/a.app"), status: .partialSuccess(cleaned: 10, failed: 2)),
        ]
        let (title, body) = NotificationService.buildContent(for: items)
        #expect(title == String(localized: "Quarantine Partially Removed", comment: "Notification title: partial success"))
        #expect(body == String(localized: "\(1) of \(1) items cleaned. Some items had errors.", comment: "Notification body: partial success"))
    }

    @Test("Mix of clean and partial success items")
    func cleanAndPartialMix() {
        let items = [
            FileItem(url: URL(filePath: "/tmp/a.app"), status: .clean),
            FileItem(url: URL(filePath: "/tmp/b.app"), status: .partialSuccess(cleaned: 5, failed: 1)),
        ]
        let (title, body) = NotificationService.buildContent(for: items)
        #expect(title == String(localized: "Quarantine Partially Removed", comment: "Notification title: partial success"))
        #expect(body == String(localized: "\(2) of \(2) items cleaned. Some items had errors.", comment: "Notification body: partial success"))
    }
}

// MARK: - FileStatus Properties

@Suite("FileStatus")
struct FileStatusTests {

    @Test("isSuccessful for each status")
    func isSuccessful() {
        #expect(FileStatus.processing.isSuccessful == false)
        #expect(FileStatus.clean.isSuccessful == true)
        #expect(FileStatus.partialSuccess(cleaned: 3, failed: 1).isSuccessful == true)
        #expect(FileStatus.error(.fileNotFound(URL(filePath: "/tmp/x"))).isSuccessful == false)
    }

    @Test("hasErrors for each status")
    func hasErrors() {
        #expect(FileStatus.processing.hasErrors == false)
        #expect(FileStatus.clean.hasErrors == false)
        #expect(FileStatus.partialSuccess(cleaned: 3, failed: 1).hasErrors == true)
        #expect(FileStatus.error(.fileNotFound(URL(filePath: "/tmp/x"))).hasErrors == true)
    }
}
