//
//  GatedExecutor.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import Foundation
import Synchronization

// Holds every job until the test opens it, so a walk can be caught after it was
// handed off but before it touched the disk.
nonisolated final class GatedExecutor: TaskExecutor {
    private nonisolated struct State {
        var isOpen = false
        var held: [UnownedJob] = []
        var received = 0
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "com.benjaminhuebner.SmugglerTests.gated", attributes: .concurrent)

    var receivedJobs: Int {
        state.withLock { $0.received }
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let runsNow = state.withLock { state in
            state.received += 1
            if !state.isOpen {
                state.held.append(job)
            }
            return state.isOpen
        }
        if runsNow {
            run(job)
        }
    }

    func open() {
        let held = state.withLock { state in
            state.isOpen = true
            defer { state.held.removeAll() }
            return state.held
        }
        held.forEach(run)
    }

    private func run(_ job: UnownedJob) {
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}
