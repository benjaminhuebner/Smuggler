//
//  CountedPhraseTests.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import Foundation
import Testing

// Resolved from each language's own table, not through the host's preferences:
// the test host runs in whatever language the Mac does.
@Suite("String catalog — counted phrases")
struct CountedPhraseTests {
    nonisolated struct Phrase: Sendable, CustomTestStringConvertible {
        let key: String
        let counts: [Int]
        let english: String
        let german: String

        var testDescription: String { "\(key) \(counts)" }
    }

    nonisolated static let phrases: [Phrase] = [
        Phrase(key: "%lld items freed", counts: [1], english: "1 item freed", german: "1 Objekt freigegeben"),
        Phrase(key: "%lld items freed", counts: [2], english: "2 items freed", german: "2 Objekte freigegeben"),
        Phrase(
            key: "%lld items freed from quarantine.", counts: [1],
            english: "1 item freed from quarantine.", german: "1 Objekt freigegeben."),
        Phrase(
            key: "%lld items freed from quarantine.", counts: [12],
            english: "12 items freed from quarantine.", german: "12 Objekte freigegeben."),
        Phrase(
            key: "%lld items could not be processed:", counts: [1],
            english: "1 item could not be processed:", german: "1 Objekt konnte nicht verarbeitet werden:"),
        Phrase(
            key: "%lld items could not be processed:", counts: [3],
            english: "3 items could not be processed:", german: "3 Objekte konnten nicht verarbeitet werden:"),
        Phrase(key: "and %lld more items", counts: [1], english: "and 1 more item", german: "und 1 weiteres Objekt"),
        Phrase(key: "and %lld more items", counts: [3], english: "and 3 more items", german: "und 3 weitere Objekte"),
        Phrase(
            key: "%lld items are ready to use.", counts: [1],
            english: "1 item is ready to use.", german: "1 Objekt ist einsatzbereit."),
        Phrase(
            key: "%lld items are ready to use.", counts: [2],
            english: "2 items are ready to use.", german: "2 Objekte sind einsatzbereit."),
        Phrase(
            key: "%lld items were not in quarantine.", counts: [1],
            english: "1 item was not in quarantine.", german: "1 Objekt war nicht in Quarantäne."),
        Phrase(
            key: "%lld items were not in quarantine.", counts: [4],
            english: "4 items were not in quarantine.", german: "4 Objekte waren nicht in Quarantäne."),
        Phrase(
            key: "%lld freed, %lld were not in quarantine.", counts: [3, 1],
            english: "3 freed, 1 was not in quarantine.", german: "3 freigegeben, 1 war nicht in Quarantäne."),
        Phrase(
            key: "%lld freed, %lld were not in quarantine.", counts: [1, 2],
            english: "1 freed, 2 were not in quarantine.", german: "1 freigegeben, 2 waren nicht in Quarantäne."),
        Phrase(
            key: "%lld of %lld items freed. Some could not be processed.", counts: [1, 1],
            english: "1 of 1 item freed. Some could not be processed.",
            german: "1 von 1 Objekt freigegeben. Einige konnten nicht verarbeitet werden."),
        Phrase(
            key: "%lld of %lld items freed. Some could not be processed.", counts: [1, 3],
            english: "1 of 3 items freed. Some could not be processed.",
            german: "1 von 3 Objekten freigegeben. Einige konnten nicht verarbeitet werden."),
        Phrase(
            key: "Could not remove quarantine from %lld items.", counts: [1],
            english: "Could not remove quarantine from 1 item.",
            german: "Quarantäne von 1 Objekt konnte nicht aufgehoben werden."),
        Phrase(
            key: "Could not remove quarantine from %lld items.", counts: [6],
            english: "Could not remove quarantine from 6 items.",
            german: "Quarantäne von 6 Objekten konnte nicht aufgehoben werden."),
        Phrase(key: "Open %lld items?", counts: [1], english: "Open 1 item?", german: "1 Objekt öffnen?"),
        Phrase(key: "Open %lld items?", counts: [2], english: "Open 2 items?", german: "2 Objekte öffnen?"),
        Phrase(
            key: "Remove quarantine from %lld items?", counts: [1],
            english: "Remove quarantine from 1 item?", german: "Quarantäne von 1 Objekt aufheben?"),
        Phrase(
            key: "Remove quarantine from %lld items?", counts: [11],
            english: "Remove quarantine from 11 items?", german: "Quarantäne von 11 Objekten aufheben?"),
        Phrase(
            key: "Processing… %lld of %lld items", counts: [0, 1],
            english: "Processing… 0 of 1 item", german: "Verarbeitung\u{00A0}… 0 von 1 Objekt"),
        Phrase(
            key: "Processing… %lld of %lld items", counts: [1, 2],
            english: "Processing… 1 of 2 items", german: "Verarbeitung\u{00A0}… 1 von 2 Objekten"),
    ]

    @Test("Each counted phrase agrees with its count in English and German", arguments: phrases)
    func phraseAgreesWithCount(_ phrase: Phrase) throws {
        #expect(try resolve(phrase, in: "en") == phrase.english)
        #expect(try resolve(phrase, in: "de") == phrase.german)
    }

    private func resolve(_ phrase: Phrase, in language: String) throws -> String {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let table = try #require(Bundle(path: path))
        let format = table.localizedString(forKey: phrase.key, value: nil, table: nil)
        return String(format: format, locale: Locale(identifier: language), arguments: phrase.counts)
    }
}
