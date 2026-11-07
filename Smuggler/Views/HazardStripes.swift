//
//  HazardStripes.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 03.09.26.
//

import SwiftUI

// Stripes drawn in screen space break wherever the band turns, the tell of a
// decal. These live in tape coordinates: every edge is `along − across = const`,
// so they bend with the band through corners and on a torn piece that curls.
nonisolated enum HazardStripes {
    private static let nominalPeriod: CGFloat = 26
    // Drawn past both edges and clipped back to the band, so the band's own
    // outline, not this sampling of it, is what cuts each stripe.
    private static let overdraw: CGFloat = 2
    private static let edgeStep: CGFloat = 2
    private static let sideSteps = 10

    // A whole number of repeats, so the pattern meets itself around the loop.
    static func period(forLoopLength length: CGFloat) -> CGFloat {
        length / max(1, (length / nominalPeriod).rounded())
    }

    // All pieces share the loop's grid, so a torn half carries exactly the
    // stripes it covered while sealed.
    static func stripes(covering range: ClosedRange<CGFloat>, period: CGFloat) -> Range<Int> {
        let reach = TapeMetrics.bandWidth / 2 + overdraw
        let first = Int(((range.lowerBound - reach - period / 2) / period).rounded(.down))
        let last = Int(((range.upperBound + reach) / period).rounded(.up))
        return first..<(last + 1)
    }

    static func path(
        period: CGFloat,
        stripes: Range<Int>,
        point: (_ along: CGFloat, _ across: CGFloat) -> CGPoint
    ) -> Path {
        guard period > 0 else { return Path() }
        let reach = TapeMetrics.bandWidth / 2 + overdraw
        let edgeSteps = max(2, Int((period / 2 / edgeStep).rounded(.up)))

        var path = Path()
        var points: [CGPoint] = []
        points.reserveCapacity(2 * sideSteps + 2 * edgeSteps)
        for stripe in stripes {
            let start = CGFloat(stripe) * period
            let stop = start + period / 2
            points.removeAll(keepingCapacity: true)
            for step in 0...sideSteps {
                let across = -reach + 2 * reach * CGFloat(step) / CGFloat(sideSteps)
                points.append(point(start + across, across))
            }
            for step in 1...edgeSteps {
                let along = start + reach + (stop - start) * CGFloat(step) / CGFloat(edgeSteps)
                points.append(point(along, reach))
            }
            for step in 1...sideSteps {
                let across = reach - 2 * reach * CGFloat(step) / CGFloat(sideSteps)
                points.append(point(stop + across, across))
            }
            for step in 1..<edgeSteps {
                let along = stop - reach - (stop - start) * CGFloat(step) / CGFloat(edgeSteps)
                points.append(point(along, -reach))
            }
            path.addLines(points)
            path.closeSubpath()
        }
        return path
    }
}
