import AppKit
import SwiftUI

struct ContentView: View {
    let appModel: AppModel
    @State private var dropContact = DropContact()
    @State private var finishingFillRowCount = 0
    @State private var showsResults: Bool

    init(appModel: AppModel) {
        self.appModel = appModel
        _showsResults = State(initialValue: !appModel.items.isEmpty)
    }

    private static let resultsSwitch = Animation.easeInOut(duration: 0.25)

    private var isDropHovering: Bool { dropContact.phase == .hovering }

    // Real completion leads the bars' finishing fill; a status bar keyed on it
    // alone would announce success while a row is still sprinting to full.
    private var showsAsProcessing: Bool {
        appModel.isProcessing || finishingFillRowCount > 0
    }

    var body: some View {
        Group {
            if appModel.isServiceMode {
                serviceView
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minWidth: 320)
            } else {
                normalView
            }
        }
        .onPreferenceChange(FinishingFillCountKey.self) { finishingFillRowCount = $0 }
        // View state under withAnimation: an implicit animation on the model value never
        // ran for a drop. Watched above the service switch, because a headless batch
        // fills the list while the normal view is unmounted and the hand-back needs it.
        .onChange(of: appModel.items.isEmpty) { _, isEmpty in
            withAnimation(Self.resultsSwitch) {
                showsResults = !isEmpty
            }
        }
        // The result lives in the bar, last in traversal order, so a VoiceOver user
        // would otherwise never learn it. Keyed on the summary, not on completion: a
        // batch refused outright finishes without anything having processed.
        .task(id: statusSummary) {
            // Outlasts the pass in which the fill count still trails real
            // completion, which would otherwise speak the result twice.
            guard let summary = statusSummary, summary.isSettled else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            AccessibilityNotification.Announcement(summary.text).post()
        }
    }

    // One value for the bar and the announcement, so the two cannot drift.
    private var statusSummary: StatusSummary? {
        StatusSummary(
            items: appModel.items, showsAsProcessing: showsAsProcessing, runProgress: appModel.runProgress)
    }

    // MARK: - Normal Mode

    private var normalView: some View {
        Group {
            if showsResults {
                resultsView
            } else {
                DropZoneView(contact: dropContact) {
                    openPanel()
                }
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .coordinateSpace(.named(DropContact.surface))
        .dropDestination(for: DroppedFile.self) { files, _ in
            guard !files.isEmpty else {
                dropContact.end()
                return false
            }
            dropContact.land()
            Task { await appModel.process(urls: files.map(\.url)) }
            return true
        }
        // The session, not `isTargeted`, drives the tape: it carries where the
        // load is, and it tells a drop from a drag that left — `isTargeted`
        // reports both as a plain false, just before the drop arrives.
        .onDropSessionUpdated { session in
            switch session.phase {
            case .entering, .active:
                dropContact.hover(at: session.location)
            case .exiting, .ended:
                dropContact.end()
            case .dataTransferCompleted:
                break
            @unknown default:
                break
            }
        }
        .focusedSceneValue(\.chooseFiles, FileMenuAction { openPanel() })
        .focusedSceneValue(\.clearAll, FileMenuAction { clearAll() })
    }

    private var resultsView: some View {
        VStack(spacing: 0) {
            DropStripView(isTargeted: isDropHovering) {
                openPanel()
            }

            ScrollView {
                // Alternating bands rather than gapped rows: the list is a result
                // table, and the system's own two-tone backing is what makes it
                // scannable without drawing a border around anything.
                LazyVStack(spacing: 0) {
                    // Enumerated in place, not through an Array: this body reruns on
                    // every finished file, and a drop can carry thousands.
                    ForEach(appModel.items.enumerated(), id: \.element.id) { index, item in
                        FileRowView(item: item, isAlternateRow: !index.isMultiple(of: 2)) {
                            appModel.cancel(id: item.id)
                        }
                    }
                }
            }
            // The band reaches this far inward from the list's edges, and the rows
            // run edge to edge — without a matching gutter it lands on the first
            // and last of them.
            .contentMargins(.vertical, TapeFrame.tapeWidth, for: .scrollContent)
            // Bottom only. The drop strip is a sibling above this view, not a bar
            // inside its safe area, so a top edge effect has nothing to fade
            // content under — it just washes over the first row during a drag.
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .scrollBounceBehavior(.basedOnSize)
            .tint(Color.smugglerYellow)
            // The tape belongs to this state too. Framed before the status strip is
            // inset, or it swallows the summary.
            .overlay {
                // Mounted only for the drag, so a resting list carries no tape and
                // the band arrives sealed, giving way in front of the pointer.
                if isDropHovering {
                    TapeFrame(contact: dropContact)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isDropHovering)
            .safeAreaInset(edge: .bottom) {
                statusBar
            }
        }
    }

    private var statusBar: some View {
        VStack(spacing: 0) {
            // The bar material alone is within a percent of the content behind
            // it in Light Mode, so the strip needs a real line to sit on.
            Divider()

            HStack(spacing: 12) {
                statusText
                    .font(.subheadline)
                    .lineLimit(1)

                Spacer()

                if !appModel.items.isEmpty {
                    // Keyed on real work, not on the lagging fill: offering Cancel All
                    // once every task is gone would be a button that cancels nothing.
                    if appModel.isProcessing {
                        cancelAllButton
                    } else {
                        BarButton(
                            title: String(
                                localized: "Clear All", comment: "Status bar button: remove all items from the list"),
                            systemImage: "trash"
                        ) {
                            clearAll()
                        }
                        .help(
                            String(
                                localized: "Remove all items from the list",
                                comment: "Tooltip: the status bar's Clear All button"))
                    }
                }
            }
            .padding(.horizontal, FileRowView.listHorizontalPadding)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    private var cancelAllButton: some View {
        BarButton(
            title: String(
                localized: "Cancel All",
                comment: "Button in the status bar and the service window: cancel every item still being processed"),
            systemImage: "xmark.circle"
        ) {
            appModel.cancelAll()
        }
        .help(
            String(
                localized: "Cancel all items still in progress",
                comment: "Tooltip: the Cancel All button in the status bar and the service window"))
    }

    @ViewBuilder
    private var statusText: some View {
        if let summary = statusSummary {
            switch summary.glyph {
            case .progress:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .fixedSize()
                    Text(summary.text)
                        .foregroundStyle(.secondary)
                }
            case .symbol(let name, let tint):
                // Colored icon + primary text instead of colored text, which would
                // fall short of WCAG AA contrast on the bar background.
                Label {
                    Text(summary.text)
                } icon: {
                    Image(systemName: name).foregroundStyle(tint)
                }
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

    // MARK: - Actions

    // One transaction for the view and the model: the outgoing list fades with its
    // rows and summary instead of first re-rendering empty.
    private func clearAll() {
        withAnimation(Self.resultsSwitch) {
            showsResults = false
            appModel.clear()
        }
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.message = String(
            localized: "Choose files or folders to free from quarantine",
            comment: "NSOpenPanel message for files and folders")
        panel.prompt = String(localized: "Remove Quarantine", comment: "NSOpenPanel confirm button")
        guard panel.runModal() == .OK else { return }
        Task { await appModel.process(urls: panel.urls) }
    }
}

// Bar controls give up their title when the window narrows; the title stays
// on as the symbol's spoken name.
private struct BarButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ViewThatFits(in: .horizontal) {
                Text(title)
                Image(systemName: systemImage)
                    .accessibilityLabel(Text(title))
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

// The live handlers would walk real bundles, post notifications, and
// terminate the preview host.
extension AppModel.Handlers {
    fileprivate static let preview = AppModel.Handlers(
        confirm: { _, _ in true },
        open: { _ in },
        terminate: {},
        authorize: {},
        notify: { _ in },
        notifyFailure: {},
        sessionStays: {}
    )
}

// Without a container the handover stores trust and read nothing, so a preview
// never touches the files the installed app and its Finder extension share.
extension AppModel {
    fileprivate static func preview() -> AppModel {
        AppModel(
            handlers: .preview,
            tokenStore: ServiceTokenStore(containerURL: nil),
            batchStore: ServiceBatchStore(containerURL: nil)
        )
    }
}

#Preview {
    ContentView(appModel: .preview())
}

#Preview("Service Mode") {
    let model = AppModel.preview()
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
