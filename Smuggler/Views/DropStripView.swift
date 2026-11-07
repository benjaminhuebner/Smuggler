//
//  DropStripView.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 11.08.26.
//

import SwiftUI

// The drop affordance once results own the window: one line of chrome above the
// list, carrying the same invitation the empty state makes at full size.
struct DropStripView: View {
    let isTargeted: Bool
    let onChooseFiles: () -> Void

    private static let idleHint = String(
        localized: "Drop more files here", comment: "Compact drop zone: idle state hint")

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: isTargeted ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(isTargeted ? Color.smugglerYellow : Color.secondary)
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)

                Text(isTargeted ? DropAffordance.targeted : Self.idleHint)
                    .font(.subheadline)
                    .foregroundStyle(isTargeted ? .primary : .secondary)
                    .lineLimit(1)

                Spacer()

                // Hidden rather than removed: dropping it from the layout shortens the
                // strip mid-drag and shifts the list the person is aiming at.
                ViewThatFits(in: .horizontal) {
                    Button(DropAffordance.chooseFiles) {
                        onChooseFiles()
                    }

                    Button {
                        onChooseFiles()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(DropAffordance.chooseFiles)
                    // Only the icon-only fallback needs one — on the wide variant it
                    // would pop a tooltip repeating the button's own label.
                    .help(DropAffordance.chooseFiles)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .opacity(isTargeted ? 0 : 1)
                .disabled(isTargeted)
                .accessibilityHidden(isTargeted)
            }
            .padding(.horizontal, FileRowView.listHorizontalPadding)
            .padding(.vertical, 10)

            // The material alone is within a percent of the list below it in Light
            // Mode; the line is what makes the strip read as chrome at all.
            Divider()
        }
        .background(.bar)
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
        // .contain (not .combine) so the "Choose Files…" button stays reachable.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(DropAffordance.region)
    }
}

#Preview("Idle") {
    DropStripView(isTargeted: false) {}
        .frame(width: 520)
}

#Preview("Targeted") {
    DropStripView(isTargeted: true) {}
        .frame(width: 520)
}
