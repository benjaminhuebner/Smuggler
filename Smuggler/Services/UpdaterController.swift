//
//  UpdaterController.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 07.06.26.
//

import Foundation
import Observation
import Sparkle

// The single home for the Sparkle SDK in this codebase (one-home-per-vendor-SDK
// invariant). Wraps the standard updater controller and mirrors its
// `canCheckForUpdates` flag into observable state.
@MainActor
@Observable
final class UpdaterController {
    private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController
    private var observation: NSKeyValueObservation?

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        let updater = controller.updater
        canCheckForUpdates = updater.canCheckForUpdates
        // Mirror Sparkle's KVO flag into observable storage so the menu item's
        // enabled state tracks an in-progress check. Hop to the main actor via
        // the Sendable Bool from the change dict rather than asserting isolation,
        // so this is safe even if Sparkle ever fires the KVO off the main thread.
        observation = updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            guard let newValue = change.newValue else { return }
            Task { @MainActor in
                self?.canCheckForUpdates = newValue
            }
        }
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
