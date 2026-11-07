//
//  TapeRenderer.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import SwiftUI

struct TapeRenderer {
    let pose: TapePose
    let lane: TapeLane
    let contrast: ColorSchemeContrast

    // Both halves of a break share one profile, so at rest they tile back with
    // no seam. The long excursions leave a frayed strand on each half.
    private static let tearProfile: [CGFloat] = [0.5, -2, 1.5, 8, -0.5, 2.5, -7.5, -1, 3.5, -3, 1.5, 0]
    // How far a moving piece reaches back over the loop it leaves, so no
    // hairline of background opens at the join. Only while the band is opaque:
    // two translucent copies would double into a dark bar.
    private static let junction: CGFloat = 1.5

    private var rect: CGRect { lane.rect }

    // Increase Contrast darkens the system greys only in proportion, and the
    // sealed band shows small shares of them, so there it takes larger ones.
    private var sealed: (fill: Double, stripe: Double, edge: Double) {
        contrast == .increased ? (0.22, 0.62, 0.3) : (0.18, 0.5, 0.2)
    }

    private var frame: RoundedRectangle {
        RoundedRectangle(cornerRadius: TapeMetrics.radius, style: .continuous)
    }

    func draw(in context: inout GraphicsContext) {
        guard lane.length > 0 else { return }
        let heat = pose.heat
        let lead = Self.junction * CGFloat(heat)
        let period = HazardStripes.period(forLoopLength: lane.length)
        let runs = pose.runs.filter { lane.span($0.side).length >= 2 }
        let ribbons = runs.flatMap { ribbons(for: $0, lead: lead) }

        if heat > 0.001 {
            context.fill(frame.path(in: rect), with: .color(Color.smugglerYellow.opacity(0.05 * heat)))
        }
        drawShadows(of: ribbons.filter(\.isLifted).map(\.ribbon), in: context)

        // Form carries the metaphor, color carries the action: the hatching
        // reads as barrier tape in either state, and only the drag turns it into
        // the icon's black-on-yellow.
        let fill = Color.secondary.opacity(sealed.fill).mix(with: .smugglerYellow, by: heat)
        let stripe = Color.secondary.opacity(sealed.stripe).mix(with: .smugglerOnYellow, by: heat)
        let edge = Color.primary.opacity(sealed.edge).mix(with: Color.smugglerOnYellow.opacity(0.5), by: heat)

        let band = frame.inset(by: TapeMetrics.bandWidth / 2).path(in: rect)
            .strokedPath(StrokeStyle(lineWidth: TapeMetrics.bandWidth))
        var cutouts = Path()
        // The loop's hairlines also give way over the lead: the piece's own edge
        // runs there, and two half-opaque copies would double into a dark tick.
        var hairlineCutouts = Path()
        for run in runs {
            let span = lane.span(run.side)
            cutouts.addPath(cutout(for: span))
            hairlineCutouts.addPath(cutout(for: span, overlap: lead))
        }

        var loop = context
        if !runs.isEmpty { loop.clip(to: cutouts, options: .inverse) }
        loop.fill(band, with: .color(fill))
        loop.clip(to: band)
        loop.fill(
            HazardStripes.path(
                period: period, stripes: 0..<Int((lane.length / period).rounded()), point: lane.point),
            with: .color(stripe))

        let outlines = ribbons.map(\.ribbon.outline)
        for (piece, outline) in zip(ribbons, outlines) {
            var strip = context
            strip.clip(to: outline)
            strip.fill(outline, with: .color(fill))
            strip.fill(piece.ribbon.stripes(period: period), with: .color(stripe))
        }

        // One light source across the whole strip, laid over its outline rather
        // than its paint, so the translucent resting band catches it as fully
        // as the yellow one — and laid once, so overlapping pieces don't double it.
        context.drawLayer { light in
            var shape = light
            if !runs.isEmpty { shape.clip(to: cutouts, options: .inverse) }
            shape.fill(band, with: .color(.black))
            for outline in outlines { light.fill(outline, with: .color(.black)) }
            light.blendMode = .sourceIn
            light.fill(
                Path(rect),
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .white.opacity(0.16), location: 0),
                        .init(color: .clear, location: 0.45),
                        .init(color: .black.opacity(0.18), location: 1),
                    ]),
                    startPoint: CGPoint(x: rect.midX, y: rect.minY),
                    endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        }

        // A hairline on both edges of the strip, the one cue the frame borrows
        // from the icon's tape. Kept faint, firmer only for Increase Contrast:
        // content on the Mac stays flat.
        var hairlines = context
        if !runs.isEmpty { hairlines.clip(to: hairlineCutouts, options: .inverse) }
        let edgeInset = TapeMetrics.edgeWidth / 2
        hairlines.stroke(
            frame.inset(by: edgeInset).path(in: rect), with: .color(edge), lineWidth: TapeMetrics.edgeWidth)
        hairlines.stroke(
            frame.inset(by: TapeMetrics.bandWidth - edgeInset).path(in: rect), with: .color(edge),
            lineWidth: TapeMetrics.edgeWidth)
        for piece in ribbons {
            context.stroke(piece.ribbon.edges, with: .color(edge), lineWidth: TapeMetrics.edgeWidth)
        }
    }

    private struct Piece {
        let ribbon: TapeRibbon
        let isLifted: Bool
    }

    private func ribbons(for run: TapeRunPose, lead: CGFloat) -> [Piece] {
        let span = lane.span(run.side)
        let focus = CGPoint(x: rect.midX, y: rect.midY)
        let breakDistance = CGFloat(run.breakFraction) * span.length
        let breakAlong = span.startAlong + breakDistance
        let halves = [
            TapeHalf(pose: run.halves[0], length: breakDistance, span: span, isFromEnd: false),
            TapeHalf(pose: run.halves[1], length: span.length - breakDistance, span: span, isFromEnd: true),
        ]

        guard run.isTorn else {
            // Still whole: one strip over the fold, pinned to the point the
            // load presses, so no seam can open where the halves meet.
            let apex = span.point(at: breakDistance, across: CGFloat(run.depth))
            let near = pinned(halves[0].samples(lead: lead, trail: 0, focus: focus), to: apex, at: breakAlong)
            let far = pinned(halves[1].samples(lead: lead, trail: 0, focus: focus), to: apex, at: breakAlong)
            return [
                Piece(
                    ribbon: TapeRibbon(
                        samples: near + far.dropFirst(), low: (span.startAlong - lead, .cut),
                        high: (span.startAlong + span.length + lead, .cut)),
                    isLifted: false)
            ]
        }

        // The trailing and bottom runs walk the profile backwards, so tears on
        // different sides fray differently instead of mirroring each other.
        let profile = run.side == .top || run.side == .leading ? Self.tearProfile : Self.tearProfile.reversed()
        let trail = (profile.map(abs).max() ?? 0) + 4
        return [
            Piece(
                ribbon: TapeRibbon(
                    samples: halves[0].samples(lead: lead, trail: trail, focus: focus),
                    low: (span.startAlong - lead, .cut), high: (breakAlong, .torn(profile: profile))),
                isLifted: true),
            Piece(
                ribbon: TapeRibbon(
                    samples: halves[1].samples(lead: lead, trail: trail, focus: focus),
                    low: (breakAlong, .torn(profile: profile)), high: (span.startAlong + span.length + lead, .cut)),
                isLifted: true),
        ]
    }

    // Shifts a leg by a share of its miss that grows from nothing at the corner,
    // so it ends exactly on the fold and the join stays smooth.
    private func pinned(_ samples: [TapeRibbon.Sample], to apex: CGPoint, at along: CGFloat) -> [TapeRibbon.Sample] {
        guard let tip = samples.min(by: { abs($0.along - along) < abs($1.along - along) }),
            let anchorAlong = samples.max(by: { abs($0.along - along) < abs($1.along - along) })?.along,
            abs(anchorAlong - along) > 0
        else { return samples }
        let missX = apex.x - tip.point.x
        let missY = apex.y - tip.point.y
        return samples.map { sample in
            var sample = sample
            let share = max(0, 1 - abs(sample.along - along) / abs(anchorAlong - along))
            sample.point.x += missX * share
            sample.point.y += missY * share
            return sample
        }
    }

    private func cutout(for span: TapeSpan, overlap: CGFloat = 0) -> Path {
        let reach = TapeMetrics.bandWidth / 2 + 3
        var path = Path()
        path.addLines([
            span.point(at: -overlap, across: -reach), span.point(at: span.length + overlap, across: -reach),
            span.point(at: span.length + overlap, across: reach), span.point(at: -overlap, across: reach),
        ])
        path.closeSubpath()
        return path
    }

    // Motion depth, not surface depth: only a piece off the surface casts a
    // shadow, and it deepens with the height of each part of it.
    private func drawShadows(of ribbons: [TapeRibbon], in context: GraphicsContext) {
        let pieces = 10
        let drop: CGFloat = 0.45
        guard ribbons.contains(where: { ribbon in ribbon.samples.contains { $0.lift > 0.3 } }) else { return }
        // Filtered from outside, so the finished layer is blurred once; a filter
        // inside it would blur every piece on its own.
        var shadows = context
        shadows.addFilter(.blur(radius: 3))
        shadows.drawLayer { layer in
            for ribbon in ribbons {
                let start = ribbon.low.along
                let length = ribbon.high.along - start
                for piece in 0..<pieces {
                    let from = start + length * CGFloat(piece) / CGFloat(pieces)
                    let to = start + length * CGFloat(piece + 1) / CGFloat(pieces)
                    let height = ribbon.lift(along: (from + to) / 2)
                    guard height > 0.3 else { continue }
                    layer.fill(
                        ribbon.shadow(from: from, to: to, drop: drop),
                        with: .color(.black.opacity(0.22 * min(1, Double(height) / 14))))
                }
            }
        }
    }
}
