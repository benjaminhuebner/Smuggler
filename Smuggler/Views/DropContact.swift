//
//  DropContact.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import SwiftUI

// A class of its own rather than view state: the stream of pointer positions
// then reaches the tape and nothing else in the window.
@Observable
final class DropContact {
    enum Phase {
        case none
        case hovering
        case landed
    }

    nonisolated static let surface = "dropSurface"

    private(set) var phase = Phase.none
    private(set) var location: CGPoint?

    // Observation notifies on every write, equal or not; unguarded, each pointer
    // update would re-render everything that only asks whether a drag is on.
    func hover(at location: CGPoint) {
        if phase != .hovering { phase = .hovering }
        if self.location != location { self.location = location }
    }

    func land() {
        if phase != .landed { phase = .landed }
    }

    func end() {
        if phase != .none { phase = .none }
        if location != nil { location = nil }
    }
}
