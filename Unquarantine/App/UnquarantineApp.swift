//
//  UnquarantineApp.swift
//  Unquarantine
//
//  Created by Benjamin Hübner on 21.03.26.
//

import SwiftUI

// MARK: - Focused Values for File Menu

struct FileMenuAction {
    let action: @MainActor () -> Void
    @MainActor func callAsFunction() { action() }
}

extension FocusedValues {
    @Entry var openFiles: FileMenuAction?
    @Entry var openFolder: FileMenuAction?
}

// MARK: - App

@main
struct UnquarantineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @FocusedValue(\.openFiles) private var openFiles
    @FocusedValue(\.openFolder) private var openFolder

    var body: some Scene {
        Window("Unquarantine", id: "main") {
            ContentView(appModel: appDelegate.appModel)
                .onOpenURL { url in
                    guard let request = AppModel.parseIncomingURL(url) else { return }
                    let validURLs = request.urls.filter {
                        FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
                    }
                    guard !validURLs.isEmpty else { return }
                    let useServiceMode = request.quitAfter && !appDelegate.isReady
                    appDelegate.appModel.handleServiceURLs(
                        validURLs,
                        action: request.action,
                        quitAfter: useServiceMode
                    )
                }
        }
        .defaultSize(width: 520, height: 380)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: appDelegate.updater)
            }

            CommandGroup(replacing: .newItem) {
                Button("Open File…") {
                    openFiles?()
                }
                .keyboardShortcut("o")

                Button("Open Folder…") {
                    openFolder?()
                }
                .keyboardShortcut("O", modifiers: [.shift, .command])
            }
        }
    }
}

// MARK: - Check for Updates Command

private struct CheckForUpdatesButton: View {
    let updater: UpdaterController

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
    }
}
