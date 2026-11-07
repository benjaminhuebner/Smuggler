//
//  URLDisplayNameTests.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import Foundation
import Testing

@testable import Smuggler

@Suite("URL display names")
struct URLDisplayNameTests {
    @Test("A right-to-left override cannot reorder a name")
    func overrideIsNeutralized() {
        #expect(URL(filePath: "/tmp/Rechnung\u{202E}fdp.app").displayName == "Rechnung\u{FFFD}fdp.app")
    }

    @Test("A line break cannot start a line of its own in a path list")
    func lineBreakIsNeutralized() {
        #expect(URL(filePath: "/tmp/with\nnewline").displayPath == "/tmp/with\u{FFFD}newline")
    }

    @Test(
        "Every control, format and separator character is replaced",
        arguments: [
            "\u{0009}", "\u{000A}", "\u{000D}", "\u{001B}", "\u{0085}", "\u{00AD}", "\u{061C}",
            "\u{200B}", "\u{200E}", "\u{200F}", "\u{2028}", "\u{2029}", "\u{202A}", "\u{202B}",
            "\u{202C}", "\u{202D}", "\u{202E}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
            "\u{FEFF}", "\u{FFF9}", "\u{E0001}",
        ])
    func hazardIsReplaced(character: String) {
        #expect(URL(filePath: "/tmp/a\(character)b").displayName == "a\u{FFFD}b")
    }

    @Test(
        "Emoji sequences, right-to-left scripts and combining marks stay as they are",
        arguments: [
            "👨\u{200D}👩\u{200D}👧.png", "🏴\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F} Trip.jpg",
            "קובץ.pdf", "ملف.pdf", "می\u{200C}خواهم.txt", "Ün̈ïcode – name.app", "e\u{0301}clair.txt",
        ])
    func legitimateNameIsKept(name: String) {
        #expect(URL(filePath: "/tmp/\(name)").displayName == name)
    }
}
