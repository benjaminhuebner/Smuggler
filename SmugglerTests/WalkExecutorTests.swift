//
//  WalkExecutorTests.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import Foundation
import Testing

@testable import Smuggler

// Stands in for a syscall hung on a dead volume. Bounded so a regression fails the
// test instead of hanging the run.
nonisolated private func blockInKernel(until release: DispatchSemaphore) -> Bool {
    release.wait(timeout: .now() + .seconds(10)) == .success
}

@Suite("WalkExecutor")
struct WalkExecutorTests {
    @Test("Walks blocked in the kernel leave the cooperative pool free")
    func blockedWalksLeaveThePoolFree() async {
        let executor = WalkExecutor()
        let release = DispatchSemaphore(value: 0)
        let running = DispatchGroup()
        // More blocked walks than the pool has threads.
        let count = ProcessInfo.processInfo.activeProcessorCount + 4
        let walks = (0..<count).map { _ in
            running.enter()
            return Task.detached(executorPreference: executor) { () -> Bool in
                running.leave()
                return blockInKernel(until: release)
            }
        }
        await withCheckedContinuation { continuation in
            running.notify(queue: .main) { continuation.resume() }
        }

        let probe = Task.detached { () -> Bool in
            try? await Task.sleep(for: .milliseconds(10))
            return true
        }
        #expect(await probe.value)

        for _ in walks {
            release.signal()
        }
        for walk in walks {
            // Released by its timeout means the probe had to wait for this walk's thread.
            #expect(await walk.value)
        }
    }
}
