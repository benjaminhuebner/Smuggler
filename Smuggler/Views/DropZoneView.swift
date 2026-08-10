import SwiftUI

struct DropZoneView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isTargeted: Bool
    let compact: Bool
    let onChooseFiles: () -> Void

    var body: some View {
        if compact {
            compactView
        } else {
            fullView
        }
    }

    // MARK: - Compact (used when results are visible)

    private var compactView: some View {
        HStack(spacing: 10) {
            Image(systemName: isTargeted ? "arrow.down.circle.fill" : "arrow.down.circle")
                .foregroundStyle(isTargeted ? Color.smugglerYellow : Color.secondary.opacity(0.6))
                .font(.title3)
                .contentTransition(.symbolEffect(.replace))

            Text(isTargeted ? "Release to free from quarantine" : "Drop more files here")
                .font(.subheadline)
                .foregroundStyle(isTargeted ? .primary : .secondary)
                .lineLimit(1)

            Spacer()

            // Hidden rather than removed: dropping it from the layout shortens the
            // strip mid-drag and shifts the list the person is aiming at.
            ViewThatFits(in: .horizontal) {
                Button("Choose Files…", systemImage: "plus.circle") {
                    onChooseFiles()
                }
                .buttonStyle(.bordered)
                .font(.subheadline)
                .controlSize(.small)

                Button {
                    onChooseFiles()
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(
                    String(localized: "Choose Files…", comment: "Button: open the file picker")
                )
                .help("Choose Files…")
            }
            .opacity(isTargeted ? 0 : 1)
            .disabled(isTargeted)
            .accessibilityHidden(isTargeted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
        // .contain (not .combine) so the "Choose Files…" button stays reachable.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            isTargeted
                ? String(
                    localized: "Release to free from quarantine",
                    comment: "Drop zone status while a drag hovers over it")
                : String(
                    localized: "Drop zone. Drop more files here.",
                    comment: "Accessibility label: compact drop zone"))
    }

    // MARK: - Full (empty state)

    private var fullView: some View {
        VStack(spacing: 28) {
            // One symbol, not two: the lifting tape is the moment here, and a
            // padlock would put the security metaphor back into a product whose
            // words refuse it.
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(
                    isTargeted
                        ? AnyShapeStyle(Color.smugglerYellow)
                        : AnyShapeStyle(.secondary)
                )
                .symbolEffect(.bounce, value: reduceMotion ? false : isTargeted)
                .frame(height: 64)
                .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.3), value: isTargeted)

            VStack(spacing: 8) {
                Text(isTargeted ? "Release to free from quarantine" : "Drop files to remove quarantine")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .contentTransition(.numericText())

                if !isTargeted {
                    Text("Drag files or folders here, or choose them manually")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isTargeted)

            if !isTargeted {
                Button {
                    onChooseFiles()
                } label: {
                    Label("Choose Files…", systemImage: "folder")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.smugglerOnYellow)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.smugglerYellow)
                .controlSize(.large)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            dropZoneBackground
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            isTargeted
                ? String(
                    localized: "Release to remove quarantine",
                    comment: "Accessibility label: full drop zone while a drag hovers over it")
                : String(
                    localized: "Drop zone. Drag files or folders to remove quarantine.",
                    comment: "Accessibility label: full drop zone"))
    }

    // MARK: - Background

    private static let frameRadius: CGFloat = 16
    private static let tapeWidth: CGFloat = 10
    private static let runThickness = tapeWidth + 1

    // Form carries the metaphor, color carries the action: the hatching reads as
    // barrier tape in either state, and only the drag turns it into the icon's
    // black-on-yellow — yellow at rest would mark a surface where nothing is happening.
    private var tapeFill: Color {
        isTargeted ? Color.smugglerYellow : Color.secondary.opacity(0.12)
    }

    // Opaque colour plus a single opacity pass: the rows overlap by design, and a
    // translucent stroke would compound its alpha into a woven grey at every seam.
    private var tapeStripe: Color {
        isTargeted ? Color.smugglerOnYellow : Color.secondary
    }

    private var tapeStripeOpacity: Double {
        isTargeted ? 1 : 0.34
    }

    private var bandShape: some InsettableShape {
        RoundedRectangle(cornerRadius: Self.frameRadius, style: .continuous)
    }

    // Tape under tension snaps: each half whips past its rest angle and wobbles
    // once, and all four run on different clocks — a symmetric rip reads as a
    // mechanism. Re-sealing is the undo of an action nobody took: plain, quick.
    private static func tearMotion(
        _ tearing: Bool, run: TornTapeHalf.Run, end: TornTapeHalf.End
    ) -> Animation {
        guard tearing else { return .timingCurve(0.3, 0, 0.2, 1, duration: 0.16) }
        switch (run, end) {
        case (.leading, .top): return .spring(duration: 0.3, bounce: 0.45)
        case (.leading, .bottom): return .spring(duration: 0.37, bounce: 0.32)
        case (.trailing, .top): return .spring(duration: 0.34, bounce: 0.38)
        case (.trailing, .bottom): return .spring(duration: 0.4, bounce: 0.28)
        }
    }

    private func tapeBand() -> some View {
        ZStack {
            bandShape.strokeBorder(tapeFill, lineWidth: Self.tapeWidth)

            HazardStripes(radius: Self.frameRadius, bandWidth: Self.tapeWidth, color: tapeStripe)
                .compositingGroup()
                .opacity(tapeStripeOpacity)

            // One light source across the whole strip. Plastic tape is never flat,
            // and a flat band reads as a printed frame instead of something lying
            // on the surface.
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.16), location: 0),
                    .init(color: .clear, location: 0.45),
                    .init(color: .black.opacity(0.18), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .mask { bandShape.strokeBorder(Color.black, lineWidth: Self.tapeWidth) }
        }
    }

    // Barrier tape gives way where the load pushes through: both side runs snap
    // at mid-height and the four freed halves stay hanging from the corners,
    // swung into the zone — a barrier broken open, not a strip tidied away.
    private var dropZoneBackground: some View {
        GeometryReader { proxy in
            let height = max(1, proxy.size.height)
            // Two different heights, both slightly off-centre: snaps that mirror
            // or sit dead-centre read as designed, not torn.
            let leftBreakY = height * 0.47
            let rightBreakY = height * 0.53
            let runLength = max(0, height - 2 * Self.frameRadius)

            ZStack {
                bandShape
                    .fill(Color.smugglerYellow.opacity(0.05))
                    .opacity(isTargeted ? 1 : 0)

                // Top, bottom and corners stay stuck — only the side runs tear.
                tapeBand()
                    .mask {
                        Rectangle()
                            .overlay(alignment: .leading) { sideRunCutout(length: runLength) }
                            .overlay(alignment: .trailing) { sideRunCutout(length: runLength) }
                            .compositingGroup()
                    }

                tornHalf(run: .leading, end: .top, breakY: leftBreakY, in: proxy.size)
                tornHalf(run: .leading, end: .bottom, breakY: leftBreakY, in: proxy.size)
                tornHalf(run: .trailing, end: .top, breakY: rightBreakY, in: proxy.size)
                tornHalf(run: .trailing, end: .bottom, breakY: rightBreakY, in: proxy.size)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isTargeted)
        .padding(20)
        .accessibilityHidden(true)
    }

    private func sideRunCutout(length: CGFloat) -> some View {
        Rectangle()
            .frame(width: Self.runThickness, height: length)
            .blendMode(.destinationOut)
    }

    // Each half hangs from the corner it is still stuck at: it recoils toward it
    // (snapped tape contracts), lifts its torn end off the surface, and swings
    // into the zone under the only shadow in the interface — genuinely airborne.
    private func tornHalf(
        run: TornTapeHalf.Run, end: TornTapeHalf.End, breakY: CGFloat, in size: CGSize
    ) -> some View {
        let torn: CGFloat = isTargeted ? 1 : 0
        let width = max(1, size.width)
        let height = max(1, size.height)
        let hinge = UnitPoint(
            x: run == .leading
                ? Self.runThickness / 2 / width
                : 1 - Self.runThickness / 2 / width,
            y: end == .top
                ? Self.frameRadius / height
                : 1 - Self.frameRadius / height)
        // Swing is always inward (the load arrives from outside), lift always
        // raises the torn end toward the viewer; magnitudes differ per piece so
        // the four halves don't move in lockstep.
        let droop: Double
        let lift: Double
        switch (run, end) {
        case (.leading, .top):
            droop = -11
            lift = 32
        case (.leading, .bottom):
            droop = 9
            lift = -28
        case (.trailing, .top):
            droop = 8.5
            lift = 34
        case (.trailing, .bottom):
            droop = -12
            lift = -26
        }
        return tapeBand()
            .mask {
                TornTapeHalf(
                    run: run, end: end, breakY: breakY,
                    cornerInset: Self.frameRadius, thickness: Self.runThickness)
            }
            .shadow(color: .black.opacity(0.4 * torn), radius: 8 * torn, y: 6 * torn)
            .scaleEffect(x: 1, y: 1 - 0.06 * torn, anchor: hinge)
            .rotation3DEffect(
                .degrees(lift * torn),
                axis: (x: 1, y: 0, z: 0),
                anchor: hinge,
                perspective: 0.55
            )
            .rotationEffect(.degrees(droop * torn), anchor: hinge)
            .animation(
                reduceMotion ? nil : Self.tearMotion(isTargeted, run: run, end: end),
                value: isTargeted)
    }
}

// MARK: - Hazard Stripes

// Stripes drawn in screen space break wherever the band turns, which is the tell
// that gives away a decal. One dashed ring per row, each phase-shifted by its own
// offset, lines the dashes up into a diagonal that carries around the corners.
private struct HazardStripes: View {
    let radius: CGFloat
    let bandWidth: CGFloat
    let color: Color

    private static let nominalPeriod: CGFloat = 26
    // The diagonal is quantised to the row height, so too few rows serrate every
    // stripe edge. At this count the step is well under half a point.
    private static let rows = 44

    var body: some View {
        GeometryReader { proxy in
            let rowHeight = bandWidth / CGFloat(Self.rows)
            // One repeat count for every ring. Letting each round its own would
            // drift them apart, and the diagonal would fan from 45° to square
            // and back again on the way round.
            let repeats = Self.repeatCount(
                for: Self.perimeter(of: proxy.size, inset: rowHeight / 2, radius: radius))
            ForEach(0..<Self.rows, id: \.self) { row in
                let inset = rowHeight * (CGFloat(row) + 0.5)
                let period = max(
                    0.02, Self.perimeter(of: proxy.size, inset: inset, radius: radius) / repeats)
                // A fraction of this ring's own period, never a fixed distance:
                // the rings differ in length, so only a relative offset holds one
                // lean the whole way around.
                let lean = (bandWidth / Self.nominalPeriod) * CGFloat(row) / CGFloat(Self.rows - 1)
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .inset(by: inset)
                    .stroke(
                        color,
                        style: StrokeStyle(
                            // Overdrawn past the row height so neighbours meet
                            // without a hairline of field showing between them.
                            lineWidth: rowHeight * 2.4,
                            dash: [period / 2, period / 2],
                            dashPhase: -period * lean))
            }
        }
    }

    private static func perimeter(of size: CGSize, inset: CGFloat, radius: CGFloat) -> CGFloat {
        let width = max(0, size.width - 2 * inset)
        let height = max(0, size.height - 2 * inset)
        let cornerRadius = max(0, min(radius - inset, min(width, height) / 2))
        return 2 * (width - 2 * cornerRadius) + 2 * (height - 2 * cornerRadius) + 2 * .pi * cornerRadius
    }

    // A whole number of repeats, so every ring's pattern meets itself cleanly.
    private static func repeatCount(for perimeter: CGFloat) -> CGFloat {
        guard perimeter > 0 else { return 1 }
        return max(1, (perimeter / nominalPeriod).rounded())
    }
}

// Both halves of a run share one break profile, so at rest they tile back with
// no seam. Deterministic, never random: re-rolling each layout pass would crawl
// during a resize. The long excursions leave a frayed strand on each half.
private struct TornTapeHalf: Shape {
    enum Run {
        case leading
        case trailing
    }
    enum End {
        case top
        case bottom
    }

    let run: Run
    let end: End
    let breakY: CGFloat
    let cornerInset: CGFloat
    let thickness: CGFloat

    private static let profile: [CGFloat] = [0.5, -2, 1.5, 8, -0.5, 2.5, -7.5, -1, 3.5, -3, 1.5, 0]

    func path(in rect: CGRect) -> Path {
        let steps = Self.profile.count - 1
        let outerX = run == .leading ? rect.minX : rect.maxX
        let innerX = run == .leading ? rect.minX + thickness : rect.maxX - thickness
        let stuckY = end == .top ? rect.minY + cornerInset : rect.maxY - cornerInset
        var path = Path()
        path.move(to: CGPoint(x: outerX, y: stuckY))
        for index in 0...steps {
            // The trailing run walks the profile backwards, so the two tears
            // fray differently instead of mirroring each other.
            let offset = run == .leading ? Self.profile[index] : Self.profile[steps - index]
            path.addLine(
                to: CGPoint(
                    x: outerX + (innerX - outerX) * CGFloat(index) / CGFloat(steps),
                    y: breakY + offset))
        }
        path.addLine(to: CGPoint(x: innerX, y: stuckY))
        path.closeSubpath()
        return path
    }
}

#Preview("Full — idle") {
    DropZoneView(isTargeted: false, compact: false) {}
        .frame(width: 520, height: 380)
}

#Preview("Full — targeted") {
    DropZoneView(isTargeted: true, compact: false) {}
        .frame(width: 520, height: 380)
}

#Preview("Compact — idle") {
    DropZoneView(isTargeted: false, compact: true) {}
}

#Preview("Compact — targeted") {
    DropZoneView(isTargeted: true, compact: true) {}
}
