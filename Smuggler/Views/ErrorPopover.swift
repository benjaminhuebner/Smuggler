//
//  ErrorPopover.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 05.09.26.
//

import SwiftUI

// The row names the problem in one line; this is where the way out fits.
struct ErrorPopover: View {
    let error: QuarantineError

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(error.message)
                .font(.callout.weight(.medium))

            Text(error.recovery)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
        .padding(12)
        .frame(maxWidth: 340)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// A folder walk that freed some files and failed on others. Each way out is stated
// once, under all the failures it fixes: a locked tree would repeat it per file.
struct PartialSuccessPopover: View {
    let cleaned: Int
    let errors: [QuarantineFileError]

    private static let errorLimit = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(freedLine)
                Text(failedLine)
            }
            .font(.callout)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(errors.groupedByRecovery) { group in
                        recoveryBlock(group)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
        }
        .textSelection(.enabled)
        .padding(12)
        .frame(width: 340)
    }

    // Capped per group rather than overall, so no group's way out is cut off below
    // a long run of another group's failures.
    private func recoveryBlock(_ group: RecoveryGroup) -> some View {
        let (shownErrors, hiddenCount) = group.errors.cappedPrefix(Self.errorLimit)
        return VStack(alignment: .leading, spacing: 4) {
            // Wrapped, not truncated: a cut-off reason would end in a tooltip that
            // only a pointer can reach.
            ForEach(shownErrors) { fileError in
                Text(fileError.error.message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if hiddenCount > 0 {
                Text(hiddenItemsLabel(hiddenCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(group.recovery)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    private var freedLine: String {
        String(
            localized: "\(cleaned) items freed from quarantine.",
            comment: "Error popover: the number of items in the folder that were freed")
    }

    private var failedLine: String {
        String(
            localized: "\(errors.count) items could not be processed:",
            comment: "Error popover: the number of items that failed, followed by what went wrong and how to fix it")
    }
}

#Preview("Error") {
    ErrorPopover(error: .permissionDenied(URL(filePath: "/tmp/locked.app")))
}

#Preview("Partial success") {
    let file = { (name: String) in URL(filePath: "/tmp/Sample.app/Contents/\(name)") }
    PartialSuccessPopover(
        cleaned: 12,
        errors: [
            QuarantineFileError(url: file("a.dylib"), error: .permissionDenied(file("a.dylib"))),
            QuarantineFileError(url: file("Resources"), error: .unreadableDirectory(file("Resources"))),
            QuarantineFileError(url: file("b.dylib"), error: .permissionDenied(file("b.dylib"))),
            QuarantineFileError(url: file("c.plist"), error: .systemError(file("c.plist"), 1)),
        ])
}
