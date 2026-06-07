//
//  AppDelegate.swift
//  Unquarantine
//
//  Created by Benjamin Hübner on 21.03.26.
//

import AppKit
import os

private let logger = Logger(subsystem: "com.benjaminhuebner.Unquarantine", category: "App")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Shared model so both the window and the services/URL handler use the same state.
    let appModel = AppModel()

    // Owns the Sparkle updater for the app's lifetime. Starts itself; scheduled
    // background checks run per the user's first-run opt-in. In service mode the
    // session quits within ~1s and the menu command is unreachable, so no update
    // UI surfaces there.
    let updater = UpdaterController()

    /// Becomes `true` once the initial launch sequence is complete.
    /// Any URL received before this is a cold-launch URL (from extension).
    var isReady = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        // Set isReady on the next run loop tick — after any cold-launch
        // onOpenURL has already fired.
        Task { [weak self] in self?.isReady = true }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - NSServices handler

    @objc func removeQuarantine(
        _ pboard: NSPasteboard,
        userData: String,
        error errorPointer: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let urls = pboard.readObjects(forClasses: [NSURL.self]) as? [URL],
            !urls.isEmpty
        else {
            logger.warning("Services handler: no file paths on pasteboard")
            return
        }
        logger.info("Services handler: processing \(urls.count) item(s)")

        // Only use service mode (compact UI + auto-quit) on cold launch.
        // If the app is already open, just add items to the normal list.
        appModel.handleServiceURLs(urls, action: "remove", quitAfter: !isReady)
    }
}
