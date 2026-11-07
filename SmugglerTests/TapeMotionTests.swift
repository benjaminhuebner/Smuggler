//
//  TapeMotionTests.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 25.09.26.
//

import CoreGraphics
import SwiftUI
import Testing

@testable import Smuggler

@Suite("TapeMotion")
@MainActor
struct TapeMotionTests {
    // The empty state's frame in the default 520×380 window.
    private let lane = TapeLane(rect: CGRect(x: 0, y: 0, width: 480, height: 340))

    private func pressLeading(
        _ motion: TapeMotion, to depth: CGFloat, atY y: CGFloat, from start: TimeInterval = 0
    ) -> (snappedAt: TimeInterval?, end: TimeInterval) {
        let centreline = lane.span(.leading).start.x
        var time = start
        var snappedAt: TimeInterval?
        var x = centreline - 15
        while x <= centreline + depth {
            if motion.track(CGPoint(x: x, y: y), on: lane, at: time), snappedAt == nil { snappedAt = time }
            x += 1
            time += 1.0 / 120
        }
        return (snappedAt, time)
    }

    private func leadingRun(in pose: TapePose) -> TapeRunPose? {
        pose.runs.first { $0.side == .leading }
    }

    @Test("A shallow press bends the band toward the pointer without breaking it")
    func shallowPressBends() throws {
        let motion = TapeMotion()
        motion.begin(at: 0)
        let press = pressLeading(motion, to: 7, atY: 170)

        #expect(press.snappedAt == nil)
        let run = try #require(leadingRun(in: motion.pose(at: press.end + 1, on: lane)))
        #expect(!run.isTorn)
        #expect(abs(run.depth - 7) < 0.5)
        #expect(abs(run.breakFraction - 0.5) < 0.01)
    }

    @Test("Pressing through breaks the run the load came over, level with the pointer")
    func pressThroughBreaksWherePressed() throws {
        let motion = TapeMotion()
        motion.begin(at: 0)
        let press = pressLeading(motion, to: 40, atY: 100)

        #expect(press.snappedAt != nil)
        let pose = motion.pose(at: press.end + 2, on: lane)
        #expect(pose.runs.count == 1)
        let run = try #require(leadingRun(in: pose))
        #expect(run.isTorn)
        let span = lane.span(.leading)
        #expect(abs(run.breakFraction - span.distance(of: CGPoint(x: 0, y: 100)) / span.length) < 0.01)
    }

    @Test("Near a corner the band breaks after a shallower dent than mid-run")
    func cornerBreaksSooner() {
        let length = Double(lane.span(.leading).length)

        #expect(TapeMotion.breaks(fraction: 0.12, depth: 11, length: length))
        #expect(!TapeMotion.breaks(fraction: 0.5, depth: 11, length: length))
    }

    @Test("Once settled, both halves hang curled into the zone, recoiled and lifted, with no twist left")
    func tornHalvesSettle() throws {
        let motion = TapeMotion()
        motion.begin(at: 0)
        let press = pressLeading(motion, to: 40, atY: 170)
        let run = try #require(leadingRun(in: motion.pose(at: press.end + 3, on: lane)))

        for half in run.halves {
            #expect(half.curl > 0.3)
            #expect(half.stretch < 0)
            #expect(half.lift > 1)
            #expect(abs(half.twist) < 0.001)
            #expect(abs(half.fold) < 0.001)
        }
    }

    @Test("The snap overshoots before it settles, so the free end whips")
    func snapWhips() throws {
        let motion = TapeMotion()
        motion.begin(at: 0)
        let press = pressLeading(motion, to: 40, atY: 170)
        let snappedAt = try #require(press.snappedAt)

        let peak =
            stride(from: snappedAt, through: snappedAt + 0.3, by: 1.0 / 240)
            .compactMap { leadingRun(in: motion.pose(at: $0, on: lane))?.halves[0].curl }
            .max() ?? 0
        let rest = try #require(leadingRun(in: motion.pose(at: snappedAt + 3, on: lane))).halves[0].curl
        #expect(peak > rest * 1.2)
    }

    @Test("When the drag leaves, the break closes and the tape comes to rest sealed")
    func leavingReseals() {
        let motion = TapeMotion()
        motion.begin(at: 0)
        let press = pressLeading(motion, to: 40, atY: 170)
        motion.end(at: press.end + 0.5)

        let pose = motion.pose(at: press.end + 3, on: lane)
        #expect(pose.runs.isEmpty)
        #expect(pose.heat < 0.001)
    }

    @Test("Backing out before the break lets the band spring back into line")
    func backingOutRelaxes() {
        let motion = TapeMotion()
        motion.begin(at: 0)
        let press = pressLeading(motion, to: 7, atY: 170)
        _ = motion.track(CGPoint(x: -10, y: 170), on: lane, at: press.end)

        #expect(motion.pose(at: press.end + 2, on: lane).runs.isEmpty)
    }

    @Test("A drop goes through even where nothing pressed: the band breaks level with the pointer")
    func dropBreaksWithoutPress() throws {
        let motion = TapeMotion()
        motion.begin(at: 0)
        let pointer = CGPoint(x: -8, y: 100)
        _ = motion.track(pointer, on: lane, at: 0.1)

        #expect(motion.land(on: lane, near: pointer, at: 0.2))
        let run = try #require(leadingRun(in: motion.pose(at: 3, on: lane)))
        #expect(run.isTorn)
        let span = lane.span(.leading)
        #expect(abs(run.breakFraction - span.distance(of: pointer) / span.length) < 0.01)
    }

    @Test("A drop onto a tape that already broke keeps it open without a second snap")
    func dropAfterBreakHolds() {
        let motion = TapeMotion()
        motion.begin(at: 0)
        let press = pressLeading(motion, to: 40, atY: 170)

        #expect(!motion.land(on: lane, near: CGPoint(x: 60, y: 170), at: press.end))
        #expect(motion.pose(at: press.end + 2, on: lane).runs.first?.isTorn == true)
    }

    @Test("Coming back before the gap has closed goes through the same gap without a second snap")
    func reentryReopensWithoutSnap() throws {
        let motion = TapeMotion()
        motion.begin(at: 0)
        let press = pressLeading(motion, to: 40, atY: 170)
        try #require(press.snappedAt != nil)
        let tear = try #require(leadingRun(in: motion.pose(at: press.end, on: lane))).breakFraction
        motion.end(at: press.end)
        motion.begin(at: press.end + 0.05)

        #expect(!motion.track(CGPoint(x: 20, y: 120), on: lane, at: press.end + 0.05))
        let run = try #require(leadingRun(in: motion.pose(at: press.end + 2, on: lane)))
        #expect(run.isTorn)
        #expect(run.breakFraction == tear)
        for half in run.halves {
            #expect(half.curl > 0.3)
        }
    }

    @Test("A drop while the gap is closing opens it again instead of breaking the band a second time")
    func dropDuringResealReopens() throws {
        let motion = TapeMotion()
        motion.begin(at: 0)
        let press = pressLeading(motion, to: 40, atY: 170)
        let tear = try #require(leadingRun(in: motion.pose(at: press.end, on: lane))).breakFraction
        motion.end(at: press.end)
        motion.begin(at: press.end + 0.05)
        let outside = CGPoint(x: -8, y: 170)
        _ = motion.track(outside, on: lane, at: press.end + 0.05)

        #expect(!motion.land(on: lane, near: outside, at: press.end + 0.1))
        let run = try #require(leadingRun(in: motion.pose(at: press.end + 2, on: lane)))
        #expect(run.isTorn)
        #expect(run.breakFraction == tear)
    }

    @Test("Once the gap has closed, the next crossing breaks the band afresh where it presses")
    func resealedTapeSnapsAgain() throws {
        let motion = TapeMotion()
        motion.begin(at: 0)
        let first = pressLeading(motion, to: 40, atY: 170)
        motion.end(at: first.end)

        motion.begin(at: first.end + 2)
        let second = pressLeading(motion, to: 40, atY: 100, from: first.end + 2)
        #expect(second.snappedAt != nil)
        let run = try #require(leadingRun(in: motion.pose(at: second.end + 2, on: lane)))
        let span = lane.span(.leading)
        #expect(abs(run.breakFraction - span.distance(of: CGPoint(x: 0, y: 100)) / span.length) < 0.01)
    }

    @Test("The load keeps pressing the run it came in over, even once another run is nearer")
    func approachIsSticky() throws {
        let motion = TapeMotion()
        motion.begin(at: 0)
        // At y 9 the pointer ends up 6pt into the leading run but only 4pt into the top one.
        let press = pressLeading(motion, to: 6, atY: 9)

        #expect(press.snappedAt == nil)
        let pose = motion.pose(at: press.end + 1, on: lane)
        #expect(pose.runs.map(\.side) == [.leading])
        let run = try #require(leadingRun(in: pose))
        #expect(!run.isTorn)
        #expect(abs(run.depth - 6) < 0.5)
    }

    @Test("Under Reduce Motion the band holds still until it breaks, then shows the break at rest")
    func reduceMotionCuts() throws {
        let motion = TapeMotion()
        motion.reducesMotion = true
        motion.begin(at: 0)
        let shallow = pressLeading(motion, to: 7, atY: 170)
        #expect(leadingRun(in: motion.pose(at: shallow.end, on: lane)) == nil)

        let press = pressLeading(motion, to: 40, atY: 170, from: shallow.end)
        let snappedAt = try #require(press.snappedAt)
        let atSnap = try #require(leadingRun(in: motion.pose(at: snappedAt, on: lane))).halves[0]
        let settled = try #require(leadingRun(in: motion.pose(at: snappedAt + 3, on: lane))).halves[0]
        #expect(atSnap.curl == settled.curl)
        #expect(atSnap.lift == settled.lift)
    }

    @Test("Under Reduce Motion the break closes at once when the drag leaves")
    func reduceMotionSealsAtOnce() {
        let motion = TapeMotion()
        motion.reducesMotion = true
        motion.begin(at: 0)
        let press = pressLeading(motion, to: 40, atY: 170)
        #expect(press.snappedAt != nil)
        motion.end(at: press.end)

        #expect(motion.pose(at: press.end, on: lane).runs.isEmpty)
    }

    // Each motion starts well after the entry has warmed the band, so the
    // deadline it leaves can only come from the event under test.
    nonisolated enum Settling: CaseIterable {
        case warmUp
        case hold
        case snap
        case twang
        case drop
        case coolDown
        case reseal
        case reopen
        case hoverOverTear
    }

    private func play(_ settling: Settling, on motion: TapeMotion) {
        motion.begin(at: 0)
        switch settling {
        case .warmUp:
            break
        case .hold:
            _ = pressLeading(motion, to: 7, atY: 170, from: 3)
        case .snap:
            _ = pressLeading(motion, to: 40, atY: 170, from: 3)
        case .twang:
            let press = pressLeading(motion, to: 7, atY: 170, from: 3)
            _ = motion.track(CGPoint(x: -10, y: 170), on: lane, at: press.end + 3)
        case .drop:
            _ = motion.track(CGPoint(x: -8, y: 100), on: lane, at: 0.1)
            _ = motion.land(on: lane, near: CGPoint(x: -8, y: 100), at: 3)
        case .coolDown:
            motion.end(at: 3)
        case .reseal:
            let press = pressLeading(motion, to: 40, atY: 170, from: 3)
            motion.end(at: press.end + 3)
        case .reopen:
            let press = pressLeading(motion, to: 40, atY: 170, from: 3)
            motion.end(at: press.end + 3)
            motion.begin(at: press.end + 3.05)
            _ = motion.track(CGPoint(x: 20, y: 120), on: lane, at: press.end + 3.05)
        case .hoverOverTear:
            let press = pressLeading(motion, to: 40, atY: 170, from: 3)
            for step in 0..<120 {
                let time = press.end + 3 + Double(step) / 120
                _ = motion.track(CGPoint(x: 60 + Double(step), y: 170), on: lane, at: time)
            }
        }
    }

    // Lift and depth are in points, so they get ten times the room of the angles
    // and fractions.
    private func drift(from settled: TapePose, to pose: TapePose) -> Double {
        guard pose.runs.map(\.side) == settled.runs.map(\.side),
            pose.runs.map(\.isTorn) == settled.runs.map(\.isTorn)
        else { return .infinity }
        var worst = abs(pose.heat - settled.heat)
        for (run, rest) in zip(pose.runs, settled.runs) {
            worst = max(worst, abs(run.breakFraction - rest.breakFraction), abs(run.depth - rest.depth) / 10)
            for (half, still) in zip(run.halves, rest.halves) {
                worst = max(
                    worst, abs(half.bend - still.bend), abs(half.fold - still.fold), abs(half.curl - still.curl),
                    abs(half.twist - still.twist), abs(half.stretch - still.stretch), abs(half.lift - still.lift) / 10)
            }
        }
        return worst
    }

    @Test("A drag leaving a band that never moved asks for no frames")
    func idleEndAsksForNoFrames() {
        let motion = TapeMotion()
        motion.end(at: 10)

        #expect(motion.settleDeadline <= 10)
    }

    @Test("Moving over a settled tear, dropping on it or re-entering asks for no more frames")
    func settledTearAsksForNoFrames() {
        let motion = TapeMotion()
        motion.begin(at: 0)
        let press = pressLeading(motion, to: 40, atY: 170)
        let deadline = motion.settleDeadline

        for step in 0..<60 {
            _ = motion.track(CGPoint(x: 60 + Double(step), y: 170), on: lane, at: press.end + 2 + Double(step) / 120)
        }
        motion.begin(at: press.end + 3)
        #expect(!motion.land(on: lane, near: CGPoint(x: 120, y: 170), at: press.end + 3))
        #expect(motion.settleDeadline == deadline)
    }

    @Test("Under Reduce Motion a press that doesn't break asks for no frames")
    func reducedPressAsksForNoFrames() {
        let motion = TapeMotion()
        motion.reducesMotion = true
        motion.begin(at: 0)
        let deadline = motion.settleDeadline

        let press = pressLeading(motion, to: 7, atY: 170, from: 5)
        _ = motion.track(CGPoint(x: -10, y: 170), on: lane, at: press.end)
        #expect(motion.settleDeadline == deadline)
    }

    // A window, not one instant: a residual that still rings can cross its
    // resting value exactly at the deadline.
    @Test(
        "Nothing moves once the settle deadline has passed, so the paused timeline never freezes a motion",
        arguments: Settling.allCases, [false, true])
    func nothingMovesAfterTheDeadline(_ settling: Settling, reducesMotion: Bool) {
        let motion = TapeMotion()
        motion.reducesMotion = reducesMotion
        play(settling, on: motion)
        let deadline = motion.settleDeadline
        let settled = motion.pose(at: deadline + 10, on: lane)

        let worst =
            stride(from: deadline, through: deadline + 0.5, by: 1.0 / 120)
            .map { drift(from: settled, to: motion.pose(at: $0, on: lane)) }
            .max() ?? 0
        #expect(worst < 1e-3)
    }

    @Test("While the band is folded around the load, its two legs meet at the pointer")
    func foldLegsMeet() {
        let length = 308.0
        let depth = 12.0
        let halves = TapeMotion.fold(at: 0.3, depth: depth, length: length)

        let near = 0.3 * length * (1 + halves[0].stretch)
        let far = 0.7 * length * (1 + halves[1].stretch)
        #expect(abs(near * sin(halves[0].bend) - depth) < 0.001)
        #expect(abs(far * sin(halves[1].bend) - depth) < 0.001)
        #expect(abs(near * cos(halves[0].bend) + far * cos(halves[1].bend) - length) < 0.001)
    }
}
