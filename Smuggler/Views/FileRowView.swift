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

// MARK: - FileRowView

struct FileRowView: View {
    enum Style { case list, compact }

    let item: FileItem
    var style: Style = .list
    var onCancel: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showErrorPopover = false
    @State private var animatedProgress: Double = 0
    @State private var icon: NSImage?
    @State private var isHovered = false
    @FocusState private var cancelFocused: Bool
    @FocusState private var revealFocused: Bool

    private static let placeholderIcon = NSImage(systemSymbolName: "doc", accessibilityDescription: nil) ?? NSImage()

    private static let iconSize: CGFloat = 28
    private static let compactHorizontalPadding: CGFloat = 12
    private static let compactContentSpacing: CGFloat = 10

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
    private var canRevealInFinder: Bool {
        guard style == .list, presentsAsFinished else { return false }
        switch item.status {
        case .clean, .alreadyClean, .partialSuccess: return true
        case .error(let error): return !error.refersToMissingFile
        default: return false
        }
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
                        .accessibilityLabel(
                            String(localized: "Removing quarantine…", comment: "Compact status: processing")
                        )
                        .accessibilityValue(
                            String(localized: "In progress", comment: "Accessibility value: work is still running")
                        )
                } else if style == .list {
                    // Primary, not a grey: .secondary falls short of 4.5:1 at this
                    // size, and this line is the answer the person came for. Held
                    // to one line — the full text is a pointer or a popover away.
                    Text(statusDescription)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .help(statusDescription)
                }

                if style == .compact {
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .help(statusText)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showsProgressBar)

            Spacer()

            if canRevealInFinder {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                } label: {
                    Image(systemName: "folder")
                        .foregroundStyle(.quaternary)
                        .font(.body)
                }
                .buttonStyle(.plain)
                .opacity(isHovered || revealFocused ? 1 : 0)
                .focused($revealFocused)
                .accessibilityLabel(
                    String(localized: "Show in Finder", comment: "Accessibility label: reveal the file in Finder")
                )
                .help("Show in Finder")
            }

            statusLabel
                .contentTransition(.symbolEffect(.replace))
                .animation(.easeInOut(duration: 0.3), value: displayStatus)

            if item.status == .processing, let onCancel {
                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.quaternary)
                        .font(.body)
                }
                .buttonStyle(.plain)
                // Keyboard focus must reveal the hover-gated button, or Full
                // Keyboard Access users would tab onto an invisible control.
                .opacity(isHovered || cancelFocused ? 1 : 0)
                .focused($cancelFocused)
                .accessibilityLabel(
                    String(localized: "Cancel processing", comment: "Accessibility label: cancel button on a row")
                )
                .help("Cancel")
            }
        }
        .padding(.vertical, style == .compact ? 6 : 8)
        .padding(.horizontal, style == .compact ? Self.compactHorizontalPadding : 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .preference(key: FinishingFillCountKey.self, value: isFinishingFill ? 1 : 0)
        // Terminal rows collapse to a single VoiceOver stop reading "name, status";
        // the error popover stays reachable as a named action. Processing rows keep
        // their children so the progress bar and cancel control remain individual stops.
        .accessibilityElement(children: presentsAsFinished ? .ignore : .contain)
        .accessibilityLabel(presentsAsFinished ? "\(item.name), \(statusText)" : item.name)
        .accessibilityActions {
            if canRevealInFinder {
                Button(
                    String(localized: "Show in Finder", comment: "Accessibility label: reveal the file in Finder")
                ) {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
            }
            if presentsAsFinished, item.status.hasErrors {
                Button(
                    String(localized: "Show error details", comment: "Accessibility action: open the error popover")
                ) {
                    showErrorPopover = true
                }
            }
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
            let start = ContinuousClock.now
            while !Task.isCancelled {
                let fraction = min(1.0, (ContinuousClock.now - start) / .seconds(8))
                animatedProgress = 0.9 * (1 - pow(1 - fraction, 3))
                guard fraction < 1 else { return }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    // MARK: - Icon Loading

    // Icon lookup hits the disk; running it inline would stall row rendering on bulk drops.
    @concurrent
    private nonisolated static func loadIcon(forPath path: String) async -> NSImage {
        NSWorkspace.shared.icon(forFile: path)
    }

    // MARK: - Status Description (subtitle in list style)

    private var statusDescription: String {
        switch displayStatus {
        case .processing:
            String(localized: "Processing…", comment: "File row status: currently processing")
        case .clean:
            String(localized: "Freed — ready to use", comment: "File row status: success")
        case .alreadyClean:
            String(localized: "Not in quarantine — nothing to do", comment: "File row status: had no quarantine")
        case .partialSuccess(let cleaned, let errors):
            String(
                localized: "\(cleaned) freed, \(errors.count) could not be processed",
                comment: "File row status: partial success with counts")
        case .cancelled:
            String(localized: "Processing was cancelled", comment: "File row status: cancelled")
        case .error(let error):
            error.errorDescription ?? String(localized: "An error occurred", comment: "Fallback error message")
        }
    }

    // MARK: - Status Label (list style)

    @ViewBuilder
    private var statusLabel: some View {
        switch displayStatus {
        case .processing:
            EmptyView()

        case .clean:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.body)
                .accessibilityLabel(
                    String(localized: "Freed — ready to use", comment: "Compact status: success"))

        case .alreadyClean:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
                .font(.body)
                .accessibilityLabel(
                    String(localized: "Not in quarantine", comment: "Compact status: had no quarantine"))

        case .partialSuccess(let cleaned, let errors):
            Button {
                showErrorPopover = true
            } label: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.body)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                String(
                    localized: "\(cleaned) freed, \(errors.count) failed",
                    comment: "Compact status: partial success")
            )
            .accessibilityHint(
                String(localized: "Show error details", comment: "Accessibility action: open the error popover")
            )
            .popover(isPresented: $showErrorPopover, arrowEdge: .trailing) {
                partialSuccessPopoverContent(cleaned: cleaned, errors: errors)
            }

        case .cancelled:
            Image(systemName: "slash.circle.fill")
                .foregroundStyle(.secondary)
                .font(.body)
                .accessibilityLabel(
                    String(localized: "Cancelled", comment: "Compact status: cancelled"))

        case .error(let error):
            Button {
                showErrorPopover = true
            } label: {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.body)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                String(localized: "Error: \(item.name)", comment: "Accessibility label: error button with file name")
            )
            .accessibilityHint(
                String(localized: "Show error details", comment: "Accessibility action: open the error popover")
            )
            .popover(isPresented: $showErrorPopover, arrowEdge: .trailing) {
                errorPopoverContent(error: error)
            }
        }
    }

    private func errorPopoverContent(error: QuarantineError) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(error.errorDescription ?? String(localized: "An error occurred", comment: "Fallback error message"))
                .font(.callout.weight(.medium))

            if let recovery = error.recoverySuggestion {
                Text(recovery)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: 340)
        .fixedSize(horizontal: false, vertical: true)
    }

    private static let popoverErrorLimit = 20

    private func freedLine(_ cleaned: Int) -> String {
        cleaned == 1
            ? String(
                localized: "1 item freed from quarantine.",
                comment: "Error popover: exactly one item was freed")
            : String(
                localized: "\(cleaned) items freed from quarantine.",
                comment: "Error popover: several items were freed")
    }

    private func failedLine(_ failed: Int) -> String {
        failed == 1
            ? String(
                localized: "1 item could not be processed:",
                comment: "Error popover: exactly one item failed, followed by its name")
            : String(
                localized: "\(failed) items could not be processed:",
                comment: "Error popover: several items failed, followed by their names")
    }

    private func partialSuccessPopoverContent(cleaned: Int, errors: [QuarantineFileError]) -> some View {
        let (shownErrors, hiddenCount) = errors.cappedPrefix(Self.popoverErrorLimit)
        return VStack(alignment: .leading, spacing: 8) {
            // Two sentences, each with its own count line: one string carrying both
            // numbers cannot read correctly at one in either of them.
            Text("\(freedLine(cleaned))\n\(failedLine(errors.count))")
                .font(.callout)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(shownErrors) { fileError in
                        Text(fileError.url.lastPathComponent)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(fileError.error.errorDescription ?? "")
                    }
                    if hiddenCount > 0 {
                        Text(hiddenItemsLabel(hiddenCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
        }
        .padding(12)
        .frame(width: 340)
    }

    // MARK: - Status Text (compact style)

    private var statusText: String {
        switch displayStatus {
        case .processing:
            String(localized: "Removing quarantine…", comment: "Compact status: processing")
        case .clean:
            String(localized: "Freed — ready to use", comment: "Compact status: success")
        case .alreadyClean:
            String(localized: "Not in quarantine", comment: "Compact status: had no quarantine")
        case .partialSuccess(let cleaned, let errors):
            String(
                localized: "\(cleaned) freed, \(errors.count) failed",
                comment: "Compact status: partial success")
        case .cancelled:
            String(localized: "Cancelled", comment: "Compact status: cancelled")
        case .error(let error):
            error.errorDescription ?? String(localized: "Error", comment: "Compact status: error fallback")
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
