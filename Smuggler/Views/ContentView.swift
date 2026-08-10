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
        // The result lives in the bar, last in traversal order, so a VoiceOver user
        // would otherwise never learn it. Keyed on the text, not on completion: a
        // batch refused outright finishes without anything having processed.
        .task(id: announcement) {
            // Outlasts the pass in which the fill count still trails real
            // completion, which would otherwise speak the result twice.
            guard announcement.isSettled else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            AccessibilityNotification.Announcement(announcement.text).post()
        }
    }

    private struct StatusAnnouncement: Equatable {
        var text: String
        var isSettled: Bool
    }

    private var announcement: StatusAnnouncement {
        StatusAnnouncement(
            text: statusPresentation.text,
            isSettled: !showsAsProcessing && !appModel.items.isEmpty)
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
                .font(.subheadline)
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

    private struct StatusPresentation {
        var text: String
        // Paired, never half-set: a symbol without its tint would drop the icon
        // silently instead of failing.
        var icon: (symbol: String, tint: Color)?
    }

    // Resolved once so the visible bar and the spoken announcement cannot drift.
    private var statusPresentation: StatusPresentation {
        if showsAsProcessing {
            return StatusPresentation(
                text: String(localized: "Processing…", comment: "File row status: currently processing"))
        }
        if appModel.allCancelled {
            return StatusPresentation(
                text: String(localized: "All items cancelled", comment: "Status bar: every item was cancelled"))
        }
        // Counted once per pass: each of these is a full scan of the item list,
        // which a Finder selection can push into the thousands.
        let freed = appModel.freedCount
        let failed = appModel.failedCount
        let alreadyFree = appModel.alreadyFreeCount
        if freed == 0, failed > 0 {
            // The already-free rows are named even here: a red "nothing succeeded"
            // over a list of usable files contradicts the rows it summarizes.
            if alreadyFree > 0 {
                return StatusPresentation(
                    text: String(
                        localized: "\(alreadyFree) already free, \(failed) failed",
                        comment: "Status bar: nothing freed, some had no quarantine, some failed"),
                    icon: ("exclamationmark.triangle.fill", .orange))
            }
            return StatusPresentation(
                text: String(localized: "No items could be freed", comment: "Status bar: nothing succeeded"),
                icon: ("exclamationmark.circle.fill", .red))
        }
        if freed == 0 {
            return StatusPresentation(
                text: String(
                    localized: "Nothing needed freeing",
                    comment: "Status bar: nothing had quarantine to remove"))
        }
        if failed > 0 {
            return StatusPresentation(
                text: String(
                    localized: "\(freed) freed, \(failed) failed",
                    comment: "Status bar: mixed result"),
                icon: ("exclamationmark.triangle.fill", .orange))
        }
        if alreadyFree > 0 {
            return StatusPresentation(
                text: String(
                    localized: "\(freed) freed, \(alreadyFree) already free",
                    comment: "Status bar: some freed, some had no quarantine"),
                icon: ("checkmark.circle.fill", .green))
        }
        return StatusPresentation(
            text: freed == 1
                ? String(localized: "1 item freed", comment: "Status bar: exactly one item freed")
                : String(
                    localized: "\(freed) items freed",
                    comment: "Status bar: several items freed"),
            icon: ("checkmark.circle.fill", .green))
    }

    @ViewBuilder
    private var statusText: some View {
        let presentation = statusPresentation
        if showsAsProcessing {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .fixedSize()
                Text(presentation.text)
                    .lineLimit(1)
            }
        } else if let icon = presentation.icon {
            // Colored icon + primary text instead of colored text, which would
            // fall short of WCAG AA contrast on the bar background.
            Label {
                Text(presentation.text).foregroundStyle(.primary)
            } icon: {
                Image(systemName: icon.symbol).foregroundStyle(icon.tint)
            }
        } else {
            Text(presentation.text)
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
                    Divider().padding(.leading, FileRowView.compactTextInset)
                }
            }
            if hiddenCount > 0 {
                Divider().padding(.leading, FileRowView.compactTextInset)
                Text(hiddenItemsLabel(hiddenCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, FileRowView.compactTextInset)
                    .padding(.trailing, 12)
                    .padding(.vertical, 8)
            }
            if showsAsProcessing {
                // Rows past the cap have no visible cancel control; the
                // batch-level cancel keeps a wedged hidden item cancellable.
                // Held through the finishing fill so this content-sized window
                // doesn't shrink out from under rows that still read as working.
                Divider().padding(.leading, FileRowView.compactTextInset)
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
