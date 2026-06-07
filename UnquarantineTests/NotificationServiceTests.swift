//
//  NotificationServiceTests.swift
//  Unquarantine
//
//  Created by Benjamin Hübner on 21.03.26.
//

import Foundation
import Testing

@testable import Unquarantine

@Suite("NotificationService — Content Building")
struct NotificationServiceTests {
    // Assertions check branch selection and dynamic content (file name / counts),
    // not exact localized text, so they stay valid regardless of the test locale.

    private func cleanItem(_ path: String) -> FileItem {
        FileItem(url: URL(filePath: path), status: .clean)
    }

    private func failedItem(_ path: String) -> FileItem {
        FileItem(url: URL(filePath: path), status: .error(.permissionDenied(URL(filePath: path))))
    }

    @Test("Success, partial, and failure produce distinct titles")
    func titlesAreDistinct() {
        let successTitle = NotificationService.buildContent(for: [cleanItem("/tmp/a.app")]).title
        let failureTitle = NotificationService.buildContent(for: [failedItem("/tmp/a.app")]).title
        let partialTitle = NotificationService.buildContent(
            for: [cleanItem("/tmp/a.app"), failedItem("/tmp/b.app")]
        ).title

        #expect(successTitle != failureTitle)
        #expect(successTitle != partialTitle)
        #expect(failureTitle != partialTitle)
    }

    @Test("Single successful item names the file in the body")
    func singleSuccessNamesFile() {
        let (_, body) = NotificationService.buildContent(for: [cleanItem("/tmp/MyApp.app")])
        #expect(body.contains("MyApp.app"))
    }

    @Test("Multiple successful items show the total count in the body")
    func multipleSuccessShowsCount() {
        let items = (0..<3).map { cleanItem("/tmp/\($0).app") }
        let (_, body) = NotificationService.buildContent(for: items)
        #expect(body.contains("3"))
    }

    @Test("Single failure names the file in the body")
    func singleFailureNamesFile() {
        let (_, body) = NotificationService.buildContent(for: [failedItem("/tmp/MyApp.app")])
        #expect(body.contains("MyApp.app"))
    }

    @Test("Partial success reports cleaned-of-total counts")
    func partialReportsCounts() {
        let items = [cleanItem("/tmp/a.app"), cleanItem("/tmp/b.app"), failedItem("/tmp/c.app")]
        let (_, body) = NotificationService.buildContent(for: items)
        #expect(body.contains("2"))
        #expect(body.contains("3"))
    }

    @Test("A partialSuccess item counts as success, yielding the partial title overall")
    func partialSuccessItemCountsAsSuccess() {
        let items = [FileItem(url: URL(filePath: "/tmp/a.app"), status: .partialSuccess(cleaned: 10, failed: 2))]
        let partialTitle = NotificationService.buildContent(for: items).title
        let allCleanTitle = NotificationService.buildContent(for: [cleanItem("/tmp/a.app")]).title
        #expect(partialTitle != allCleanTitle)
    }

    @Test("Empty item list is safe and returns a non-empty title")
    func emptyListIsSafe() {
        let (title, body) = NotificationService.buildContent(for: [])
        #expect(!title.isEmpty)
        #expect(body.isEmpty)
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
