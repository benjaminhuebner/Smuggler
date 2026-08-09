import Foundation
import Testing

@testable import Smuggler

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

    private func cancelledItem(_ path: String) -> FileItem {
        FileItem(url: URL(filePath: path), status: .cancelled)
    }

    private func fileError(_ path: String) -> QuarantineFileError {
        QuarantineFileError(url: URL(filePath: path), error: .permissionDenied(URL(filePath: path)))
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

    @Test("Multiple failures without successes report the failure count")
    func multipleFailuresShowCount() {
        let items = [failedItem("/tmp/a.app"), failedItem("/tmp/b.app")]
        let (title, body) = NotificationService.buildContent(for: items)

        #expect(title == NotificationService.buildContent(for: [failedItem("/tmp/a.app")]).title)
        #expect(body.contains("2"))
    }

    @Test("Partial success reports cleaned-of-total counts")
    func partialReportsCounts() {
        let items = [cleanItem("/tmp/a.app"), cleanItem("/tmp/b.app"), failedItem("/tmp/c.app")]
        let (_, body) = NotificationService.buildContent(for: items)
        #expect(body.contains("2"))
        #expect(body.contains("3"))
    }

    @Test("Cancelled rows stay out of the partial-success total")
    func cancelledRowsAreNotCountedAsFailures() {
        let attempted = [cleanItem("/tmp/a.app"), failedItem("/tmp/b.app")]
        let withCancelled = attempted + (0..<8).map { cancelledItem("/tmp/c\($0).app") }

        #expect(
            NotificationService.buildContent(for: withCancelled).body
                == NotificationService.buildContent(for: attempted).body)
    }

    @Test("A partialSuccess item counts as success, yielding the partial title overall")
    func partialSuccessItemCountsAsSuccess() {
        let items = [
            FileItem(
                url: URL(filePath: "/tmp/a.app"),
                status: .partialSuccess(cleaned: 10, errors: [fileError("/tmp/a.app/x")]))
        ]
        let partialTitle = NotificationService.buildContent(for: items).title
        let allCleanTitle = NotificationService.buildContent(for: [cleanItem("/tmp/a.app")]).title
        #expect(partialTitle != allCleanTitle)
    }

    @Test("All-cancelled batch does not use the success title")
    func allCancelledIsNotSuccess() {
        let cancelledTitle = NotificationService.buildContent(
            for: [cancelledItem("/tmp/a.app"), cancelledItem("/tmp/b.app")]
        ).title
        let successTitle = NotificationService.buildContent(for: [cleanItem("/tmp/a.app")]).title
        let failureTitle = NotificationService.buildContent(for: [failedItem("/tmp/a.app")]).title

        #expect(cancelledTitle != successTitle)
        #expect(cancelledTitle != failureTitle)
    }

    @Test("An alreadyClean batch uses the success copy")
    func alreadyCleanUsesSuccessCopy() {
        let alreadyClean = [FileItem(url: URL(filePath: "/tmp/a.app"), status: .alreadyClean)]
        let successTitle = NotificationService.buildContent(for: [cleanItem("/tmp/a.app")]).title

        #expect(NotificationService.buildContent(for: alreadyClean).title == successTitle)
    }

    @Test("Empty item list is safe and returns a non-empty title")
    func emptyListIsSafe() {
        let (title, body) = NotificationService.buildContent(for: [])
        #expect(!title.isEmpty)
        #expect(body.isEmpty)
    }

    @Test("Cancelled rows do not count toward the ready total")
    func cancelledRowsNotCountedAsReady() {
        let items = [cleanItem("/tmp/a.app"), cleanItem("/tmp/b.app"), cancelledItem("/tmp/c.app")]
        let (title, body) = NotificationService.buildContent(for: items)

        #expect(title == NotificationService.buildContent(for: [cleanItem("/tmp/a.app")]).title)
        #expect(body.contains("2"))
        #expect(!body.contains("3"))
    }

    @Test("A single success plus cancelled rows names the successful file")
    func successWithCancelledNamesTheSuccessfulFile() {
        let items = [cancelledItem("/tmp/gone.app"), cleanItem("/tmp/MyApp.app")]
        let (_, body) = NotificationService.buildContent(for: items)

        #expect(body.contains("MyApp.app"))
        #expect(!body.contains("gone.app"))
    }

    @Test("Cancelled rows do not count toward the failure total")
    func cancelledRowsNotCountedAsFailed() {
        let items = [failedItem("/tmp/Broken.app"), cancelledItem("/tmp/b.app"), cancelledItem("/tmp/c.app")]
        let (_, body) = NotificationService.buildContent(for: items)

        #expect(body.contains("Broken.app"))
        #expect(!body.contains("3"))
    }
}

// MARK: - FileStatus Properties

@Suite("FileStatus")
struct FileStatusTests {
    private static let partial = FileStatus.partialSuccess(
        cleaned: 3,
        errors: [
            QuarantineFileError(url: URL(filePath: "/tmp/x"), error: .permissionDenied(URL(filePath: "/tmp/x")))
        ])

    @Test("A skipped subtree is an error, but not one the window can act on")
    func skippedSubtreeIsNotActionable() {
        let dir = URL(filePath: "/tmp/locked")
        let skipped = FileStatus.error(.unreadableDirectory(dir))
        #expect(skipped.hasErrors)
        #expect(!skipped.hasActionableErrors)

        let partialWithSkipOnly = FileStatus.partialSuccess(
            cleaned: 3,
            errors: [QuarantineFileError(url: dir, error: .unreadableDirectory(dir))])
        #expect(partialWithSkipOnly.hasErrors)
        #expect(!partialWithSkipOnly.hasActionableErrors)

        #expect(Self.partial.hasActionableErrors)
    }

    @Test("isSuccessful for each status")
    func isSuccessful() {
        #expect(FileStatus.processing.isSuccessful == false)
        #expect(FileStatus.clean.isSuccessful == true)
        #expect(FileStatus.alreadyClean.isSuccessful == true)
        #expect(FileStatus.cancelled.isSuccessful == false)
        #expect(Self.partial.isSuccessful == true)
        #expect(FileStatus.error(.fileNotFound(URL(filePath: "/tmp/x"))).isSuccessful == false)
    }

    @Test("hasErrors for each status")
    func hasErrors() {
        #expect(FileStatus.processing.hasErrors == false)
        #expect(FileStatus.clean.hasErrors == false)
        #expect(FileStatus.alreadyClean.hasErrors == false)
        #expect(FileStatus.cancelled.hasErrors == false)
        #expect(Self.partial.hasErrors == true)
        #expect(FileStatus.error(.fileNotFound(URL(filePath: "/tmp/x"))).hasErrors == true)
    }
}
