//
//  TapeRendererTests.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import AppKit
import CoreGraphics
import SwiftUI
import Testing

@testable import Smuggler

@Suite("TapeRenderer")
@MainActor
struct TapeRendererTests {
    // The empty state's frame in the default 520×380 window.
    private let lane = TapeLane(rect: CGRect(x: 0, y: 0, width: 480, height: 340))

    // The system setting reaches the greys through the environment (settable
    // only through its underscored key); `tape` is the renderer's own input.
    private func render(
        _ pose: TapePose, system: ColorSchemeContrast = .standard, tape: ColorSchemeContrast = .standard,
        scheme: ColorScheme = .light, scale: CGFloat = 4
    ) throws -> Bitmap {
        let lane = lane
        let view = Canvas { context, _ in
            TapeRenderer(pose: pose, lane: lane, contrast: tape).draw(in: &context)
        }
        .frame(width: lane.rect.width, height: lane.rect.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, scheme)
        .environment(\._colorSchemeContrast, system)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return try Bitmap(try #require(renderer.cgImage), scale: scale)
    }

    private func pressedTopRun(depth: Double) -> TapePose {
        let length = Double(lane.span(.top).length)
        let fraction = 0.1
        return TapePose(
            heat: 1,
            runs: [
                TapeRunPose(
                    side: .top, breakFraction: fraction, depth: depth, isTorn: false,
                    halves: TapeMotion.fold(at: fraction, depth: depth, length: length))
            ])
    }

    // Where the pressed strip reaches back over the loop at the top-left corner,
    // its inner hairline lies over a yellow gap between two stripes.
    @Test("A pressed run's hairline runs on at one strength where the strip meets the loop")
    func hairlineKeepsItsStrengthAtTheJoin() throws {
        let bitmap = try render(pressedTopRun(depth: 9))
        let start = lane.span(.top).start.x
        let inner = lane.rect.minY + TapeMetrics.bandWidth - TapeMetrics.edgeWidth / 2
        let hairline = (inner - 1.5)...(inner + 1.5)

        let atJoin = stride(from: start - 1.4, through: start - 0.1, by: 0.25)
            .map { bitmap.darkestRed(atX: $0, rows: hairline) }
        let alongTheStrip = stride(from: start + 0.5, through: start + 2, by: 0.25)
            .map { bitmap.darkestRed(atX: $0, rows: hairline) }
        let reference = try #require(alongTheStrip.min())

        #expect(atJoin.allSatisfy { abs($0 - reference) <= 8 })
    }

    // The top run lies under the light end of the gradient and the bottom run
    // under the dark end, so each is the weak spot in one appearance.
    @Test(
        "Under Increase Contrast the sealed hatching stands out 3:1 from the window on every run",
        arguments: [ColorScheme.light, .dark])
    func sealedHatchingHoldsUnderIncreasedContrast(scheme: ColorScheme) throws {
        let bitmap = try render(TapePose(), system: .increased, tape: .increased, scheme: scheme)
        let window = bitmap.luminance(at: CGPoint(x: lane.rect.midX, y: lane.rect.midY))

        for side in TapeSide.allCases {
            let span = lane.span(side)
            let strongest =
                stride(from: 0, through: span.length, by: 0.5)
                .map { Bitmap.contrast(bitmap.luminance(at: span.point(at: $0)), window) }
                .max() ?? 0
            #expect(strongest >= 3, "\(side)")
        }
    }

    // Two renders of one drawing can differ by a step or two in a channel.
    @Test("The targeted band looks the same whatever the contrast setting")
    func targetedBandIgnoresContrast() throws {
        let pose = pressedTopRun(depth: 9)

        let standard = try render(pose, system: .increased, tape: .standard, scale: 2)
        let increased = try render(pose, system: .increased, tape: .increased, scale: 2)
        #expect(standard.largestDifference(from: increased) <= 4)
    }
}

private struct Bitmap {
    private let scale: CGFloat
    private let width: Int
    private let height: Int
    private let bytes: [UInt8]

    init(_ image: CGImage, scale: CGFloat) throws {
        self.scale = scale
        width = image.width
        height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let drawn = bytes.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        try #require(drawn)
        self.bytes = bytes
    }

    func largestDifference(from other: Bitmap) -> Int {
        guard width == other.width, height == other.height else { return .max }
        guard bytes != other.bytes else { return 0 }
        var largest = 0
        for index in bytes.indices {
            largest = max(largest, abs(Int(bytes[index]) - Int(other.bytes[index])))
        }
        return largest
    }

    static func contrast(_ first: Double, _ second: Double) -> Double {
        (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private func offset(atX x: CGFloat, y: CGFloat) -> Int {
        let column = min(max(Int(x * scale), 0), width - 1)
        let row = min(max(Int(y * scale), 0), height - 1)
        return (row * width + column) * 4
    }

    func darkestRed(atX x: CGFloat, rows: ClosedRange<CGFloat>) -> Int {
        stride(from: rows.lowerBound, through: rows.upperBound, by: 1 / scale)
            .map { Int(bytes[offset(atX: x, y: $0)]) }
            .min() ?? 255
    }

    func luminance(at point: CGPoint) -> Double {
        let start = offset(atX: point.x, y: point.y)
        let linear = bytes[start..<start + 3].map { byte in
            let value = Double(byte) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
}
