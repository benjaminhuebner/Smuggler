//
//  TapeLaneTests.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import CoreGraphics
import Testing

@testable import Smuggler

@Suite("TapeLane")
struct TapeLaneTests {
    private let lane = TapeLane(rect: CGRect(x: 0, y: 0, width: 480, height: 340))

    // The loop is drawn through the lane and every moving piece through its
    // span; they only tile back without a seam because the two agree.
    @Test("Each run's span places a point exactly where the loop does", arguments: TapeSide.allCases)
    func spansFollowTheLoop(side: TapeSide) {
        let span = lane.span(side)
        let distances = Array(stride(from: 0, through: span.length, by: span.length / 7)) + [span.length]

        for distance in distances {
            for across: CGFloat in [-5, 0, 5] {
                let onLoop = lane.point(along: span.startAlong + distance, across: across)
                let onSpan = span.point(at: distance, across: across)
                #expect(hypot(onLoop.x - onSpan.x, onLoop.y - onSpan.y) < 1e-6)
            }
        }
    }
}
