//
//  TapeMotion.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 25.09.26.
//

import SwiftUI

nonisolated struct TapeHalfPose {
    var bend: Double = 0
    var fold: Double = 0
    var curl: Double = 0
    var stretch: Double = 0
    var lift: Double = 0
    var twist: Double = 0

    var isAtRest: Bool {
        abs(bend) < 0.001 && abs(fold) < 0.001 && abs(curl) < 0.001 && abs(stretch) < 0.001
            && abs(lift) < 0.05 && abs(twist) < 0.005
    }
}

nonisolated struct TapeRunPose {
    var side: TapeSide
    var breakFraction: Double
    var depth: Double
    var isTorn: Bool
    var halves: [TapeHalfPose]
}

nonisolated struct TapePose {
    var heat: Double = 0
    var runs: [TapeRunPose] = []
}

// Events only retarget springs; each frame is evaluated at the time the display
// asks for, so none lags behind the pointer or drops part of a motion.
final class TapeMotion {
    var reducesMotion = false
    // Pushed out only by an event that retargets a spring, so a pointer moving
    // over a band that has nothing left to do never wakes the timeline.
    private(set) var settleDeadline: TimeInterval = 0

    private var heat = SpringValue()
    private var runs: [TapeSide: Run] = [:]
    // Sticky: the load keeps pressing on the run it came in over even after
    // the pointer moves closer to another one.
    private var approach: TapeSide?

    // MARK: - Events

    func begin(at time: TimeInterval) {
        guard heat.target != 1 else { return }
        extendDeadline(from: time)
        heat.animate(to: 1, at: time, with: Self.heatSpring)
    }

    func track(_ point: CGPoint, on lane: TapeLane, at time: TimeInterval) -> Bool {
        prune(at: time)
        let depths = TapeSide.allCases.map { (side: $0, depth: lane.span($0).depth(of: point)) }
        if let outside = depths.filter({ $0.depth < 0 }).min(by: { $0.depth < $1.depth }) {
            approach = outside.side
            relaxFolds(except: nil, at: time)
            return false
        }
        let side = approach ?? depths.min(by: { $0.depth < $1.depth })?.side ?? .leading
        approach = side
        relaxFolds(except: side, at: time)

        let span = lane.span(side)
        guard span.length >= 2 else { return false }
        var run = runs[side] ?? Run()
        defer { runs[side] = run }
        if run.tear != nil {
            if run.isResealing { reopen(&run, length: span.length, at: time) }
            return false
        }
        let depth = span.depth(of: point)
        let fraction = Self.fraction(of: span.distance(of: point), on: span)
        press(&run, at: fraction, depth: depth, time: time)
        guard Self.breaks(fraction: fraction, depth: depth, length: span.length) else { return false }
        snap(&run, length: span.length, at: time)
        return true
    }

    // A drop always goes through: if the band has not given way yet, it does
    // now — where the load presses, or else level with where it was let go.
    func land(on lane: TapeLane, near point: CGPoint?, at time: TimeInterval) -> Bool {
        if runs.values.contains(where: { $0.tear != nil && !$0.isResealing }) { return false }

        let pressed = runs.first { $0.value.tear == nil && $0.value.depth.target > 0 }?.key
        let nearest = point.flatMap { point in
            TapeSide.allCases.min { lane.span($0).depth(of: point) < lane.span($1).depth(of: point) }
        }
        let side = pressed ?? approach ?? nearest ?? .leading
        let span = lane.span(side)
        guard span.length >= 2 else { return false }
        var run = runs[side] ?? Run()
        defer { runs[side] = run }
        if run.tear != nil {
            reopen(&run, length: span.length, at: time)
            return false
        }
        if side != pressed {
            let fraction = point.map { Self.fraction(of: span.distance(of: $0), on: span) } ?? 0.5
            run.apex.jump(to: fraction, at: time)
        }
        snap(&run, length: span.length, at: time)
        return true
    }

    func end(at time: TimeInterval) {
        approach = nil
        prune(at: time)
        guard heat.target != 0 || !runs.isEmpty else { return }
        extendDeadline(from: time)
        heat.animate(to: 0, at: time, with: Self.heatSpring)
        for side in Array(runs.keys) {
            guard var run = runs[side] else { continue }
            if run.tear != nil {
                run.isResealing = true
                for index in run.halves.indices {
                    if reducesMotion {
                        run.halves[index].jump(to: TapeHalfPose(), at: time)
                    } else {
                        run.halves[index].animate(to: TapeHalfPose(), at: time, with: Self.resealSpring)
                    }
                }
            } else {
                release(&run, at: time)
            }
            runs[side] = run
        }
    }

    func pose(at time: TimeInterval, on lane: TapeLane) -> TapePose {
        var pose = TapePose(heat: min(1, max(0, heat.value(at: time))))
        for side in TapeSide.allCases {
            guard let run = runs[side] else { continue }
            if let tear = run.tear {
                let halves = run.halves.map { $0.pose(at: time) }
                if run.isResealing && halves.allSatisfy(\.isAtRest) { continue }
                pose.runs.append(
                    TapeRunPose(side: side, breakFraction: tear, depth: 0, isTorn: true, halves: halves))
            } else {
                let depth = run.depth.value(at: time)
                guard abs(depth) > 0.02 else { continue }
                let fraction = run.apex.value(at: time)
                pose.runs.append(
                    TapeRunPose(
                        side: side, breakFraction: fraction, depth: depth, isTorn: false,
                        halves: Self.fold(at: fraction, depth: depth, length: lane.span(side).length)))
            }
        }
        return pose
    }

    // MARK: - Pressing

    private func press(_ run: inout Run, at fraction: Double, depth: Double, time: TimeInterval) {
        // A fresh press starts where the load meets the band instead of
        // sweeping in from the corner the fraction last pointed at.
        if abs(run.depth.value(at: time)) < 0.5 && run.depth.target == 0 {
            run.apex.jump(to: fraction, at: time)
        }
        // Under Reduce Motion the band holds still until it breaks.
        guard !reducesMotion else { return }
        extendDeadline(from: time)
        run.apex.animate(to: fraction, at: time, with: Self.followSpring)
        run.depth.animate(to: max(0, depth), at: time, with: Self.followSpring)
    }

    private func release(_ run: inout Run, at time: TimeInterval) {
        guard run.depth.target != 0 else { return }
        extendDeadline(from: time)
        if reducesMotion {
            run.depth.jump(to: 0, at: time)
        } else {
            // Stretched and let go, it overshoots its line once, like a plucked string.
            run.depth.animate(to: 0, at: time, with: Self.twangSpring)
        }
    }

    private func relaxFolds(except kept: TapeSide?, at time: TimeInterval) {
        for side in Array(runs.keys) where side != kept {
            guard var run = runs[side], run.tear == nil else { continue }
            release(&run, at: time)
            runs[side] = run
        }
    }

    // MARK: - Breaking

    private func snap(_ run: inout Run, length: Double, at time: TimeInterval) {
        extendDeadline(from: time)
        let fraction = run.apex.value(at: time)
        let depth = reducesMotion ? 0 : max(0, run.depth.value(at: time))
        // A fast drag breaks through while the band is still turning yellow;
        // the break is the action, so it arrives in full color.
        heat.animate(to: 1, at: time, with: Self.breakHeatSpring)
        run.tear = fraction
        run.isResealing = false
        run.depth.jump(to: 0, at: time)

        let folded = Self.fold(at: fraction, depth: depth, length: length)
        let lengths = [fraction * length, (1 - fraction) * length]
        for index in run.halves.indices {
            let character = Self.characters[index]
            let rest = Self.hanging(length: lengths[index], character: character)
            if reducesMotion {
                run.halves[index].jump(to: rest, at: time)
                continue
            }
            run.halves[index].jump(to: folded[index], at: time)
            run.halves[index].whip(to: rest, character: character, at: time)
        }
    }

    // Back in before the gap had closed: the load goes through the same gap,
    // which opens again without a second snap.
    private func reopen(_ run: inout Run, length: Double, at time: TimeInterval) {
        guard let tear = run.tear else { return }
        extendDeadline(from: time)
        run.isResealing = false
        let lengths = [tear * length, (1 - tear) * length]
        for index in run.halves.indices {
            let rest = Self.hanging(length: lengths[index], character: Self.characters[index])
            if reducesMotion {
                run.halves[index].jump(to: rest, at: time)
            } else {
                run.halves[index].animate(to: rest, at: time, with: Self.reopenSpring)
            }
        }
    }

    private func prune(at time: TimeInterval) {
        runs = runs.filter { !$0.value.isSettled(at: time) }
    }

    private func extendDeadline(from time: TimeInterval) {
        settleDeadline = max(settleDeadline, time + Self.longestSettle)
    }

    // MARK: - Shape of the physics

    static func fold(at fraction: Double, depth: Double, length: Double) -> [TapeHalfPose] {
        let near = max(1, fraction * length)
        let far = max(1, (1 - fraction) * length)
        let nearAngle = atan2(depth, near)
        let farAngle = atan2(depth, far)
        let fold = -(nearAngle + farAngle) / 2
        return [
            TapeHalfPose(bend: nearAngle, fold: fold, stretch: hypot(near, depth) / near - 1),
            TapeHalfPose(bend: farAngle, fold: fold, stretch: hypot(far, depth) / far - 1),
        ]
    }

    // Tape gives by stretch, not by depth: pressed near a corner it breaks
    // after a shallow dent, pressed mid-run it bows much further first.
    static func breaks(fraction: Double, depth: Double, length: Double) -> Bool {
        guard depth >= minimumBreakDepth else { return false }
        if depth >= maximumBreakDepth { return true }
        let near = fraction * length
        let far = (1 - fraction) * length
        return hypot(near, depth) + hypot(far, depth) - length >= breakingStretch
    }

    // Short halves have little to curl with, and a long one stops curling
    // before its end reaches into the content.
    private static func hanging(length: Double, character: Character) -> TapeHalfPose {
        let reach = min(1, length / 90)
        let curlLength = Double(TapeHalf.curlLength(for: length))
        let deepest = maximumCurlDepth * (Double(TapeHalf.curlShape) + 1) / curlLength
        return TapeHalfPose(
            bend: 0.03 * character.reach,
            curl: min(0.7 * reach, deepest) * character.reach,
            stretch: -0.06,
            lift: 5 * reach)
    }

    private static func fraction(of distance: Double, on span: TapeSpan) -> Double {
        guard span.length > 0 else { return 0.5 }
        let margin = min(28, span.length / 3)
        return min(max(distance, margin), span.length - margin) / span.length
    }

    // The two halves never move in lockstep: a symmetric rip reads as a mechanism.
    private struct Character {
        let pace: Double
        let reach: Double
        let twist: Double
    }

    private static let characters = [
        Character(pace: 1, reach: 1, twist: 1),
        Character(pace: 0.88, reach: 1.15, twist: -0.8),
    ]

    private static let minimumBreakDepth: Double = 8
    private static let maximumBreakDepth: Double = 26
    private static let breakingStretch: Double = 1.7
    private static let maximumCurlDepth: Double = 38
    private static let longestSettle: TimeInterval = 1.2

    private static let heatSpring = Spring(duration: 0.2, bounce: 0)
    private static let breakHeatSpring = Spring(duration: 0.06, bounce: 0)
    private static let followSpring = Spring(duration: 0.06, bounce: 0)
    private static let twangSpring = Spring(duration: 0.32, bounce: 0.45)
    private static let resealSpring = Spring(duration: 0.2, bounce: 0)
    private static let reopenSpring = Spring(duration: 0.3, bounce: 0.2)

    // MARK: - State

    private struct Run {
        var apex = SpringValue()
        var depth = SpringValue()
        var tear: Double?
        var isResealing = false
        var halves = [Half(), Half()]

        func isSettled(at time: TimeInterval) -> Bool {
            if tear != nil {
                return isResealing && halves.allSatisfy { $0.pose(at: time).isAtRest && $0.isStill(at: time) }
            }
            return depth.target == 0 && abs(depth.value(at: time)) < 0.02 && abs(depth.velocity(at: time)) < 0.5
        }
    }

    private struct Half {
        var bend = SpringValue()
        var fold = SpringValue()
        var curl = SpringValue()
        var stretch = SpringValue()
        var lift = SpringValue()
        var twist = SpringValue()

        func pose(at time: TimeInterval) -> TapeHalfPose {
            TapeHalfPose(
                bend: bend.value(at: time), fold: fold.value(at: time), curl: curl.value(at: time),
                stretch: stretch.value(at: time), lift: lift.value(at: time), twist: twist.value(at: time))
        }

        func isStill(at time: TimeInterval) -> Bool {
            abs(bend.velocity(at: time)) < 0.01 && abs(curl.velocity(at: time)) < 0.01
                && abs(stretch.velocity(at: time)) < 0.005 && abs(lift.velocity(at: time)) < 0.5
        }

        mutating func jump(to pose: TapeHalfPose, at time: TimeInterval) {
            bend.jump(to: pose.bend, at: time)
            fold.jump(to: pose.fold, at: time)
            curl.jump(to: pose.curl, at: time)
            stretch.jump(to: pose.stretch, at: time)
            lift.jump(to: pose.lift, at: time)
            twist.jump(to: pose.twist, at: time)
        }

        mutating func animate(to pose: TapeHalfPose, at time: TimeInterval, with spring: Spring) {
            bend.animate(to: pose.bend, at: time, with: spring)
            fold.animate(to: pose.fold, at: time, with: spring)
            curl.animate(to: pose.curl, at: time, with: spring)
            stretch.animate(to: pose.stretch, at: time, with: spring)
            lift.animate(to: pose.lift, at: time, with: spring)
            twist.animate(to: pose.twist, at: time, with: spring)
        }

        // The snap starts at full speed — stored stretch lets go at once — so
        // every part gets its velocity up front instead of easing in.
        mutating func whip(to rest: TapeHalfPose, character: Character, at time: TimeInterval) {
            let pace = character.pace
            stretch.animate(
                to: rest.stretch, at: time, with: Spring(duration: 0.12 * pace, bounce: 0.4), kick: -3)
            bend.animate(to: rest.bend, at: time, with: Spring(duration: 0.26 * pace, bounce: 0.35))
            fold.animate(to: 0, at: time, with: Spring(duration: 0.08, bounce: 0))
            curl.animate(
                to: rest.curl, at: time, with: Spring(duration: 0.34 * pace, bounce: 0.5), kick: 30 * rest.curl)
            lift.animate(
                to: rest.lift, at: time, with: Spring(duration: 0.32 * pace, bounce: 0.3), kick: 90 * rest.lift)
            twist.animate(
                to: 0, at: time, with: Spring(duration: 0.28 * pace, bounce: 0.35), kick: 22 * character.twist)
        }
    }
}
