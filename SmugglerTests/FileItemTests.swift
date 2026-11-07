//
//  FileItemTests.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 05.09.26.
//

import Foundation
import Testing

@testable import Smuggler

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

    @Test("didFreeSomething for each status")
    func didFreeSomething() {
        #expect(FileStatus.processing.didFreeSomething == false)
        #expect(FileStatus.clean.didFreeSomething == true)
        #expect(FileStatus.alreadyClean.didFreeSomething == false)
        #expect(FileStatus.cancelled.didFreeSomething == false)
        #expect(Self.partial.didFreeSomething == true)
        #expect(FileStatus.partialSuccess(cleaned: 0, errors: []).didFreeSomething == false)
        #expect(FileStatus.error(.fileNotFound(URL(filePath: "/tmp/x"))).didFreeSomething == false)
    }

    @Test("The batch counts a window and a notification share")
    func batchCounts() {
        let items = [
            FileItem(url: URL(filePath: "/tmp/a"), status: .clean),
            FileItem(url: URL(filePath: "/tmp/b"), status: .alreadyClean),
            FileItem(url: URL(filePath: "/tmp/c"), status: Self.partial),
            FileItem(url: URL(filePath: "/tmp/d"), status: .error(.fileNotFound(URL(filePath: "/tmp/d")))),
            FileItem(url: URL(filePath: "/tmp/e"), status: .cancelled),
        ]

        #expect(items.freedCount == 2)
        #expect(items.alreadyFreeCount == 1)
        #expect(items.failedCount == 2)
        #expect(items.cancelledCount == 1)
        #expect(items.attemptedCount == 4)
    }

    @Test("A walk's result maps to the row status it earned")
    func outcomeMapping() {
        let url = URL(filePath: "/tmp/dir")
        let inner = QuarantineFileError(
            url: URL(filePath: "/tmp/dir/x"), error: .permissionDenied(URL(filePath: "/tmp/dir/x")))

        #expect(FileStatus(outcomeOf: QuarantineResult(processed: 3, cleaned: 2), for: url) == .clean)
        #expect(FileStatus(outcomeOf: QuarantineResult(processed: 3), for: url) == .alreadyClean)
        #expect(
            FileStatus(outcomeOf: QuarantineResult(processed: 3, cleaned: 2, errors: [inner]), for: url)
                == .partialSuccess(cleaned: 2, errors: [inner]))
        #expect(
            FileStatus(outcomeOf: QuarantineResult(processed: 1, errors: [inner]), for: url)
                == .error(inner.error))
    }

    @Test("A timed-out walk keeps what it freed and names the deadline when nothing was")
    func outcomeTimeout() {
        let url = URL(filePath: "/tmp/dir")
        let inner = QuarantineFileError(
            url: URL(filePath: "/tmp/dir/x"), error: .permissionDenied(URL(filePath: "/tmp/dir/x")))
        let timeout = QuarantineFileError(url: url, error: .timeout(url))

        #expect(
            FileStatus(outcomeOf: QuarantineResult(processed: 5, cleaned: 2, timedOut: true), for: url)
                == .partialSuccess(cleaned: 2, errors: [timeout]))
        #expect(
            FileStatus(outcomeOf: QuarantineResult(processed: 5, errors: [inner], timedOut: true), for: url)
                == .error(.timeout(url)))
        #expect(FileStatus(outcomeOf: QuarantineResult(timedOut: true), for: url) == .error(.timeout(url)))
    }
}

nonisolated private let folder = URL(filePath: "/tmp/dir")
nonisolated private let child = URL(filePath: "/tmp/dir/x")

@Suite("FileItem")
struct FileItemTests {
    @Test(
        "Only a run that failed to find the item itself proves it gone",
        arguments: [
            (FileStatus.error(.fileNotFound(folder)), true),
            (.error(.invalidURL(folder)), true),
            (.error(.fileNotFound(child)), false),
            (.error(.permissionDenied(folder)), false),
            (
                .partialSuccess(cleaned: 1, errors: [QuarantineFileError(url: child, error: .fileNotFound(child))]),
                false
            ),
            (.processing, false),
            (.cancelled, false),
        ])
    func provedMissing(status: FileStatus, provedMissing: Bool) {
        #expect(FileItem(url: folder, status: status).provedMissing == provedMissing)
    }

    @Test("Only a row that starts out processing is stamped with when it began")
    func processingStamp() {
        #expect(FileItem(url: folder, status: .processing).processingSince != nil)
        #expect(FileItem(url: folder, status: .clean).processingSince == nil)
        #expect(FileItem(url: folder, status: .error(.blockedPath(folder))).processingSince == nil)
    }

    @Test("The row name cannot be reordered by a control character")
    func nameIsNeutralized() {
        #expect(FileItem(url: URL(filePath: "/tmp/a\u{202E}fdp.app"), status: .clean).name == "a\u{FFFD}fdp.app")
    }
}
