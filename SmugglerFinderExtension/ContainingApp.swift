//
//  ContainingApp.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import AppKit

// Launch Services hands a custom scheme to whichever bundle it prefers, stale
// copies and foreign apps included; the token may reach only the app this
// extension ships in, which holds it at Contents/PlugIns/<extension>.appex.
enum ContainingApp {
    static func url(containing extensionURL: URL) -> URL {
        extensionURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func openConfiguration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        // Left on, it swaps even an explicitly named app for a running copy at
        // another path; a running instance of this very app is still reused.
        configuration.allowsRunningApplicationSubstitution = false
        return configuration
    }
}
