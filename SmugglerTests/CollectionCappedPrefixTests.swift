//
//  CollectionCappedPrefixTests.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 09.08.26.
//

import Testing

@testable import Smuggler

@Suite("Collection.cappedPrefix")
struct CollectionCappedPrefixTests {
    @Test("A collection over the limit is capped and counts the hidden rest")
    func capsOverLimit() {
        let (shown, hidden) = [1, 2, 3, 4, 5].cappedPrefix(3)

        #expect(shown == [1, 2, 3])
        #expect(hidden == 2)
    }

    @Test("A collection at or under the limit is shown in full", arguments: [2, 3])
    func showsFullCollectionAtOrUnderLimit(limit: Int) {
        let (shown, hidden) = [1, 2].cappedPrefix(limit)

        #expect(shown == [1, 2])
        #expect(hidden == 0)
    }

    @Test("An empty collection yields nothing shown and nothing hidden")
    func emptyCollection() {
        let (shown, hidden) = [Int]().cappedPrefix(10)

        #expect(shown.isEmpty)
        #expect(hidden == 0)
    }
}
