//
//  Collection+CappedPrefix.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 09.08.26.
//

import Foundation

nonisolated extension Collection {
    func cappedPrefix(_ limit: Int) -> (shown: [Element], hiddenCount: Int) {
        (Array(prefix(limit)), Swift.max(count - limit, 0))
    }
}

// Lives next to the cap that produces the count: every list truncated this way
// names what it hid the same way, in one place to pluralize.
nonisolated func hiddenItemsLabel(_ hiddenCount: Int) -> String {
    hiddenCount == 1
        ? String(
            localized: "and 1 more item",
            comment: "Suffix on a truncated item list when exactly one item is hidden")
        : String(
            localized: "and \(hiddenCount) more items",
            comment: "Suffix on a truncated item list when several items are hidden")
}
