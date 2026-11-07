//
//  WalkExecutor.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import Foundation

// The cooperative pool has a fixed width and never replaces a thread blocked in a
// syscall, so walks stuck on a hung volume would starve every task in the app, the
// timeout backstop included. A dispatch queue adds a thread when one blocks.
nonisolated final class WalkExecutor: TaskExecutor {
    private let queue = DispatchQueue(
        label: "com.benjaminhuebner.Smuggler.walk", qos: .userInitiated, attributes: .concurrent)

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}
