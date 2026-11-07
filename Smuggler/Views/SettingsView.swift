//
//  SettingsView.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import SwiftUI

struct SettingsView: View {
    @Bindable var updater: UpdaterController

    var body: some View {
        Form {
            Toggle(
                String(
                    localized: "Automatically check for updates",
                    comment: "Settings toggle: let the app look for new versions on its own"),
                isOn: $updater.automaticallyChecksForUpdates)

            Toggle(
                String(
                    localized: "Automatically download and install updates",
                    comment: "Settings toggle: install new versions without asking first"),
                isOn: $updater.automaticallyDownloadsUpdates
            )
            // Sparkle ignores this choice, and reads it as off, while checks are manual.
            .disabled(!updater.automaticallyChecksForUpdates)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        // A grouped form scrolls, so it would stretch the window far past its two rows.
        .fixedSize(horizontal: false, vertical: true)
    }
}
