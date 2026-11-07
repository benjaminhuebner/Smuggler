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
// names what it hid the same way.
nonisolated func hiddenItemsLabel(_ hiddenCount: Int) -> String {
    String(
        localized: "and \(hiddenCount) more items",
        comment: "Last line of a truncated list of items: the number of items not shown")
}
