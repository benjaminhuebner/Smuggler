//
//  SettleTests.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import Foundation
import Testing

@testable import Smuggler

@Suite("AppModel.settle")
@MainActor
struct SettleTests {
    @Test("A task that never ends fails the test at the deadline instead of hanging the run")
    func settleFailsAtDeadline() async {
        let model = makeModel()
        let release = model.parkRequestQueue()

        await withKnownIssue {
            try await model.settle(timeout: .milliseconds(50))
        }

        release.finish()
        await model.incomingRequestTask?.value
    }
}
