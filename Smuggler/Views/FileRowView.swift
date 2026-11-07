import AppKit
import SwiftUI

// MARK: - Finishing-Fill Preference

// Rows report their finishing fill upward so summary UI can hold its
// processing presentation until every bar has visibly landed — real
// completion leads the fill by its duration.
nonisolated struct FinishingFillCountKey: PreferenceKey {
    static let defaultValue = 0

    static func reduce(value: inout Int, nextValue: () -> Int) {
        value += nextValue()
    }
}

// MARK: - Popover Trigger Chrome

// Two of the status symbols open a popover and the rest are decoration; drawn
// identically, nothing tells the person which of them is a control. Hovering the
// row lifts the interactive ones onto a backing the others never get.
private struct PopoverTriggerChrome: ViewModifier {
    let isHovered: Bool

    func body(content: Content) -> some View {
        // Bled outward rather than padded and un-padded: the backing has to grow
        // past the glyph without the glyph's slot growing with it.
        content.background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.09) : Color.clear)
                .padding(-3)
        }
    }
}

// MARK: - Reveal in Finder

// A row offers revealing three ways — hover button, context menu, accessibility
// action. One definition, so behaviour and label cannot drift apart.
private enum RevealAction {
    static let label = String(
        localized: "Show in Finder", comment: "Row button, menu item and VoiceOver action: reveal the item in Finder")

    static func run(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Row Context Menu

// Right-click is where macOS puts "Show in Finder"; the hover-revealed button
// reaches nobody who isn't already sweeping the row with the pointer. The
// service window stays without one — it is transient and closes itself.
private struct RevealContextMenu: ViewModifier {
    let url: URL
    let isAttached: Bool
    let canReveal: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isAttached {
            content.contextMenu {
                Button {
                    RevealAction.run(url)
                } label: {
                    // Names the destination instead of describing a generic folder.
                    // Whether the image draws at all is the system's call, not ours.
                    Label(RevealAction.label, systemImage: "finder")
                }
                // Dimmed rather than dropped: an empty menu on a row whose file
                // vanished reads as a broken right-click.
                .disabled(!canReveal)
                // The list tints itself yellow and a menu inherits it, which would
                // paint the glyph in the color reserved for a landing action.
                .tint(.primary)
            }
        } else {
            content
        }
    }
}

// MARK: - FileRowView

struct FileRowView: View {
    enum Style { case list, compact }

    let item: FileItem
    var style: Style = .list
    var isAlternateRow = false
    var onCancel: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showErrorPopover = false
    @State private var animatedProgress: Double = 0
    @State private var icon: NSImage?
    @State private var isHovered = false
    @FocusState private var cancelFocused: Bool
    @FocusState private var revealFocused: Bool

    private static let placeholderIcon = NSImage(systemSymbolName: "doc", accessibilityDescription: nil) ?? NSImage()
    private static let showErrorDetails = String(
        localized: "Show error details", comment: "Accessibility action: open the error popover")

    private static let iconSize: CGFloat = 28
    private static let compactHorizontalPadding: CGFloat = 12
    private static let compactContentSpacing: CGFloat = 10

    // The window's content inset: the drop strip and the status bar align to it.
    static let listHorizontalPadding: CGFloat = 20

    // Derived, not repeated: dividers and summary rows in the service window
    // align to this column, and a hand-copied value silently drifts from it.
    static let compactTextInset = compactHorizontalPadding + iconSize + compactContentSpacing

    private var isFinished: Bool { item.status != .processing }

    // A completed run sprints the bar to full before it leaves — a bar vanishing
    // mid-crawl reads as broken. Derived, never latched: a flag written from
    // .onChange lands a pass after the terminal status and flashes the result.
    private var isFinishingFill: Bool {
        isFinished && completedWithoutErrors && animatedProgress > 0 && !reduceMotion
    }

    // All visual state reads this lagged status: while the finishing fill runs,
    // the row keeps presenting as processing so checkmark and success text
    // cannot appear before the bar reaches full.
    private var displayStatus: FileStatus {
        isFinishingFill ? .processing : item.status
    }

    private var showsProgressBar: Bool { displayStatus == .processing }

    // Accessibility follows the same lagged status as the visuals, or VoiceOver
    // would read "Removing quarantine…" out of a row it has already collapsed.
    private var presentsAsFinished: Bool { !showsProgressBar }

    // .partialSuccess is excluded: a bar sprinting to full would claim a success
    // the run didn't have.
    private var completedWithoutErrors: Bool {
        item.status == .clean || item.status == .alreadyClean
    }

    private var displayProgress: Double {
        isFinished ? 1.0 : animatedProgress
    }

    // Revealing is not opening: it launches nothing, so it needs no confirmation.
    // Only a proved-missing file hides it; a processing or cancelled row still has
    // a file to select, and a walk stopped midway may already have freed part of it.
    private var canRevealInFinder: Bool {
        style == .list && !item.provedMissing
    }

    // The button shares the trailing slot with the cancel control, so it stays out
    // while a bar is up. Menu and accessibility action have no such constraint and
    // keep offering it there.
    private var showsRevealButton: Bool {
        canRevealInFinder && presentsAsFinished
    }

    var body: some View {
        HStack(spacing: style == .compact ? Self.compactContentSpacing : 12) {
            Image(nsImage: icon ?? Self.placeholderIcon)
                .resizable()
                .frame(width: Self.iconSize, height: Self.iconSize)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(style == .compact ? .callout.weight(.medium) : .body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if showsProgressBar {
                    // The fill is a paced estimate, not measured progress, so the
                    // spoken value must not read as a percentage of the real work.
                    ProgressView(value: displayProgress)
                        .progressViewStyle(.linear)
                        .tint(Color.smugglerYellow)
                        .accessibilityLabel(statusText)
                        .accessibilityValue(
                            String(localized: "In progress", comment: "Accessibility value: work is still running")
                        )
                }

                if style == .compact || !showsProgressBar {
                    // Primary, not a grey: .secondary falls short of 4.5:1 at this
                    // size, and this line is the answer the person came for. Held
                    // to one line — the full text is a pointer or a popover away.
                    Text(statusText)
                        .font(style == .compact ? .subheadline : .callout)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .help(statusText)
                        // The bar above already speaks this line while it runs.
                        .accessibilityHidden(showsProgressBar)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showsProgressBar)

            Spacer()

            if showsRevealButton {
                Button {
                    RevealAction.run(item.url)
                } label: {
                    Image(systemName: "finder")
                        .foregroundStyle(.secondary)
                        .font(.body)
                }
                .buttonStyle(.plain)
                .opacity(isHovered || revealFocused ? 1 : 0)
                .focused($revealFocused)
                .accessibilityLabel(RevealAction.label)
                .help(RevealAction.label)
            }

            statusLabel
                .contentTransition(.symbolEffect(.replace))
                .animation(.easeInOut(duration: 0.3), value: displayStatus)

            // Lagged like the rest of the row: keyed on the real status the button
            // would leave mid finishing fill and its freed width briefly widens
            // the bar.
            if showsProgressBar, let onCancel {
                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.body)
                }
                .buttonStyle(.plain)
                // Held only to keep that width: the model is already done, so a
                // click here would cancel nothing.
                .disabled(isFinishingFill)
                // Keyboard focus must reveal the hover-gated button, or Full
                // Keyboard Access users would tab onto an invisible control.
                .opacity(isHovered || cancelFocused ? 1 : 0)
                .focused($cancelFocused)
                .accessibilityLabel(
                    String(localized: "Cancel processing", comment: "Accessibility label: cancel button on a row")
                )
                .help(String(localized: "Cancel", comment: "Tooltip: the cancel button on a row still processing"))
            }
        }
        .padding(.vertical, style == .compact ? 6 : 8)
        // Matches the drop strip and the status bar that frame the list; a row on
        // its own inset would stair-step against both.
        .padding(.horizontal, style == .compact ? Self.compactHorizontalPadding : Self.listHorizontalPadding)
        .background(rowBackground)
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .modifier(
            RevealContextMenu(url: item.url, isAttached: style == .list, canReveal: canRevealInFinder)
        )
        .preference(key: FinishingFillCountKey.self, value: isFinishingFill ? 1 : 0)
        // Terminal rows collapse to a single VoiceOver stop reading name, then status;
        // the error popover stays reachable as a named action. Processing rows keep
        // their children so the progress bar and cancel control remain individual stops.
        .accessibilityElement(children: presentsAsFinished ? .ignore : .contain)
        .accessibilityLabel(errorNamesRow ? statusText : item.name)
        .accessibilityValue(presentsAsFinished && !errorNamesRow ? statusText : "")
        .accessibilityActions {
            if canRevealInFinder {
                Button(RevealAction.label) {
                    RevealAction.run(item.url)
                }
            }
            if presentsAsFinished, item.status.hasErrors {
                Button(Self.showErrorDetails) {
                    showErrorPopover = true
                }
            }
            // Real status, not the lagged one: an action has no width to hold, and
            // offering one that cancels nothing is worse than offering none.
            if item.status == .processing, let onCancel {
                Button(
                    String(localized: "Cancel processing", comment: "Accessibility label: cancel button on a row")
                ) {
                    onCancel()
                }
            }
        }
        .task(id: item.id) {
            icon = await Self.loadIcon(forPath: item.url.path(percentEncoded: false))
        }
        // Re-dropping a finished file reuses the row identity, so the ease must
        // key on the status transition — a task keyed on the row would not rerun
        // and the bar would resume at its previous value.
        .task(id: isFinished) {
            if isFinished {
                // Zeroing the progress is what ends the fill; cancelled, failed
                // and partial runs never held it, so they drop the bar at once.
                if isFinishingFill {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                }
                animatedProgress = 0
                return
            }
            // Ease toward 0.9 (not 1.0) while processing so the bar shows motion
            // without falsely signalling completion; the long ease-out lingers near the end.
            if reduceMotion {
                animatedProgress = 0.9
                return
            }
            // The bar's AppKit backing ignores transaction animations and smooths
            // any value jump over ~0.5s — withAnimation's slow fill arrived almost
            // instantly. Stepped values let that smoothing interpolate an 8s ease.
            let start = item.processingSince ?? .now
            while !Task.isCancelled {
                let fraction = min(1.0, (ContinuousClock.now - start) / .seconds(8))
                animatedProgress = 0.9 * (1 - pow(1 - fraction, 3))
                guard fraction < 1 else { return }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        // A lazy stack cancels this row's tasks when it scrolls out: a fill left
        // standing would replay its landing on return, or never end at all.
        .onDisappear {
            animatedProgress = 0
        }
    }

    // MARK: - Row Background

    // The system's own table backing, not a hand-mixed grey: it is the value
    // NSTableView uses, so it tracks appearance and Increased Contrast for free.
    private static let alternateFill = Color(
        nsColor: NSColor.alternatingContentBackgroundColors.last ?? .controlBackgroundColor)

    private var rowBackground: some View {
        ZStack {
            // Banding is the list's own scanning aid; the service window separates
            // its handful of rows with dividers instead. Hover belongs to both.
            if style == .list, isAlternateRow {
                Self.alternateFill
            }
            if isHovered {
                Color.primary.opacity(0.06)
            }
        }
    }

    // MARK: - Icon Loading

    // Icon lookup hits the disk; running it inline would stall row rendering on bulk drops.
    @concurrent
    private nonisolated static func loadIcon(forPath path: String) async -> NSImage {
        NSWorkspace.shared.icon(forFile: path)
    }

    // MARK: - Status

    // The line, its tooltip and VoiceOver all read this one wording, so nobody hears
    // other words than the row shows.
    private var statusText: String {
        switch displayStatus {
        case .processing:
            String(localized: "Removing quarantine…", comment: "File row status: processing")
        case .clean:
            String(localized: "Freed — ready to use", comment: "File row status: success")
        case .alreadyClean:
            style == .list
                ? String(localized: "Not in quarantine — nothing to do", comment: "File row status: had no quarantine")
                : String(localized: "Not in quarantine", comment: "Compact status: had no quarantine")
        case .partialSuccess(let cleaned, let errors):
            style == .list
                ? String(
                    localized: "\(cleaned) freed, \(errors.count) could not be processed",
                    comment: "File row status: partial success with counts")
                : String(
                    localized: "\(cleaned) freed, \(errors.count) failed", comment: "Compact status: partial success")
        case .cancelled:
            style == .list
                ? String(localized: "Processing was canceled", comment: "File row status: canceled")
                : String(localized: "Canceled", comment: "Compact status: canceled")
        case .error(let error):
            error.message
        }
    }

    private var statusSymbol: (name: String, tint: Color)? {
        switch displayStatus {
        case .processing: nil
        case .clean: ("checkmark.circle.fill", .green)
        case .alreadyClean: ("checkmark.circle", .secondary)
        case .partialSuccess: ("exclamationmark.triangle.fill", .orange)
        case .cancelled: ("slash.circle.fill", .secondary)
        case .error: ("exclamationmark.circle.fill", .red)
        }
    }

    // An error about the row itself already names it. One about a descendant, which
    // a folder whose walk freed nothing reports, names only the descendant.
    private var errorNamesRow: Bool {
        if case .error(let error) = displayStatus { error.url == item.url } else { false }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if let symbol = statusSymbol {
            let image = Image(systemName: symbol.name)
                .foregroundStyle(symbol.tint)
                .font(.body)
            if displayStatus.hasErrors {
                Button {
                    showErrorPopover = true
                } label: {
                    image.modifier(PopoverTriggerChrome(isHovered: isHovered))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(statusText)
                .accessibilityHint(Self.showErrorDetails)
                .popover(isPresented: $showErrorPopover, arrowEdge: .trailing) {
                    errorDetails
                }
            } else {
                image.accessibilityLabel(statusText)
            }
        }
    }

    @ViewBuilder
    private var errorDetails: some View {
        switch displayStatus {
        case .partialSuccess(let cleaned, let errors):
            PartialSuccessPopover(cleaned: cleaned, errors: errors)
        case .error(let error):
            ErrorPopover(error: error)
        default:
            EmptyView()
        }
    }
}

// MARK: - Previews

#Preview("List Style") {
    let url = URL(filePath: "/Applications/Safari.app")
    List {
        FileRowView(item: FileItem(url: url, status: .processing))
        FileRowView(item: FileItem(url: url, status: .clean))
        FileRowView(
            item: FileItem(
                url: url,
                status: .partialSuccess(
                    cleaned: 12,
                    errors: [
                        QuarantineFileError(url: URL(filePath: "/tmp/locked.app"), error: .permissionDenied(url)),
                        QuarantineFileError(url: URL(filePath: "/tmp/gone.dmg"), error: .fileNotFound(url)),
                    ])))
        FileRowView(item: FileItem(url: url, status: .cancelled))
        FileRowView(item: FileItem(url: url, status: .error(.permissionDenied(url))))
    }
    .listStyle(.inset)
    .frame(width: 360)
}

#Preview("Compact Style") {
    let url = URL(filePath: "/Applications/Safari.app")
    VStack(spacing: 0) {
        FileRowView(item: FileItem(url: url, status: .processing), style: .compact)
        Divider().padding(.leading, FileRowView.compactTextInset)
        FileRowView(item: FileItem(url: url, status: .clean), style: .compact)
        Divider().padding(.leading, FileRowView.compactTextInset)
        FileRowView(item: FileItem(url: url, status: .error(.permissionDenied(url))), style: .compact)
    }
    .frame(width: 340)
}
