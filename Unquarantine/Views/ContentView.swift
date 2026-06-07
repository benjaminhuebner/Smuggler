//
//  ContentView.swift
//  Unquarantine
//
//  Created by Benjamin Hübner on 21.03.26.
//

import AppKit
import SwiftUI

struct ContentView: View {
    let appModel: AppModel
    @State private var isDropTargeted = false

    private var isServiceMode: Bool { appModel.serviceMode != nil }

    var body: some View {
        if isServiceMode {
            serviceView
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 320)
        } else {
            normalView
        }
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
            .tint(Color("UnquarantinePurple"))
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
                            .accessibilityLabel("Clear all")
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove all items from the list")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private var statusText: some View {
        if appModel.isProcessing {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .fixedSize()
                Text("Processing…")
                    .lineLimit(1)
            }
        } else if appModel.allCancelled {
            Text("All items cancelled")
        } else if appModel.cleanedCount == 0 {
            Text("No items could be freed")
        } else {
            Label(
                appModel.cleanedCount == 1
                    ? "1 item freed"
                    : "\(appModel.cleanedCount) items freed",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
        }
    }

    // MARK: - Service Mode (Finder Extension / Services Menu)

    private var serviceView: some View {
        let lastItemID = appModel.items.last?.id
        return VStack(spacing: 0) {
            ForEach(appModel.items) { item in
                FileRowView(item: item, style: .compact) {
                    appModel.cancel(id: item.id)
                }
                if item.id != lastItemID {
                    Divider().padding(.leading, 44)
                }
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
    let model = AppModel()
    ContentView(appModel: model)
        .onAppear {
            let urls = [
                URL(fileURLWithPath: "/Applications/Safari.app"),
                URL(fileURLWithPath: "/tmp/test.zip"),
            ]
            model.handleServiceURLs(urls, action: "remove", quitAfter: true)
        }
        .frame(width: 380)
}
