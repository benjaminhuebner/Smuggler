//
//  SpringValue.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import SwiftUI

// Solved in closed form from its last retarget, and a retarget keeps the
// velocity it had, so a change of mind bends the motion instead of restarting it.
nonisolated struct SpringValue {
    private var origin: Double
    private var initialVelocity: Double = 0
    private(set) var target: Double
    private var start: TimeInterval = 0
    private var spring = Spring()

    init(_ value: Double = 0) {
        origin = value
        target = value
    }

    func value(at time: TimeInterval) -> Double {
        origin + spring.value(target: target - origin, initialVelocity: initialVelocity, time: max(0, time - start))
    }

    func velocity(at time: TimeInterval) -> Double {
        spring.velocity(target: target - origin, initialVelocity: initialVelocity, time: max(0, time - start))
    }

    mutating func animate(to target: Double, at time: TimeInterval, with spring: Spring, kick: Double = 0) {
        let value = value(at: time)
        initialVelocity = velocity(at: time) + kick
        origin = value
        self.target = target
        self.spring = spring
        start = time
    }

    mutating func jump(to value: Double, at time: TimeInterval) {
        origin = value
        initialVelocity = 0
        target = value
        start = time
    }
}
