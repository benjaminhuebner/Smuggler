import SwiftUI

// MARK: - Shared Drop Vocabulary

// Both surfaces that accept a drop — this zone and the compact strip over the
// results — say the same thing at the same moment, on screen and to VoiceOver.
// One definition, so no copy of it can drift.
enum DropAffordance {
    static let targeted = String(
        localized: "Release to free from quarantine",
        comment: "Drop zone status while a drag hovers over it")

    static let chooseFiles = String(
        localized: "Choose Files…", comment: "Button: open the file picker")

    // The surface's name alone: its sentence is a child the reader reaches next,
    // and a label repeating it would be spoken twice.
    static let region = String(
        localized: "Drop zone", comment: "Accessibility label: the area that accepts dropped files")
}

// MARK: - DropZoneView

struct DropZoneView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let idleHeadline = String(
        localized: "Drop files to remove quarantine",
        comment: "Full drop zone: main heading in idle state")

    private static let idleSubtext = String(
        localized: "Drag files or folders here, or choose them manually",
        comment: "Full drop zone: subtext in idle state")

    let contact: DropContact
    let onChooseFiles: () -> Void

    // Held through the landing: the zone is on its way out by then, and
    // dropping back to its idle look first would flash the button.
    private var isTargeted: Bool { contact.phase != .none }

    var body: some View {
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
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(isTargeted ? DropAffordance.targeted : Self.idleHeadline)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)

                if !isTargeted {
                    Text(Self.idleSubtext)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            if !isTargeted {
                Button {
                    onChooseFiles()
                } label: {
                    // Pure black rather than the style's own label colour, which
                    // would flip to white in Dark Mode and vanish on the yellow.
                    Text(DropAffordance.chooseFiles)
                        .foregroundStyle(Color.smugglerOnYellow)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.smugglerYellow)
                .controlSize(.large)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        // On the whole stack, so the button's exit plays and the re-centring glides,
        // and under Reduce Motion all of it cuts. Before the background, which keeps
        // the tape out of this transaction.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isTargeted)
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            TapeFrame(contact: contact)
                .padding(20)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(DropAffordance.region)
    }
}

#Preview("Idle") {
    DropZoneView(contact: DropContact()) {}
        .frame(width: 520, height: 380)
        .coordinateSpace(.named(DropContact.surface))
}

#Preview("Targeted") {
    let contact = DropContact()
    DropZoneView(contact: contact) {}
        .frame(width: 520, height: 380)
        .coordinateSpace(.named(DropContact.surface))
        .task { contact.hover(at: CGPoint(x: 90, y: 200)) }
}
