//
//  SpringValueTests.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import SwiftUI
import Testing

@testable import Smuggler

@Suite("SpringValue")
struct SpringValueTests {
    @Test("Retargeting a spring mid-flight keeps its value and velocity")
    func springRetargetIsContinuous() {
        var value = SpringValue()
        value.animate(to: 10, at: 0, with: Spring(duration: 0.3, bounce: 0.3))
        let position = value.value(at: 0.1)
        let velocity = value.velocity(at: 0.1)

        value.animate(to: 0, at: 0.1, with: Spring(duration: 0.2, bounce: 0))
        #expect(abs(value.value(at: 0.1) - position) < 1e-9)
        #expect(abs(value.velocity(at: 0.1) - velocity) < 1e-9)
    }
}
