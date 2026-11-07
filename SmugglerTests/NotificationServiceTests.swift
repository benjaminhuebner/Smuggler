import Foundation
import Testing

@testable import Smuggler

@Suite("NotificationService — Content Building")
struct NotificationServiceTests {
    // Expectations go through String(localized:) with the service's own keys, so
    // they resolve in whatever language the test host runs. Names interpolate as
    // String and counts as Int, the types the keys were extracted with.
    private let removedTitle = String(localized: "Quarantine Removed")
    private let failedTitle = String(localized: "Quarantine Removal Failed")
    private let partialTitle = String(localized: "Quarantine Partially Removed")

    private func cleanItem(_ path: String) -> FileItem {
        FileItem(url: URL(filePath: path), status: .clean)
    }

    private func failedItem(_ path: String) -> FileItem {
        FileItem(url: URL(filePath: path), status: .error(.permissionDenied(URL(filePath: path))))
    }

    private func alreadyCleanItem(_ path: String) -> FileItem {
        FileItem(url: URL(filePath: path), status: .alreadyClean)
    }

    private func cancelledItem(_ path: String) -> FileItem {
        FileItem(url: URL(filePath: path), status: .cancelled)
    }

    private func fileError(_ path: String) -> QuarantineFileError {
        QuarantineFileError(url: URL(filePath: path), error: .permissionDenied(URL(filePath: path)))
    }

    @Test("Single successful item names the file in the body")
    func singleSuccessNamesFile() {
        let name = "MyApp.app"
        let (title, body) = NotificationService.buildContent(for: [cleanItem("/tmp/\(name)")])

        #expect(title == removedTitle)
        #expect(body == String(localized: "\(name) is ready to use."))
    }

    @Test("Multiple successful items show the total count in the body")
    func multipleSuccessShowsCount() {
        let items = (0..<3).map { cleanItem("/tmp/\($0).app") }
        let (title, body) = NotificationService.buildContent(for: items)

        #expect(title == removedTitle)
        #expect(body == String(localized: "\(3) items are ready to use."))
    }

    @Test("Single failure names the file in the body")
    func singleFailureNamesFile() {
        let name = "MyApp.app"
        let (title, body) = NotificationService.buildContent(for: [failedItem("/tmp/\(name)")])

        #expect(title == failedTitle)
        #expect(body == String(localized: "Could not remove quarantine from \(name)."))
    }

    @Test("Multiple failures without successes report the failure count")
    func multipleFailuresShowCount() {
        let items = [failedItem("/tmp/a.app"), failedItem("/tmp/b.app")]
        let (title, body) = NotificationService.buildContent(for: items)

        #expect(title == failedTitle)
        #expect(body == String(localized: "Could not remove quarantine from \(2) items."))
    }

    @Test("Partial success reports cleaned-of-total counts")
    func partialReportsCounts() {
        let items = [cleanItem("/tmp/a.app"), cleanItem("/tmp/b.app"), failedItem("/tmp/c.app")]
        let (title, body) = NotificationService.buildContent(for: items)

        #expect(title == partialTitle)
        #expect(body == String(localized: "\(2) of \(3) items freed. Some could not be processed."))
    }

    @Test("Cancelled rows stay out of the partial-success total")
    func cancelledRowsAreNotCountedAsFailures() {
        let items =
            [cleanItem("/tmp/a.app"), failedItem("/tmp/b.app")] + (0..<8).map { cancelledItem("/tmp/c\($0).app") }
        let (_, body) = NotificationService.buildContent(for: items)

        #expect(body == String(localized: "\(1) of \(2) items freed. Some could not be processed."))
    }

    @Test("A partialSuccess item counts as success, yielding the partial title overall")
    func partialSuccessItemCountsAsSuccess() {
        let items = [
            FileItem(
                url: URL(filePath: "/tmp/a.app"),
                status: .partialSuccess(cleaned: 10, errors: [fileError("/tmp/a.app/x")]))
        ]
        let (title, body) = NotificationService.buildContent(for: items)

        #expect(title == partialTitle)
        #expect(body == String(localized: "Some items in \("a.app") could not be processed."))
    }

    @Test("A folder freed only in part beside a clean item is counted, not named")
    func partialFolderBesideCleanItemIsCounted() {
        let items = [
            FileItem(
                url: URL(filePath: "/tmp/a.app"),
                status: .partialSuccess(cleaned: 10, errors: [fileError("/tmp/a.app/x")])),
            cleanItem("/tmp/b.app"),
        ]
        let (title, body) = NotificationService.buildContent(for: items)

        #expect(title == partialTitle)
        #expect(body == String(localized: "\(2) of \(2) items freed. Some could not be processed."))
    }

    @Test("All-cancelled batch reports the stop without claiming nothing changed")
    func allCancelledIsNotSuccess() {
        let (title, body) = NotificationService.buildContent(
            for: [cancelledItem("/tmp/a.app"), cancelledItem("/tmp/b.app")])

        #expect(title == String(localized: "Canceled"))
        #expect(body == String(localized: "Processing was stopped before it finished."))
    }

    @Test("Canceled rows beside ones without quarantine report the stop, not that nothing needed removing")
    func alreadyCleanWithCancelledReportsTheStop() {
        let (title, body) = NotificationService.buildContent(
            for: [alreadyCleanItem("/tmp/a.app"), cancelledItem("/tmp/b.app")])

        #expect(title == String(localized: "Canceled"))
        #expect(body == String(localized: "Processing was stopped before it finished."))
    }

    @Test("An alreadyClean batch does not claim anything was freed")
    func alreadyCleanIsNotReportedAsFreed() {
        let alreadyClean = (0..<4).map { alreadyCleanItem("/tmp/\($0).app") }
        let (title, body) = NotificationService.buildContent(for: alreadyClean)

        #expect(title == String(localized: "Nothing to Remove"))
        #expect(body == String(localized: "\(4) items were not in quarantine."))
    }

    @Test("A single item without quarantine is named in the body")
    func singleAlreadyCleanNamesFile() {
        let name = "MyApp.app"
        let (title, body) = NotificationService.buildContent(for: [alreadyCleanItem("/tmp/\(name)")])

        #expect(title == String(localized: "Nothing to Remove"))
        #expect(body == String(localized: "\(name) was not in quarantine."))
    }

    // The status bar counts only rows that actually had something removed, and a
    // notification counting the others contradicts those rows.
    @Test("alreadyClean rows do not count toward the freed total")
    func alreadyCleanRowsAreNotFreed() {
        let items =
            (0..<4).map { alreadyCleanItem("/tmp/\($0).app") }
            + (0..<6).map { failedItem("/tmp/f\($0).app") }
        let (title, body) = NotificationService.buildContent(for: items)

        #expect(title == failedTitle)
        #expect(body == String(localized: "Could not remove quarantine from \(6) items."))
    }

    @Test("A batch that freed some and found the rest already free reports both counts")
    func freedAndAlreadyFreeReportBothCounts() {
        let items = [cleanItem("/tmp/a.app"), alreadyCleanItem("/tmp/b.app"), alreadyCleanItem("/tmp/c.app")]
        let (title, body) = NotificationService.buildContent(for: items)

        #expect(title == removedTitle)
        #expect(body == String(localized: "\(1) freed, \(2) were not in quarantine."))
    }

    @Test("Empty item list is safe and returns the success title without a body")
    func emptyListIsSafe() {
        let (title, body) = NotificationService.buildContent(for: [])

        #expect(title == removedTitle)
        #expect(body.isEmpty)
    }

    @Test("Cancelled rows do not count toward the ready total")
    func cancelledRowsNotCountedAsReady() {
        let items = [cleanItem("/tmp/a.app"), cleanItem("/tmp/b.app"), cancelledItem("/tmp/c.app")]
        let (title, body) = NotificationService.buildContent(for: items)

        #expect(title == removedTitle)
        #expect(body == String(localized: "\(2) items are ready to use."))
    }

    @Test("A single success plus cancelled rows names the successful file")
    func successWithCancelledNamesTheSuccessfulFile() {
        let name = "MyApp.app"
        let items = [cancelledItem("/tmp/gone.app"), cleanItem("/tmp/\(name)")]
        let (_, body) = NotificationService.buildContent(for: items)

        #expect(body == String(localized: "\(name) is ready to use."))
    }

    @Test("Cancelled rows do not count toward the failure total")
    func cancelledRowsNotCountedAsFailed() {
        let name = "Broken.app"
        let items = [failedItem("/tmp/\(name)"), cancelledItem("/tmp/b.app"), cancelledItem("/tmp/c.app")]
        let (_, body) = NotificationService.buildContent(for: items)

        #expect(body == String(localized: "Could not remove quarantine from \(name)."))
    }

    @Test("A control character in a file name cannot reorder the notification")
    func nameControlsAreNeutralized() {
        let (_, body) = NotificationService.buildContent(for: [failedItem("/tmp/Rechnung\u{202E}fdp.app")])

        #expect(body == String(localized: "Could not remove quarantine from \("Rechnung\u{FFFD}fdp.app")."))
    }
}
