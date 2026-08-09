//
//  WaitUntil.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 09.08.26.
//

import Foundation

struct WaitTimeoutError: Error {}

@MainActor
func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: @MainActor () -> Bool
) async throws {
    let start = ContinuousClock.now
    while !condition() {
        if ContinuousClock.now - start > timeout {
            throw WaitTimeoutError()
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
