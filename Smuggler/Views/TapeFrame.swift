//
//  TapeFrame.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 11.08.26.
//

import AppKit
import SwiftUI

// The barrier the North Star names, as a standalone surface: a hatched band
// that gives way where the load pushes through it. Shared by the empty state
// and the drag overlay so the motif reads the same wherever a drop can land.
struct TapeFrame: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let contact: DropContact

    // How far the band reaches inward from the frame's bounds. Callers that must
    // keep it off their content derive their gutter from it.
    static let tapeWidth = TapeMetrics.bandWidth

    @State private var motion = TapeMotion()
    @State private var isAnimating = false
    @State private var surfaceFrame = CGRect.zero

    private var now: TimeInterval { Date.now.timeIntervalSinceReferenceDate }

    private var lane: TapeLane {
        TapeLane(rect: CGRect(origin: .zero, size: surfaceFrame.size))
    }

    private var pointer: CGPoint? {
        contact.location.map { CGPoint(x: $0.x - surfaceFrame.minX, y: $0.y - surfaceFrame.minY) }
    }

    var body: some View {
        TapeCanvas(motion: motion, isAnimating: isAnimating)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(DropContact.surface))
            } action: { frame in
                surfaceFrame = frame
            }
            .onChange(of: reduceMotion, initial: true) {
                motion.reducesMotion = reduceMotion
            }
            .onChange(of: contact.phase, initial: true) {
                respond(to: contact.phase)
            }
            .onChange(of: contact.location) {
                track()
            }
            .onChange(of: surfaceFrame.size) {
                track()
            }
            .task(id: isAnimating) {
                guard isAnimating else { return }
                while !Task.isCancelled {
                    let remaining = motion.settleDeadline - now
                    guard remaining > 0 else {
                        isAnimating = false
                        return
                    }
                    try? await Task.sleep(for: .seconds(remaining))
                }
            }
    }

    private func respond(to phase: DropContact.Phase) {
        switch phase {
        case .hovering:
            // Mounted mid-drag it still arrives sealed and gives way in front
            // of the pointer, instead of popping in already torn.
            motion.begin(at: now)
            track()
        case .landed:
            guard !surfaceFrame.isEmpty else { return }
            if motion.land(on: lane, near: pointer, at: now) { snapped() }
        case .none:
            motion.end(at: now)
        }
        wake()
    }

    private func track() {
        guard contact.phase == .hovering, let pointer, !surfaceFrame.isEmpty else { return }
        if motion.track(pointer, on: lane, at: now) { snapped() }
        wake()
    }

    // On a Force Touch trackpad the snap is felt, not only seen — the tick
    // macOS gives when a drag lands on a guide.
    private func snapped() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    private func wake() {
        guard !isAnimating, motion.settleDeadline > now else { return }
        isAnimating = true
    }
}

// A view of its own, so a pointer update that reruns the frame's body leaves the
// drawing alone: these inputs compare equal, and only the timeline redraws it.
private struct TapeCanvas: View {
    @Environment(\.colorSchemeContrast) private var contrast

    let motion: TapeMotion
    let isAnimating: Bool

    var body: some View {
        // The display asks for frames only while something moves; at rest the
        // tape is one static drawing.
        TimelineView(.animation(paused: !isAnimating)) { timeline in
            Canvas { context, size in
                let lane = TapeLane(rect: CGRect(origin: .zero, size: size))
                let pose = motion.pose(at: timeline.date.timeIntervalSinceReferenceDate, on: lane)
                TapeRenderer(pose: pose, lane: lane, contrast: contrast).draw(in: &context)
            }
        }
    }
}

#Preview("Sealed") {
    TapeFrame(contact: DropContact())
        .padding(20)
        .frame(width: 520, height: 380)
        .coordinateSpace(.named(DropContact.surface))
}

#Preview("Torn") {
    let contact = DropContact()
    TapeFrame(contact: contact)
        .padding(20)
        .frame(width: 520, height: 380)
        .coordinateSpace(.named(DropContact.surface))
        .task {
            contact.hover(at: CGPoint(x: 8, y: 150))
            try? await Task.sleep(for: .milliseconds(300))
            contact.hover(at: CGPoint(x: 60, y: 170))
        }
}
