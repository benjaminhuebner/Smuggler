//
//  WaitUntil.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 09.08.26.
//

import Foundation
import Testing

@testable import Smuggler

@MainActor
func waitUntil(
    timeout: Duration = .seconds(5),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @MainActor () -> Bool
) async throws {
    let start = ContinuousClock.now
    while !condition() {
        guard ContinuousClock.now - start <= timeout else {
            try #require(condition(), "Condition not met within \(timeout)", sourceLocation: sourceLocation)
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

extension AppModel {
    // A request sent while parked waits its turn behind the parked one until the
    // returned continuation finishes.
    func parkRequestQueue() -> AsyncStream<Void>.Continuation {
        let (gate, release) = AsyncStream<Void>.makeStream()
        incomingRequestTask = Task {
            for await _ in gate {}
        }
        return release
    }

    @discardableResult
    func handleIncomingRequest(
        _ urls: [URL], action: ServiceAction = .remove, quitAfter: Bool = false, token: String? = nil,
        batchName: String? = nil, isColdLaunch: Bool = false
    ) -> Task<Void, Never> {
        handleIncomingRequest(
            IncomingRequest(urls: urls, action: action, quitAfter: quitAfter, token: token, batchName: batchName),
            isColdLaunch: isColdLaunch)
    }

    // Bounded because awaiting a task's value ignores cancellation: a task that
    // never ends would hang the whole test run instead of failing this test.
    func settle(
        timeout: Duration = .seconds(5),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let (outcome, report) = AsyncStream.makeStream(of: Bool.self)
        Task {
            await drainExposedTasks()
            report.yield(true)
        }
        let deadline = Task {
            try? await Task.sleep(for: timeout)
            report.yield(false)
        }
        var firstOutcome = outcome.makeAsyncIterator()
        let settled = await firstOutcome.next() ?? false
        deadline.cancel()
        try #require(settled, "Model did not settle within \(timeout)", sourceLocation: sourceLocation)
    }

    // Loops because a handler can start the next session or request while the
    // awaited one is still running; it returns once a pass finds nothing new.
    private func drainExposedTasks() async {
        while true {
            let request = incomingRequestTask
            let handler = serviceHandlerTask
            let session = serviceMode
            await request?.value
            await handler?.value
            await session?.authorizationTask?.value
            await session?.processingTask?.value
            await session?.terminationTask?.value
            let unchanged = request == incomingRequestTask && handler == serviceHandlerTask && session === serviceMode
            if unchanged { return }
        }
    }
}
