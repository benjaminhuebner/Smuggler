import SwiftUI

// MARK: - Focused Values for File Menu

struct FileMenuAction {
    let action: @MainActor () -> Void
    @MainActor func callAsFunction() { action() }
}

extension FocusedValues {
    @Entry var chooseFiles: FileMenuAction?
    @Entry var clearAll: FileMenuAction?
}

// MARK: - App

@main
struct SmugglerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.chooseFiles) private var chooseFiles
    @FocusedValue(\.clearAll) private var clearAll

    private static let aboutTitle = String(
        localized: "About Smuggler", comment: "App menu item and window title: the app's version and contact links")

    var body: some Scene {
        Window(String(localized: "Smuggler", comment: "Window title: the brand name, never translated"), id: "main") {
            ContentView(appModel: appDelegate.appModel)
                .onOpenURL(perform: appDelegate.handleIncomingURL)
                .onAppear { appDelegate.openMainWindow = { openWindow(id: "main") } }
        }
        .defaultSize(width: 520, height: 380)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(Self.aboutTitle) {
                    openWindow(id: "about")
                }
            }

            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: appDelegate.updater)
            }

            CommandGroup(replacing: .newItem) {
                Button(DropAffordance.chooseFiles) {
                    chooseFiles?()
                }
                .keyboardShortcut("o")
                .disabled(chooseFiles == nil)

                Divider()

                // Views, not inline buttons: observation registers through a view
                // body, and a command reading the model directly keeps whatever
                // enablement it was built with.
                CancelAllButton(appModel: appDelegate.appModel)
                ClearAllButton(appModel: appDelegate.appModel, clearAll: clearAll)
            }

            // Without a help book, the system's own item ends in "Help isn't available".
            CommandGroup(replacing: .help) {
                Link(
                    String(localized: "Smuggler Help", comment: "Help menu item: opens the app's guide on the web"),
                    destination: ProductLinks.guide)

                Divider()

                Link(
                    String(localized: "Smuggler Website", comment: "Help menu item: opens the app's website"),
                    destination: ProductLinks.website)
                Link(
                    String(
                        localized: "Support",
                        comment: "Help menu item and About window button: opens the support form on the app's website"),
                    destination: ProductLinks.support)
            }
        }

        Window(Self.aboutTitle, id: "about") {
            AboutView()
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .windowMinimizeBehavior(.disabled)
        }
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        Settings {
            SettingsView(updater: appDelegate.updater)
        }
        // A restored Settings window would open beside the compact window of a
        // session launched only to serve one Finder or Services request.
        .restorationBehavior(.disabled)
    }
}

// MARK: - File Menu Commands

private struct CancelAllButton: View {
    let appModel: AppModel

    var body: some View {
        Button(String(localized: "Cancel All", comment: "File menu item: cancel every item still being processed")) {
            appModel.cancelAll()
        }
        .keyboardShortcut(".", modifiers: .command)
        .disabled(!appModel.isProcessing)
    }
}

// Through the window, not `appModel.clear()`: from here the list would empty a
// frame before the window's switch to the drop zone begins.
private struct ClearAllButton: View {
    let appModel: AppModel
    let clearAll: FileMenuAction?

    var body: some View {
        Button(String(localized: "Clear All", comment: "File menu item: remove all items from the list")) {
            clearAll?()
        }
        .keyboardShortcut(.delete, modifiers: .command)
        // Withheld in service mode: clearing cancels the coordinator, and the
        // session Finder launched would then never reach its quit.
        .disabled(clearAll == nil || appModel.items.isEmpty || appModel.isProcessing || appModel.isServiceMode)
    }
}

// MARK: - Check for Updates Command

private struct CheckForUpdatesButton: View {
    let updater: UpdaterController

    var body: some View {
        Button(
            String(localized: "Check for Updates…", comment: "App menu item: look for a newer version of Smuggler")
        ) {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
    }
}
