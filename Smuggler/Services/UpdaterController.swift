import Foundation
import Observation
import Sparkle

// The single home for the Sparkle SDK in this codebase — keep all Sparkle
// imports and types behind this wall.
@MainActor
@Observable
final class UpdaterController {
    private(set) var canCheckForUpdates = false

    // Written through only when a person changes it: Sparkle asks for permission
    // while the choice is still unset, and echoing its own value back would answer that.
    var automaticallyChecksForUpdates = false {
        didSet {
            guard automaticallyChecksForUpdates != controller.updater.automaticallyChecksForUpdates else { return }
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    var automaticallyDownloadsUpdates = false {
        didSet {
            guard automaticallyDownloadsUpdates != controller.updater.automaticallyDownloadsUpdates else { return }
            controller.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
        }
    }

    private let controller: SPUStandardUpdaterController
    private var observations: [NSKeyValueObservation] = []

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        let updater = controller.updater
        canCheckForUpdates = updater.canCheckForUpdates
        syncSettings()
        // Mirror Sparkle's KVO flag into observable storage so the menu item
        // tracks an in-progress check. Hop to the main actor via the Sendable
        // Bool from the change dict — safe even if Sparkle fires off-main.
        observations.append(
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
                guard let newValue = change.newValue else { return }
                Task { @MainActor in
                    self?.canCheckForUpdates = newValue
                }
            })
        // Sparkle changes these on its own: its permission prompt, the update alert,
        // downloads switching off with checks. Synced from the live value, so a late
        // echo of a quick toggle can't carry a stale one back into Sparkle.
        for setting in [\SPUUpdater.automaticallyChecksForUpdates, \.automaticallyDownloadsUpdates] {
            observations.append(
                updater.observe(setting) { [weak self] _, _ in
                    Task { @MainActor in
                        self?.syncSettings()
                    }
                })
        }
    }

    func start() {
        controller.startUpdater()
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    private func syncSettings() {
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = controller.updater.automaticallyDownloadsUpdates
    }
}
