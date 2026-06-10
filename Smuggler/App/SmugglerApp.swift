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
struct SmugglerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @FocusedValue(\.openFiles) private var openFiles
    @FocusedValue(\.openFolder) private var openFolder

    var body: some Scene {
        Window("Smuggler", id: "main") {
            ContentView(appModel: appDelegate.appModel)
                .onOpenURL { url in
                    let isColdLaunch = appDelegate.consumeColdLaunch()
                    guard let request = AppModel.parseIncomingURL(url) else { return }
                    if !isColdLaunch {
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    appDelegate.appModel.handleIncomingRequest(request, isColdLaunch: isColdLaunch)
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
                .keyboardShortcut("o", modifiers: [.shift, .command])
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
