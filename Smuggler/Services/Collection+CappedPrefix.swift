//
//  Collection+CappedPrefix.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 09.08.26.
//

nonisolated extension Collection {
    func cappedPrefix(_ limit: Int) -> (shown: [Element], hiddenCount: Int) {
        (Array(prefix(limit)), Swift.max(count - limit, 0))
    }
}
