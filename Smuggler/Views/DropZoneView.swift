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
    private static let topRunHeight = tapeWidth + 1

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

    // Sized to a real drop, which is quick: a slower tear is still mid-rip when
    // the file lands, and the tape then re-seals over the arriving results.
    // Re-sealing is the undo of an action nobody took, so it gets less time.
    private static func tearMotion(_ tearing: Bool) -> Animation {
        tearing
            ? .timingCurve(0.2, 0, 0.1, 1, duration: 0.26)
            : .timingCurve(0.3, 0, 0.2, 1, duration: 0.16)
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

    // A tear travels. The run splits at a moving front: behind it the tape is
    // already off and curling, ahead of it the tape is still stuck flat — which
    // is what separates a rip from a strip that simply slides away.
    private var dropZoneBackground: some View {
        let tear = TornEdge(depth: Self.topRunHeight)
        let torn: CGFloat = isTargeted ? 1 : 0
        return GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            // The hinge rides the tear front: the freed end is the one being held
            // up, and the tape touches back down exactly where it is still stuck.
            let hinge = UnitPoint(x: torn, y: min(1, Self.topRunHeight / max(1, proxy.size.height)))

            ZStack {
                bandShape
                    .fill(Color.smugglerYellow.opacity(0.05))
                    .opacity(isTargeted ? 1 : 0)

                tapeBand()
                    .mask {
                        Rectangle()
                            .overlay { tear.blendMode(.destinationOut) }
                            .compositingGroup()
                    }

                // Still stuck, ahead of the front.
                tapeBand()
                    .mask { tear }
                    .mask {
                        Rectangle()
                            .frame(width: width * (1 - torn))
                            .frame(width: width, alignment: .trailing)
                    }

                // Already torn free, hinged on the end the rip started from. The
                // only shadow in the interface, and not decoration: this strip is
                // genuinely off the surface while it lifts.
                tapeBand()
                    .mask { tear }
                    .mask {
                        Rectangle()
                            .frame(width: width * torn)
                            .frame(width: width, alignment: .leading)
                    }
                    .shadow(color: .black.opacity(0.45 * torn), radius: 9 * torn, y: 7 * torn)
                    .rotation3DEffect(
                        .degrees(-56 * torn),
                        axis: (x: 1, y: 0, z: 0),
                        anchor: hinge,
                        perspective: 0.6
                    )
                    .rotationEffect(.degrees(-6 * torn), anchor: hinge)
                    .opacity(1 - torn)
            }
        }
        .animation(reduceMotion ? nil : Self.tearMotion(isTargeted), value: isTargeted)
        .padding(20)
        .accessibilityHidden(true)
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

// Deterministic jitter, never random: a Shape re-rolling each layout pass would
// crawl during a resize. Never negative either — a tear swinging above the line
// strands slivers of band that read as debris instead of as a torn edge.
private struct TornEdge: Shape {
    let depth: CGFloat

    private static let jitter: [CGFloat] = [0, 2.5, 1, 3.5, 0.5, 2, 0, 2.5, 1.5, 3, 0.5, 2]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        let steps = Self.jitter.count - 1
        for index in stride(from: steps, through: 0, by: -1) {
            let fraction = CGFloat(index) / CGFloat(steps)
            path.addLine(
                to: CGPoint(
                    x: rect.minX + rect.width * fraction,
                    y: rect.minY + depth + Self.jitter[index]))
        }
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
