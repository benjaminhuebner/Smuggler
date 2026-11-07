//
//  HazardStripesTests.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import CoreGraphics
import Testing

@testable import Smuggler

@Suite("HazardStripes")
struct HazardStripesTests {
    @Test(
        "The period divides the loop into whole repeats, so the pattern meets itself",
        arguments: [1576.9, 1000.3, 100, 13, 5])
    func periodTilesTheLoop(length: CGFloat) {
        let repeats = length / HazardStripes.period(forLoopLength: length)

        #expect(abs(repeats - repeats.rounded()) < 1e-9)
        #expect(repeats.rounded() >= 1)
    }
}
