//
//  StatusSummaryTests.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import Foundation
import SwiftUI
import Testing

@testable import Smuggler

nonisolated private let locked = URL(filePath: "/tmp/locked")
nonisolated private let failed = FileStatus.error(.permissionDenied(locked))
nonisolated private let skipped = FileStatus.error(.unreadableDirectory(locked))
nonisolated private let partial = FileStatus.partialSuccess(
    cleaned: 3, errors: [QuarantineFileError(url: locked, error: .permissionDenied(locked))])

nonisolated private func rows(_ statuses: [FileStatus]) -> [FileItem] {
    statuses.enumerated().map { FileItem(url: URL(filePath: "/tmp/row-\($0.offset)"), status: $0.element) }
}

nonisolated private let canceledGlyph = StatusSummary.Glyph.symbol("slash.circle.fill", tint: .secondary)
nonisolated private let failedGlyph = StatusSummary.Glyph.symbol("exclamationmark.circle.fill", tint: .red)
nonisolated private let partialGlyph = StatusSummary.Glyph.symbol("exclamationmark.triangle.fill", tint: .orange)
nonisolated private let freedGlyph = StatusSummary.Glyph.symbol("checkmark.circle.fill", tint: .green)

// Expectations go through String(localized:) with the summary's own keys, so
// they hold in whatever language the test host runs.
@Suite("StatusSummary")
struct StatusSummaryTests {
    @Test(
        "A settled list speaks the counts its rows add up to, beside the symbol they carry",
        arguments: [
            ([.cancelled, .cancelled], String(localized: "All items canceled"), canceledGlyph),
            ([failed], String(localized: "No items could be freed"), failedGlyph),
            ([skipped], String(localized: "No items could be freed"), failedGlyph),
            (
                Array(repeating: .alreadyClean, count: 4) + Array(repeating: failed, count: 6),
                String(localized: "\(4) already free, \(6) failed"), partialGlyph
            ),
            ([failed, .cancelled, .cancelled], String(localized: "\(1) failed, \(2) canceled"), failedGlyph),
            ([.alreadyClean, failed, .cancelled], String(localized: "\(1) already free, \(1) failed"), partialGlyph),
            (
                [.alreadyClean], String(localized: "Nothing needed freeing"),
                .symbol("checkmark.circle", tint: .secondary)
            ),
            (
                [.alreadyClean, .cancelled, .cancelled, .cancelled, .cancelled],
                String(localized: "\(1) already free, \(4) canceled"), canceledGlyph
            ),
            ([.clean, failed, .alreadyClean], String(localized: "\(1) freed, \(1) failed"), partialGlyph),
            ([partial], String(localized: "\(3) freed, \(1) failed"), partialGlyph),
            ([partial, .cancelled], String(localized: "\(3) freed, \(1) failed"), partialGlyph),
            ([partial, .clean], String(localized: "\(2) freed, \(1) failed"), partialGlyph),
            ([.clean, .clean, .alreadyClean], String(localized: "\(2) freed, \(1) already free"), freedGlyph),
            ([.clean, .clean, .clean], String(localized: "\(3) items freed"), freedGlyph),
            ([.clean, .cancelled], String(localized: "\(1) items freed"), freedGlyph),
        ] as [([FileStatus], String, StatusSummary.Glyph)])
    func settledOutcome(statuses: [FileStatus], text: String, glyph: StatusSummary.Glyph) throws {
        let summary = try #require(StatusSummary(items: rows(statuses), showsAsProcessing: false, runProgress: nil))

        #expect(summary.text == text)
        #expect(summary.glyph == glyph)
        #expect(summary.isSettled)
    }

    @Test("While anything still shows as processing, the bar says so over any finished mix and holds the announcement")
    func processingOutranksEveryOutcome() throws {
        let items = rows([.clean, failed, .cancelled])
        let progress = AppModel.RunProgress(done: 12, total: 40)
        let single = try #require(StatusSummary(items: items, showsAsProcessing: true, runProgress: nil))
        let batch = try #require(StatusSummary(items: items, showsAsProcessing: true, runProgress: progress))

        #expect(single.text == String(localized: "Processing…"))
        #expect(batch.text == String(localized: "Processing… \(12) of \(40) items"))
        for summary in [single, batch] {
            #expect(summary.glyph == .progress)
            #expect(!summary.isSettled)
        }
    }

    @Test("An empty list has nothing to say", arguments: [false, true])
    func emptyListHasNoSummary(showsAsProcessing: Bool) {
        #expect(StatusSummary(items: [FileItem](), showsAsProcessing: showsAsProcessing, runProgress: nil) == nil)
    }
}
