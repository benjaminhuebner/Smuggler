//
//  DropZoneView.swift
//  Unquarantine
//
//  Created by Benjamin Hübner on 21.03.26.
//

import SwiftUI

struct DropZoneView: View {
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
                .foregroundStyle(isTargeted ? Color("UnquarantineYellow") : Color.secondary.opacity(0.6))
                .font(.title3)
                .contentTransition(.symbolEffect(.replace))

            Text(isTargeted ? "Release to free from quarantine" : "Drop more files here")
                .font(.subheadline)
                .foregroundStyle(isTargeted ? .primary : .secondary)
                .lineLimit(1)

            Spacer()

            if !isTargeted {
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
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isTargeted ? "Release to free from quarantine" : "Drop zone. Drop more files here.")
    }

    // MARK: - Full (empty state)

    private var fullView: some View {
        VStack(spacing: 28) {
            // Icon area
            Image(systemName: isTargeted ? "lock.open.fill" : "arrow.down.doc")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(
                    isTargeted
                        ? AnyShapeStyle(Color("UnquarantineYellow"))
                        : AnyShapeStyle(.secondary)
                )
                .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp.byLayer)))
                .symbolEffect(.bounce, value: isTargeted)
                .frame(height: 64)
                .animation(.spring(duration: 0.4, bounce: 0.3), value: isTargeted)

            // Text area
            VStack(spacing: 8) {
                Text(isTargeted ? "Release to free from quarantine" : "Drop files to remove quarantine")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .contentTransition(.numericText())

                if !isTargeted {
                    Text("Drag files or folders here, or choose them manually")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isTargeted)

            // Button
            if !isTargeted {
                Button {
                    onChooseFiles()
                } label: {
                    Label("Choose Files…", systemImage: "folder")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.black)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("UnquarantineYellow"))
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
            isTargeted ? "Release to remove quarantine" : "Drop zone. Drag files or folders to remove quarantine.")
    }

    // MARK: - Background

    private var dropZoneBackground: some View {
        ZStack {
            // Dashed border — normal state
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    Color.secondary.opacity(0.2),
                    style: StrokeStyle(lineWidth: 1.5, dash: [8, 5])
                )
                .opacity(isTargeted ? 0 : 1)

            // Solid border + fill — targeted state
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color("UnquarantineYellow").opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color("UnquarantineYellow").opacity(0.4), lineWidth: 1.5)
                )
                .opacity(isTargeted ? 1 : 0)
        }
        .animation(.easeInOut(duration: 0.2), value: isTargeted)
        .padding(20)
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
