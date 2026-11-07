//
//  TapeLane.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import CoreGraphics

nonisolated enum TapeMetrics {
    static let radius: CGFloat = 16
    static let bandWidth: CGFloat = 10
    static let edgeWidth: CGFloat = 0.75
}

nonisolated enum TapeSide: CaseIterable {
    case top
    case trailing
    case bottom
    case leading
}

nonisolated struct TapeSpan {
    let start: CGPoint
    let direction: CGVector
    let inward: CGVector
    let length: CGFloat
    let startAlong: CGFloat

    func point(at distance: CGFloat, across: CGFloat = 0) -> CGPoint {
        CGPoint(
            x: start.x + direction.dx * distance + inward.dx * across,
            y: start.y + direction.dy * distance + inward.dy * across)
    }

    // Negative while `point` is still outside the band.
    func depth(of point: CGPoint) -> CGFloat {
        (point.x - start.x) * inward.dx + (point.y - start.y) * inward.dy
    }

    func distance(of point: CGPoint) -> CGFloat {
        (point.x - start.x) * direction.dx + (point.y - start.y) * direction.dy
    }
}

// `along` walks the centreline clockwise from the end of the top-left corner;
// `across` is positive toward the inside of the frame.
nonisolated struct TapeLane {
    let rect: CGRect
    private let inset: CGFloat
    private let cornerRadius: CGFloat
    private let straightWidth: CGFloat
    private let straightHeight: CGFloat
    private let arc: CGFloat
    let length: CGFloat

    init(rect: CGRect) {
        self.rect = rect
        inset = TapeMetrics.bandWidth / 2
        cornerRadius = max(0, TapeMetrics.radius - inset)
        straightWidth = max(0, rect.width - 2 * inset - 2 * cornerRadius)
        straightHeight = max(0, rect.height - 2 * inset - 2 * cornerRadius)
        arc = .pi / 2 * cornerRadius
        length = 2 * straightWidth + 2 * straightHeight + 4 * arc
    }

    func span(_ side: TapeSide) -> TapeSpan {
        let minX = rect.minX + inset
        let minY = rect.minY + inset
        let maxX = rect.maxX - inset
        let maxY = rect.maxY - inset
        switch side {
        case .top:
            return TapeSpan(
                start: CGPoint(x: minX + cornerRadius, y: minY), direction: CGVector(dx: 1, dy: 0),
                inward: CGVector(dx: 0, dy: 1), length: straightWidth, startAlong: 0)
        case .trailing:
            return TapeSpan(
                start: CGPoint(x: maxX, y: minY + cornerRadius), direction: CGVector(dx: 0, dy: 1),
                inward: CGVector(dx: -1, dy: 0), length: straightHeight, startAlong: straightWidth + arc)
        case .bottom:
            return TapeSpan(
                start: CGPoint(x: maxX - cornerRadius, y: maxY), direction: CGVector(dx: -1, dy: 0),
                inward: CGVector(dx: 0, dy: -1), length: straightWidth,
                startAlong: straightWidth + straightHeight + 2 * arc)
        case .leading:
            return TapeSpan(
                start: CGPoint(x: minX, y: maxY - cornerRadius), direction: CGVector(dx: 0, dy: -1),
                inward: CGVector(dx: 1, dy: 0), length: straightHeight,
                startAlong: 2 * straightWidth + straightHeight + 3 * arc)
        }
    }

    func point(along: CGFloat, across: CGFloat) -> CGPoint {
        var distance = along.truncatingRemainder(dividingBy: length)
        if distance < 0 { distance += length }
        let minX = rect.minX + inset
        let minY = rect.minY + inset
        let maxX = rect.maxX - inset
        let maxY = rect.maxY - inset

        if distance < straightWidth {
            return CGPoint(x: minX + cornerRadius + distance, y: minY + across)
        }
        distance -= straightWidth
        if distance < arc {
            return corner(
                center: CGPoint(x: maxX - cornerRadius, y: minY + cornerRadius),
                angle: -.pi / 2 + distance / cornerRadius, across: across)
        }
        distance -= arc
        if distance < straightHeight {
            return CGPoint(x: maxX - across, y: minY + cornerRadius + distance)
        }
        distance -= straightHeight
        if distance < arc {
            return corner(
                center: CGPoint(x: maxX - cornerRadius, y: maxY - cornerRadius),
                angle: distance / cornerRadius, across: across)
        }
        distance -= arc
        if distance < straightWidth {
            return CGPoint(x: maxX - cornerRadius - distance, y: maxY - across)
        }
        distance -= straightWidth
        if distance < arc {
            return corner(
                center: CGPoint(x: minX + cornerRadius, y: maxY - cornerRadius),
                angle: .pi / 2 + distance / cornerRadius, across: across)
        }
        distance -= arc
        if distance < straightHeight {
            return CGPoint(x: minX + across, y: maxY - cornerRadius - distance)
        }
        distance -= straightHeight
        return corner(
            center: CGPoint(x: minX + cornerRadius, y: minY + cornerRadius),
            angle: .pi + distance / cornerRadius, across: across)
    }

    private func corner(center: CGPoint, angle: CGFloat, across: CGFloat) -> CGPoint {
        let reach = max(0, cornerRadius - across)
        return CGPoint(x: center.x + reach * cos(angle), y: center.y + reach * sin(angle))
    }
}
