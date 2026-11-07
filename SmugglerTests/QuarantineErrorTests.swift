//
//  QuarantineErrorTests.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import Foundation
import Testing

@testable import Smuggler

nonisolated private let item = URL(filePath: "/tmp/Some Folder/item.app")

@Suite("QuarantineError")
struct QuarantineErrorTests {
    @Test(
        "Every error names its item and reaches the system's error bridging with its text",
        arguments: [
            QuarantineError.invalidURL(item), .symbolicLink(item), .fileNotFound(item), .permissionDenied(item),
            .timeout(item), .systemError(item, 13), .blockedPath(item), .unreadableDirectory(item),
        ])
    func textReachesBridging(error: QuarantineError) {
        #expect(error.url == item)
        #expect(error.message.contains("item.app"))
        #expect(!error.recovery.isEmpty)
        #expect((error as any Error).localizedDescription == error.message)
        #expect(error.recoverySuggestion == error.recovery)
    }

    @Test("A control character in the file name never reaches the message")
    func messageNeutralizesName() {
        let error = QuarantineError.fileNotFound(URL(filePath: "/tmp/Rechnung\u{202E}fdp.app"))

        #expect(error.message.contains("Rechnung\u{FFFD}fdp.app"))
        #expect(!error.message.unicodeScalars.contains("\u{202E}"))
    }
}
