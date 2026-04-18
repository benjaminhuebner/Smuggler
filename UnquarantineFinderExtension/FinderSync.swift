//
//  FinderSync.swift
//  Unquarantine
//
//  Created by Benjamin Hübner on 21.03.26.
//

import FinderSync
import AppKit
import os

private let logger = Logger(
    subsystem: "com.benjaminhuebner.Unquarantine.FinderExtension",
    category: "FinderSync"
)

final class FinderSync: FIFinderSync {

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    // MARK: - Context menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []

        // Only show menu items when at least one selected file is quarantined
        guard urls.contains(where: { Self.hasQuarantine($0) }) else {
            return NSMenu(title: "")
        }

        let submenu = NSMenu(title: "Unquarantine")
        submenu.addItem(
            withTitle: String(localized: "Remove Quarantine and Open",
                              comment: "Finder context menu: remove quarantine and open the file"),
            action: #selector(removeAndOpen(_:)),
            keyEquivalent: ""
        )
        submenu.addItem(
            withTitle: String(localized: "Remove Quarantine",
                              comment: "Finder context menu: remove quarantine only"),
            action: #selector(removeOnly(_:)),
            keyEquivalent: ""
        )

        let parentItem = NSMenuItem(title: "Unquarantine", action: nil, keyEquivalent: "")
        parentItem.submenu = submenu

        let menu = NSMenu(title: "")
        menu.addItem(parentItem)
        return menu
    }

    @objc func removeAndOpen(_ sender: Any?) {
        sendToApp(action: "open")
    }

    @objc func removeOnly(_ sender: Any?) {
        sendToApp(action: "remove")
    }

    // MARK: - Private

    private func sendToApp(action: String) {
        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        guard !urls.isEmpty else { return }

        var components = URLComponents()
        components.scheme = "unquarantine"
        components.host = "process"

        // Use one query item per path — avoids breakage from filenames containing newlines
        var queryItems = urls.map { URLQueryItem(name: "path", value: $0.path(percentEncoded: false)) }
        queryItems.append(URLQueryItem(name: "action", value: action))
        queryItems.append(URLQueryItem(name: "quitAfter", value: "true"))
        components.queryItems = queryItems

        guard let url = components.url else {
            logger.error("Failed to construct unquarantine:// URL")
            return
        }

        logger.info("Opening unquarantine URL for \(urls.count) item(s), action: \(action)")

        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
        }
    }

    /// Duplicates `QuarantineService.hasQuarantine` — the extension target cannot
    /// import from the main app without a shared framework, which is not worth the
    /// complexity for this single 4-line function.
    private static func hasQuarantine(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
        }
    }
}
