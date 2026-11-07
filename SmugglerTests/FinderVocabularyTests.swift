//
//  FinderVocabularyTests.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import Foundation
import Testing

@testable import Smuggler

nonisolated private let finderResources = URL(filePath: "/System/Library/CoreServices/Finder.app/Contents/Resources")

// The advice sends a first-timer into Finder's Get Info window: a quoted label
// Finder doesn't show leaves them stuck there.
@Suite("Recovery advice in Finder's words")
struct FinderVocabularyTests {
    private let item = URL(filePath: "/tmp/Locked.app")
    private let permissionKey =
        "Select the item in Finder and press Command-I. Deselect “Locked”, set your account to “Read & Write” under "
        + "“Sharing & Permissions”, then try again."

    @Test("The permission advice is the catalog entry checked below")
    func permissionAdviceComesFromTheCheckedKey() throws {
        let language = try #require(Bundle.main.preferredLocalizations.first, "The app resolves no localization")

        #expect(QuarantineError.permissionDenied(item).recovery == (try advice(permissionKey, in: language)))
    }

    @Test("The English permission advice quotes only labels Finder's Get Info window shows")
    func englishLabelsExistInFinder() throws {
        let labels = quoted(in: try advice(permissionKey, in: "en"), between: "“", and: "”")
        let nibs = try ["InfoWindowGeneralView", "InfoWindowPermissionsView"].map {
            try Data(contentsOf: finderResources.appending(path: "Base.lproj/\($0).nib"))
        }

        #expect(labels == ["Locked", "Read & Write", "Sharing & Permissions"])
        for label in labels {
            #expect(nibs.contains { $0.range(of: Data(label.utf8)) != nil }, "Finder shows no “\(label)”")
        }
    }

    @Test("The German permission advice quotes only labels Finder's Get Info window shows")
    func germanLabelsExistInFinder() throws {
        let labels = quoted(in: try advice(permissionKey, in: "de"), between: "„", and: "“")
        var finderLabels: Set<String> = []
        for table in ["InfoWindowGeneralView", "InfoWindowPermissionsView"] {
            let url = finderResources.appending(path: "de.lproj/\(table).strings")
            let strings = try #require(
                NSDictionary(contentsOf: url) as? [String: String],
                "Finder no longer ships \(url.lastPathComponent) as a .strings table")
            finderLabels.formUnion(strings.values.map { $0.hasSuffix(":") ? String($0.dropLast()) : $0 })
        }

        #expect(labels.count == 3)
        #expect(Set(labels).subtracting(finderLabels).isEmpty)
    }

    @Test("The link error calls the item what Finder's Kind column does")
    func linkErrorUsesFinderKind() throws {
        let sandbox = TestSandbox()
        let link = try sandbox.symlink(to: try sandbox.file())
        let kind = try #require(
            try link.resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription,
            "macOS reports no Kind for a link")

        #expect(QuarantineError.symbolicLink(link).message.localizedCaseInsensitiveContains(kind))
    }

    private func advice(_ key: String, in language: String) throws -> String {
        let path = try #require(
            Bundle.main.path(forResource: language, ofType: "lproj"), "The app ships no \(language).lproj")
        let table = try #require(Bundle(path: path), "\(language).lproj does not load as a bundle")
        return table.localizedString(forKey: key, value: nil, table: nil)
    }

    private func quoted(in text: String, between open: Character, and close: Character) -> [String] {
        text.split(separator: open).dropFirst().compactMap { $0.split(separator: close).first.map(String.init) }
    }
}
