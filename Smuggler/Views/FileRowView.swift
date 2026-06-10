import AppKit
import SwiftUI

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

    private static let placeholderIcon = NSImage(systemSymbolName: "doc", accessibilityDescription: nil) ?? NSImage()

    private var isFinished: Bool { item.status != .processing }

    private var displayProgress: Double {
        isFinished ? 1.0 : animatedProgress
    }

    var body: some View {
        HStack(spacing: style == .compact ? 10 : 12) {
            Image(nsImage: icon ?? Self.placeholderIcon)
                .resizable()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(style == .compact ? .callout.weight(.medium) : .body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if item.status == .processing {
                    ProgressView(value: displayProgress)
                        .progressViewStyle(.linear)
                        .tint(Color.smugglerYellow)
                        .animation(.easeInOut(duration: 0.2), value: displayProgress)
                } else if style == .list {
                    Text(statusDescription)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if style == .compact {
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            statusLabel
                .contentTransition(.symbolEffect(.replace))
                .animation(.easeInOut(duration: 0.3), value: item.status)

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
        .padding(.horizontal, style == .compact ? 12 : 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        // Terminal rows collapse to a single VoiceOver stop reading "name, status";
        // the error popover stays reachable as a named action. Processing rows keep
        // their children so the progress bar and cancel control remain individual stops.
        .accessibilityElement(children: isFinished ? .ignore : .contain)
        .accessibilityLabel(isFinished ? "\(item.name), \(statusText)" : item.name)
        .accessibilityActions {
            if isFinished, item.status.hasErrors {
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
            // Load icon off the main thread to avoid blocking during bulk drops
            let path = item.url.path(percentEncoded: false)
            let loadedIcon = await Task.detached(priority: .userInitiated) {
                NSWorkspace.shared.icon(forFile: path)
            }.value
            icon = loadedIcon

            // Ease toward 0.9 (not 1.0) while processing so the bar shows
            // motion without falsely signalling completion. The duration is
            // long with ease-out so it decelerates and lingers near the end.
            guard item.status == .processing else { return }
            if reduceMotion {
                animatedProgress = 0.9
            } else {
                withAnimation(.easeOut(duration: 8.0)) {
                    animatedProgress = 0.9
                }
            }
        }
    }

    // MARK: - Status Description (subtitle in list style)

    private var statusDescription: String {
        switch item.status {
        case .processing:
            String(localized: "Processing…", comment: "File row status: currently processing")
        case .clean:
            String(localized: "Quarantine removed successfully", comment: "File row status: success")
        case .alreadyClean:
            String(localized: "Already clean — no quarantine present", comment: "File row status: had no quarantine")
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
        switch item.status {
        case .processing:
            EmptyView()

        case .clean:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.body)
                .accessibilityLabel(
                    String(localized: "Freed from quarantine", comment: "Compact status: success"))

        case .alreadyClean:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
                .font(.body)
                .accessibilityLabel(
                    String(localized: "Already clean", comment: "Compact status: had no quarantine"))

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
                errorPopoverContent(
                    message: error.errorDescription
                        ?? String(localized: "An error occurred", comment: "Fallback error message")
                )
            }
        }
    }

    private func errorPopoverContent(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.callout)
        }
        .padding(12)
        .frame(maxWidth: 340)
        .fixedSize(horizontal: false, vertical: true)
    }

    private static let popoverErrorLimit = 20

    private func partialSuccessPopoverContent(cleaned: Int, errors: [QuarantineFileError]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                String(
                    localized: "\(cleaned) files freed from quarantine.\n\(errors.count) files could not be processed:",
                    comment: "Error popover: partial success details, followed by the failing file names")
            )
            .font(.callout)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(errors.prefix(Self.popoverErrorLimit)) { fileError in
                        Text(fileError.url.lastPathComponent)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(fileError.error.errorDescription ?? "")
                    }
                    if errors.count > Self.popoverErrorLimit {
                        let more = errors.count - Self.popoverErrorLimit
                        Text(
                            String(
                                localized: "and \(more) more",
                                comment: "Confirm dialog: suffix when the path list is truncated")
                        )
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
        switch item.status {
        case .processing:
            String(localized: "Removing quarantine…", comment: "Compact status: processing")
        case .clean:
            String(localized: "Freed from quarantine", comment: "Compact status: success")
        case .alreadyClean:
            String(localized: "Already clean", comment: "Compact status: had no quarantine")
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
    let url = URL(fileURLWithPath: "/Applications/Safari.app")
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
    let url = URL(fileURLWithPath: "/Applications/Safari.app")
    VStack(spacing: 0) {
        FileRowView(item: FileItem(url: url, status: .processing), style: .compact)
        Divider().padding(.leading, 44)
        FileRowView(item: FileItem(url: url, status: .clean), style: .compact)
        Divider().padding(.leading, 44)
        FileRowView(item: FileItem(url: url, status: .error(.permissionDenied(url))), style: .compact)
    }
    .frame(width: 340)
}
