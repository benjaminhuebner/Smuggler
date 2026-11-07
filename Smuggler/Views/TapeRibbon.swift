//
//  TapeRibbon.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 25.09.26.
//

import SwiftUI

// Stripes, edges and outline all come from `point(along:across:)`, so the print
// follows the strip wherever the physics puts it.
nonisolated struct TapeRibbon {
    struct Sample {
        var along: CGFloat
        var point: CGPoint
        var normal: CGVector
        var acrossScale: CGFloat
        var lift: CGFloat
    }

    enum End {
        case cut
        case torn(profile: [CGFloat])
    }

    // Ordered by increasing `along`.
    let samples: [Sample]
    let low: (along: CGFloat, end: End)
    let high: (along: CGFloat, end: End)

    private static let halfWidth = TapeMetrics.bandWidth / 2

    func point(along: CGFloat, across: CGFloat) -> CGPoint {
        let (index, fraction) = segment(containing: along)
        let first = samples[index]
        let second = samples[index + 1]
        // Positions extrapolate past either end in a straight line; the frame
        // around the point does not.
        let clamped = min(max(fraction, 0), 1)
        let x = first.point.x + (second.point.x - first.point.x) * fraction
        let y = first.point.y + (second.point.y - first.point.y) * fraction
        let normalX = first.normal.dx + (second.normal.dx - first.normal.dx) * clamped
        let normalY = first.normal.dy + (second.normal.dy - first.normal.dy) * clamped
        let scale = first.acrossScale + (second.acrossScale - first.acrossScale) * clamped
        return CGPoint(x: x + normalX * across * scale, y: y + normalY * across * scale)
    }

    func lift(along: CGFloat) -> CGFloat {
        let (index, fraction) = segment(containing: along)
        let clamped = min(max(fraction, 0), 1)
        return samples[index].lift + (samples[index + 1].lift - samples[index].lift) * clamped
    }

    var outline: Path {
        let outer = -Self.halfWidth
        let inner = Self.halfWidth
        var points = edgePoints(across: outer, from: endAlong(low, outer), to: endAlong(high, outer))
        points += endPoints(high, from: outer, to: inner)
        points += edgePoints(across: inner, from: endAlong(high, inner), to: endAlong(low, inner))
        points += endPoints(low, from: inner, to: outer)
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        return path
    }

    var edges: Path {
        let inset = Self.halfWidth - TapeMetrics.edgeWidth / 2
        var path = Path()
        for across in [-inset, inset] {
            path.addLines(edgePoints(across: across, from: endAlong(low, across), to: endAlong(high, across)))
        }
        return path
    }

    func stripes(period: CGFloat) -> Path {
        let range = (low.along - 10)...(high.along + 10)
        return HazardStripes.path(
            period: period, stripes: HazardStripes.stripes(covering: range, period: period), point: point)
    }

    // Each point drops by its own height, so neighbouring pieces of the shadow meet.
    func shadow(from start: CGFloat, to stop: CGFloat, drop: CGFloat) -> Path {
        var path = Path()
        let upper = edgePoints(across: -Self.halfWidth, from: start, to: stop)
        let lower = edgePoints(across: Self.halfWidth, from: stop, to: start)
        let alongs = edgeAlongs(from: start, to: stop)
        let dropped =
            zip(upper, alongs).map { CGPoint(x: $0.x, y: $0.y + lift(along: $1) * drop) }
            + zip(lower, alongs.reversed()).map { CGPoint(x: $0.x, y: $0.y + lift(along: $1) * drop) }
        path.addLines(dropped)
        path.closeSubpath()
        return path
    }

    private func endAlong(_ end: (along: CGFloat, end: End), _ across: CGFloat) -> CGFloat {
        guard case .torn(let profile) = end.end, profile.count > 1 else { return end.along }
        let position = (across + Self.halfWidth) / (2 * Self.halfWidth) * CGFloat(profile.count - 1)
        let index = min(max(Int(position.rounded(.down)), 0), profile.count - 2)
        let fraction = position - CGFloat(index)
        return end.along + profile[index] + (profile[index + 1] - profile[index]) * fraction
    }

    private func endPoints(_ end: (along: CGFloat, end: End), from start: CGFloat, to stop: CGFloat) -> [CGPoint] {
        guard case .torn(let profile) = end.end, profile.count > 2 else { return [] }
        let count = profile.count - 1
        return (1..<count).map { step in
            let across = start + (stop - start) * CGFloat(step) / CGFloat(count)
            return point(along: endAlong(end, across), across: across)
        }
    }

    private func edgeAlongs(from start: CGFloat, to stop: CGFloat) -> [CGFloat] {
        let lower = min(start, stop)
        let upper = max(start, stop)
        let inner = samples.lazy.map(\.along).filter { $0 > lower && $0 < upper }
        let rising = [lower] + inner + [upper]
        return start <= stop ? rising : rising.reversed()
    }

    private func edgePoints(across: CGFloat, from start: CGFloat, to stop: CGFloat) -> [CGPoint] {
        edgeAlongs(from: start, to: stop).map { point(along: $0, across: across) }
    }

    private func segment(containing along: CGFloat) -> (index: Int, fraction: CGFloat) {
        let last = samples.count - 1
        var lower = 0
        var upper = last
        if along <= samples[0].along {
            upper = 1
        } else if along >= samples[last].along {
            lower = last - 1
        } else {
            while upper - lower > 1 {
                let middle = (lower + upper) / 2
                if samples[middle].along <= along { lower = middle } else { upper = middle }
            }
        }
        let span = samples[upper].along - samples[lower].along
        return (lower, span > 0 ? (along - samples[lower].along) / span : 0)
    }
}

// MARK: - Torn Half

nonisolated struct TapeHalf {
    let pose: TapeHalfPose
    let length: CGFloat
    let span: TapeSpan
    let isFromEnd: Bool

    private static let step: CGFloat = 2
    private static let focalLength: CGFloat = 900
    // The curl gathers over most of a half and tightens toward the free end,
    // so it hangs like a ribbon rather than a hook.
    static let curlShape: CGFloat = 1.4

    static func curlLength(for length: CGFloat) -> CGFloat {
        max(1, min(length, max(80, 0.75 * length)))
    }

    func samples(lead: CGFloat, trail: CGFloat, focus: CGPoint) -> [TapeRibbon.Sample] {
        let direction = isFromEnd ? CGVector(dx: -span.direction.dx, dy: -span.direction.dy) : span.direction
        let anchor = isFromEnd ? span.point(at: span.length) : span.start
        let bendLength = max(1, min(16, length / 3))
        let foldLength = max(1, min(10, length / 4))
        let curlLength = Self.curlLength(for: length)
        let stretch = 1 + CGFloat(pose.stretch)

        // No turn at the corner itself, where the half is still taped down.
        func angle(_ material: CGFloat) -> CGFloat {
            let curl = max(0, (material - (length - curlLength)) / curlLength)
            return CGFloat(pose.bend) * Self.smoothstep(material / bendLength)
                + CGFloat(pose.fold) * Self.smoothstep((material - (length - foldLength)) / foldLength)
                + CGFloat(pose.curl) * pow(curl, Self.curlShape)
        }

        var samples: [TapeRibbon.Sample] = []
        samples.reserveCapacity(Int((length + trail) / Self.step) + 3)
        var position = CGPoint(x: anchor.x - direction.dx * lead, y: anchor.y - direction.dy * lead)
        var material = -lead
        let end = length + trail
        while true {
            let turn = material > 0 ? angle(material) : 0
            let reach = max(0, material) / max(1, length)
            let lift = CGFloat(pose.lift) * reach * reach
            let twist = CGFloat(pose.twist) * reach * reach * reach
            let scale = Self.focalLength / (Self.focalLength - lift)
            let normal = CGVector(
                dx: -sin(turn) * direction.dx + cos(turn) * span.inward.dx,
                dy: -sin(turn) * direction.dy + cos(turn) * span.inward.dy)
            samples.append(
                TapeRibbon.Sample(
                    along: isFromEnd ? span.startAlong + span.length - material : span.startAlong + material,
                    point: CGPoint(
                        x: focus.x + (position.x - focus.x) * scale, y: focus.y + (position.y - focus.y) * scale),
                    normal: normal, acrossScale: cos(twist) * scale, lift: lift))
            guard material < end else { break }
            let next = min(end, material + (material < 0 ? -material : Self.step))
            let middle = next > 0 ? angle((max(material, 0) + next) / 2) : 0
            let distance = (next - material) * (material < 0 ? 1 : stretch)
            position.x += distance * (cos(middle) * direction.dx + sin(middle) * span.inward.dx)
            position.y += distance * (cos(middle) * direction.dy + sin(middle) * span.inward.dy)
            material = next
        }
        return isFromEnd ? samples.reversed() : samples
    }

    private static func smoothstep(_ value: CGFloat) -> CGFloat {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }
}
