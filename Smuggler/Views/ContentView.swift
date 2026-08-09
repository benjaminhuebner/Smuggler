import AppKit
import SwiftUI

struct ContentView: View {
    let appModel: AppModel
    @State private var isDropTargeted = false
    @State private var finishingFillRowCount = 0

    private var isServiceMode: Bool { appModel.serviceMode != nil }

    // Real completion leads the bars' finishing fill; a status bar keyed on it
    // alone would announce success while a row is still sprinting to full.
    private var showsAsProcessing: Bool {
        appModel.isProcessing || finishingFillRowCount > 0
    }

    var body: some View {
        Group {
            if isServiceMode {
                serviceView
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minWidth: 320)
            } else {
                normalView
            }
        }
        .onPreferenceChange(FinishingFillCountKey.self) { finishingFillRowCount = $0 }
    }

    // MARK: - Normal Mode

    private var normalView: some View {
        Group {
            if appModel.items.isEmpty {
                DropZoneView(isTargeted: isDropTargeted, compact: false) {
                    openPanel()
                }
            } else {
                resultsView
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .dropDestination(for: URL.self) { urls, _ in
            let fileURLs = urls.filter(\.isFileURL)
            guard !fileURLs.isEmpty else { return false }
            Task { await appModel.process(urls: fileURLs) }
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .animation(.easeInOut(duration: 0.25), value: appModel.items.isEmpty)
        .focusedSceneValue(\.openFiles, FileMenuAction { openFilePanel() })
        .focusedSceneValue(\.openFolder, FileMenuAction { openFolderPanel() })
    }

    private var resultsView: some View {
        VStack(spacing: 0) {
            DropZoneView(isTargeted: isDropTargeted, compact: true) {
                openPanel()
            }

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(appModel.items) { item in
                        FileRowView(item: item) {
                            appModel.cancel(id: item.id)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .scrollEdgeEffectStyle(.hard, for: .top)
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .tint(Color.smugglerYellow)
            .safeAreaInset(edge: .bottom) {
                statusBar
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            statusText
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if !appModel.items.isEmpty {
                // Keyed on real work, not on the lagging fill: offering Cancel All
                // once every task is gone would be a button that cancels nothing.
                if appModel.isProcessing {
                    cancelAllButton
                } else {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            appModel.clear()
                        }
                    } label: {
                        ViewThatFits(in: .horizontal) {
                            Label("Clear All", systemImage: "trash")
                                .font(.caption)
                            Image(systemName: "trash")
                                .font(.caption)
                                .accessibilityLabel(
                                    String(
                                        localized: "Clear All",
                                        comment: "Button: remove all items from the list"))
                        }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove all items from the list")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var cancelAllButton: some View {
        Button {
            appModel.cancelAll()
        } label: {
            ViewThatFits(in: .horizontal) {
                Label("Cancel All", systemImage: "xmark.circle")
                    .font(.caption)
                Image(systemName: "xmark.circle")
                    .font(.caption)
                    .accessibilityLabel(
                        String(localized: "Cancel All", comment: "Button: cancel all in-flight items"))
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Cancel all in-flight items")
    }

    @ViewBuilder
    private var statusText: some View {
        if showsAsProcessing {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .fixedSize()
                Text("Processing…")
                    .lineLimit(1)
            }
        } else if appModel.allCancelled {
            Text("All items cancelled")
        } else if appModel.cleanedCount == 0, appModel.failedCount > 0 {
            // Colored icon + primary text instead of colored text, which would
            // fall short of WCAG AA contrast on the bar background.
            Label {
                Text("No items could be freed").foregroundStyle(.primary)
            } icon: {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            }
        } else if appModel.cleanedCount == 0 {
            Text("No items could be freed")
        } else if appModel.failedCount > 0 {
            Label {
                Text("\(appModel.cleanedCount) freed, \(appModel.failedCount) failed")
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        } else {
            Label {
                Text(
                    appModel.cleanedCount == 1
                        ? "1 item freed"
                        : "\(appModel.cleanedCount) items freed"
                )
                .foregroundStyle(.primary)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }

    // MARK: - Service Mode (Finder Extension / Services Menu)

    // The service window is content-sized and unscrollable, and a Finder
    // selection is unbounded — without a cap it can outgrow the screen.
    private static let serviceRowLimit = 8

    private var serviceView: some View {
        let (shownItems, hiddenCount) = appModel.items.cappedPrefix(Self.serviceRowLimit)
        let lastItemID = shownItems.last?.id
        return VStack(spacing: 0) {
            ForEach(shownItems) { item in
                FileRowView(item: item, style: .compact) {
                    appModel.cancel(id: item.id)
                }
                if item.id != lastItemID {
                    Divider().padding(.leading, 44)
                }
            }
            if hiddenCount > 0 {
                Divider().padding(.leading, 44)
                Text(
                    hiddenCount == 1
                        ? String(
                            localized: "and 1 more item",
                            comment: "Service window: summary row when one item is hidden by the row cap")
                        : String(
                            localized: "and \(hiddenCount) more items",
                            comment: "Service window: summary row when several items are hidden by the row cap")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 44)
                .padding(.trailing, 12)
                .padding(.vertical, 8)
            }
            if showsAsProcessing {
                // Rows past the cap have no visible cancel control; the
                // batch-level cancel keeps a wedged hidden item cancellable.
                // Held through the finishing fill so this content-sized window
                // doesn't shrink out from under rows that still read as working.
                Divider().padding(.leading, 44)
                HStack {
                    Spacer()
                    cancelAllButton
                        .disabled(!appModel.isProcessing)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - File Panel

    private func openPanel() {
        runOpenPanel(
            canChooseFiles: true, canChooseDirectories: true,
            message: String(
                localized: "Choose files or folders to free from quarantine",
                comment: "NSOpenPanel message for files and folders"))
    }

    private func openFilePanel() {
        runOpenPanel(
            canChooseFiles: true, canChooseDirectories: false,
            message: String(
                localized: "Choose files to free from quarantine",
                comment: "NSOpenPanel message for files only"))
    }

    private func openFolderPanel() {
        runOpenPanel(
            canChooseFiles: false, canChooseDirectories: true,
            message: String(
                localized: "Choose folders to free from quarantine",
                comment: "NSOpenPanel message for folders only"))
    }

    private func runOpenPanel(canChooseFiles: Bool, canChooseDirectories: Bool, message: String) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = canChooseFiles
        panel.canChooseDirectories = canChooseDirectories
        panel.message = message
        panel.prompt = String(localized: "Remove Quarantine", comment: "NSOpenPanel confirm button")
        guard panel.runModal() == .OK else { return }
        Task { await appModel.process(urls: panel.urls) }
    }
}

#Preview {
    ContentView(appModel: AppModel())
}

#Preview("Service Mode") {
    // Stub handlers and nonexistent paths: the default handlers would walk real
    // bundles, post notifications, and terminate the preview host.
    let model = AppModel(
        confirm: { _, _ in true },
        open: { _ in },
        terminate: {},
        authorize: {},
        notify: { _ in }
    )
    ContentView(appModel: model)
        .onAppear {
            let urls = [
                URL(filePath: "/tmp/smuggler-preview/Sample.app"),
                URL(filePath: "/tmp/smuggler-preview/download.zip"),
            ]
            model.handleServiceURLs(urls, action: .remove, quitAfter: true)
        }
        .frame(width: 380)
}
