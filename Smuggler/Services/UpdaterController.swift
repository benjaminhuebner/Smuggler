import Foundation
import Observation
import Sparkle

// The single home for the Sparkle SDK in this codebase — keep all Sparkle
// imports and types behind this wall.
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
        // Mirror Sparkle's KVO flag into observable storage so the menu item
        // tracks an in-progress check. Hop to the main actor via the Sendable
        // Bool from the change dict — safe even if Sparkle fires off-main.
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
