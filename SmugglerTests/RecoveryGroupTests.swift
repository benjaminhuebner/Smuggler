//
//  RecoveryGroupTests.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import Foundation
import Testing

@testable import Smuggler

nonisolated private func failure(_ name: String, _ error: (URL) -> QuarantineError) -> QuarantineFileError {
    let url = URL(filePath: "/tmp/Sample.app/Contents/\(name)")
    return QuarantineFileError(url: url, error: error(url))
}

@Suite("Collection.groupedByRecovery")
struct RecoveryGroupTests {
    @Test("Failures sharing a way out are grouped under it, largest group first, ties in the walk's order")
    func groupsByRecovery() {
        let lockedA = failure("a.dylib", QuarantineError.permissionDenied)
        let skipped = failure("Resources", QuarantineError.unreadableDirectory)
        let lockedB = failure("b.dylib", QuarantineError.permissionDenied)
        let refused = failure("c.plist") { .systemError($0, 13) }
        let rejected = failure("d.plist") { .systemError($0, 1) }

        let groups = [lockedA, skipped, lockedB, refused, rejected].groupedByRecovery

        #expect(groups.map(\.errors) == [[lockedA, lockedB], [skipped], [refused], [rejected]])
        #expect(groups.map(\.recovery) == [lockedA, skipped, refused, rejected].map(\.error.recovery))
    }

    @Test("A group that forms late still leads when it is the largest")
    func largestGroupLeads() {
        let timedOut = failure("Contents", QuarantineError.timeout)
        let lockedA = failure("a.dylib", QuarantineError.permissionDenied)
        let lockedB = failure("b.dylib", QuarantineError.permissionDenied)

        let groups = [timedOut, lockedA, lockedB].groupedByRecovery

        #expect(groups.map(\.errors) == [[lockedA, lockedB], [timedOut]])
    }

    @Test("No failures, no groups")
    func emptyHasNoGroups() {
        #expect([QuarantineFileError]().groupedByRecovery.isEmpty)
    }
}
