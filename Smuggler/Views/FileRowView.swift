//
//  FileRowView.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 21.03.26.
//

import AppKit
import SwiftUI

// MARK: - FileRowView

struct FileRowView: View {
    enum Style { case list, compact }

    let item: FileItem
    var style: Style = .list
    var onCancel: (() -> Void)?

    @State private var showErrorPopover = false
    @State private var animatedProgress: Double = 0
    @State private var icon: NSImage?
    @State private var isHovered = false

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
                        .tint(Color("SmugglerYellow"))
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

            if style == .list {
                statusLabel
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.easeInOut(duration: 0.3), value: item.status)
            }

            if item.status == .processing, let onCancel {
                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.quaternary)
                        .font(.body)
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1 : 0)
                .accessibilityLabel("Cancel processing")
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
            withAnimation(.easeOut(duration: 8.0)) {
                animatedProgress = 0.9
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
        case .partialSuccess(let cleaned, let failed):
            String(
                localized: "\(cleaned) freed, \(failed) could not be processed",
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

        case .partialSuccess(let cleaned, let failed):
            Button {
                showErrorPopover = true
            } label: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.body)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(cleaned) freed, \(failed) failed")
            .accessibilityHint("Show error details")
            .popover(isPresented: $showErrorPopover, arrowEdge: .trailing) {
                errorPopoverContent(
                    message: String(
                        localized: "\(cleaned) files freed from quarantine.\n\(failed) files could not be processed.",
                        comment: "Error popover: partial success details")
                )
            }

        case .cancelled:
            Image(systemName: "slash.circle.fill")
                .foregroundStyle(.secondary)
                .font(.body)

        case .error(let error):
            Button {
                showErrorPopover = true
            } label: {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.body)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Error")
            .accessibilityHint("Show error details")
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

    // MARK: - Status Text (compact style)

    private var statusText: String {
        switch item.status {
        case .processing:
            String(localized: "Removing quarantine…", comment: "Compact status: processing")
        case .clean:
            String(localized: "Freed from quarantine", comment: "Compact status: success")
        case .partialSuccess(let cleaned, let failed):
            String(
                localized: "\(cleaned) freed, \(failed) failed",
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
        FileRowView(item: FileItem(url: url, status: .partialSuccess(cleaned: 12, failed: 2)))
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
