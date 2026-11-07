//
//  ConfirmationAlertTests.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import Foundation
import Testing

@testable import Smuggler

@Suite("Confirmation dialog content")
@MainActor
struct ConfirmationAlertTests {
    private let reversed = URL(filePath: "/tmp/Rechnung\u{202E}fdp.app")

    @Test(
        "A bidi override in the one named item cannot reorder the dialog title",
        arguments: [
            AppModel.ConfirmKind.remove, .open,
        ])
    func titleNeutralizesOverride(kind: AppModel.ConfirmKind) {
        let title = ConfirmationAlert.requestContent(for: [reversed], kind: kind).title

        #expect(title.contains("Rechnung\u{FFFD}fdp.app"))
        #expect(!title.unicodeScalars.contains("\u{202E}"))
    }

    @Test("Each requested path takes exactly one line of the list, whatever its name holds")
    func pathListKeepsOneLinePerItem() {
        let broken = URL(filePath: "/tmp/with\nnewline")
        let single = ConfirmationAlert.requestContent(for: [URL(filePath: "/tmp/plain")], kind: .remove).body

        let body = ConfirmationAlert.requestContent(for: [broken, reversed], kind: .remove).body

        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == single.split(separator: "\n", omittingEmptySubsequences: false).count + 1)
        #expect(lines.suffix(2) == ["/tmp/with\u{FFFD}newline", "/tmp/Rechnung\u{FFFD}fdp.app"])
        #expect(!body.unicodeScalars.contains("\u{202E}"))
    }
}
