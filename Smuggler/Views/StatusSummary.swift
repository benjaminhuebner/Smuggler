//
//  StatusSummary.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import SwiftUI

// Every outcome pairs its words with the symbol its rows carry, so none of them
// rests on color or on a grey line alone.
nonisolated struct StatusSummary: Equatable, Sendable {
    nonisolated enum Glyph: Equatable, Sendable {
        case progress
        case symbol(String, tint: Color)
    }

    let text: String
    let glyph: Glyph

    var isSettled: Bool { glyph != .progress }

    // Nothing for an empty list: that is the bar fading out after Clear All, and a
    // sentence there would describe rows that are already gone.
    init?(items: some Collection<FileItem>, showsAsProcessing: Bool, runProgress: AppModel.RunProgress?) {
        guard !items.isEmpty else { return nil }
        if showsAsProcessing {
            glyph = .progress
            guard let runProgress else {
                text = String(localized: "Processing…", comment: "Status bar: a single item in flight")
                return
            }
            text = String(
                localized: "Processing… \(runProgress.done) of \(runProgress.total) items",
                comment:
                    "Status bar: a batch in flight, the number of finished items of its total (always more than one)")
            return
        }
        // Counted once per pass: each of these is a full scan of the item list,
        // which a Finder selection can push into the thousands.
        let freed = items.freedCount
        let failed = items.failedCount
        let alreadyFree = items.alreadyFreeCount
        let cancelled = items.cancelledCount
        // Cancelled rows never finished: when nothing was freed, no line may speak for
        // them as if they had failed or needed nothing.
        if cancelled == items.count {
            text = String(localized: "All items canceled", comment: "Status bar: every item was canceled")
            glyph = .symbol("slash.circle.fill", tint: .secondary)
        } else if freed == 0, failed > 0, alreadyFree > 0 {
            // The already-free rows are named even here: a red "nothing succeeded"
            // over a list of usable files contradicts the rows it summarizes.
            text = String(
                localized: "\(alreadyFree) already free, \(failed) failed",
                comment: "Status bar: nothing freed, some had no quarantine, some failed")
            glyph = .symbol("exclamationmark.triangle.fill", tint: .orange)
        } else if freed == 0, failed > 0 {
            text =
                if cancelled > 0 {
                    String(
                        localized: "\(failed) failed, \(cancelled) canceled",
                        comment: "Status bar: nothing freed, some failed, the rest canceled")
                } else {
                    String(localized: "No items could be freed", comment: "Status bar: nothing succeeded")
                }
            glyph = .symbol("exclamationmark.circle.fill", tint: .red)
        } else if freed == 0, cancelled > 0 {
            text = String(
                localized: "\(alreadyFree) already free, \(cancelled) canceled",
                comment: "Status bar: nothing freed, some had no quarantine, the rest canceled")
            glyph = .symbol("slash.circle.fill", tint: .secondary)
        } else if freed == 0 {
            text = String(localized: "Nothing needed freeing", comment: "Status bar: nothing had quarantine to remove")
            glyph = .symbol("checkmark.circle", tint: .secondary)
        } else if failed > 0 {
            // A single folder freed only in part would read "1 freed, 1 failed" as rows,
            // so it counts its files instead, the way its own row does.
            var (freed, failed) = (freed, failed)
            if items.attemptedCount == 1,
                case .partialSuccess(let cleaned, let errors)? = items.first(where: \.status.hasErrors)?.status
            {
                (freed, failed) = (cleaned, errors.count)
            }
            text = String(localized: "\(freed) freed, \(failed) failed", comment: "Status bar: mixed result")
            glyph = .symbol("exclamationmark.triangle.fill", tint: .orange)
        } else {
            text =
                if alreadyFree > 0 {
                    String(
                        localized: "\(freed) freed, \(alreadyFree) already free",
                        comment: "Status bar: some freed, some had no quarantine")
                } else {
                    String(localized: "\(freed) items freed", comment: "Status bar: the number of items freed")
                }
            glyph = .symbol("checkmark.circle.fill", tint: .green)
        }
    }
}
