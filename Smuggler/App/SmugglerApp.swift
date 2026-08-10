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
                    guard let request = IncomingRequest(url: url) else {
                        appDelegate.appModel.rejectIncomingRequest(url, isColdLaunch: isColdLaunch)
                        return
                    }
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

                Divider()

                // Views, not inline buttons: observation registers through a view
                // body, and a command reading the model directly keeps whatever
                // enablement it was built with.
                CancelAllButton(appModel: appDelegate.appModel)
                ClearAllButton(appModel: appDelegate.appModel)
            }
        }
    }
}

// MARK: - File Menu Commands

private struct CancelAllButton: View {
    let appModel: AppModel

    var body: some View {
        Button("Cancel All") {
            appModel.cancelAll()
        }
        .keyboardShortcut(".", modifiers: .command)
        .disabled(!appModel.isProcessing)
    }
}

private struct ClearAllButton: View {
    let appModel: AppModel

    var body: some View {
        Button("Clear All") {
            appModel.clear()
        }
        .keyboardShortcut(.delete, modifiers: .command)
        // Withheld in service mode: clearing cancels the coordinator, and the
        // session Finder launched would then never reach its quit.
        .disabled(appModel.items.isEmpty || appModel.isProcessing || appModel.serviceMode != nil)
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
