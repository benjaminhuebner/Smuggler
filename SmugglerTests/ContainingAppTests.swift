//
//  ContainingAppTests.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import AppKit
import Testing

@Suite("Finder extension handoff to its containing app")
struct ContainingAppTests {
    @Test("The extension resolves the app it ships in from its own bundle location")
    func resolvesTheAppItShipsIn() throws {
        let plugIns = try #require(Bundle.main.builtInPlugInsURL)
        let appex = try #require(Bundle(url: plugIns.appending(path: "SmugglerFinderExtension.appex")))

        // Bundle(url:) drops a /private prefix that Bundle.main keeps, so only the
        // standardized spellings compare.
        #expect(
            ContainingApp.url(containing: appex.bundleURL).standardizedFileURL
                == Bundle.main.bundleURL.standardizedFileURL)
    }

    @Test("A running copy at another path never receives the request in place of the containing app")
    func runningCopiesElsewhereAreNotSubstituted() {
        let configuration = ContainingApp.openConfiguration()

        #expect(configuration.allowsRunningApplicationSubstitution == false)
        #expect(configuration.createsNewApplicationInstance == false)
    }
}
