import AppKit
import FinderSync
import os

private let logger = Logger(
    subsystem: "com.benjaminhuebner.Smuggler.FinderExtension",
    category: "FinderSync"
)

// Deliberately NOT @MainActor: FIFinderSync callbacks arrive on arbitrary
// queues, and MainActor isolation trips the "Block was expected to execute on
// queue main-thread" assertion in Finder — the extension then shows no menu.
final class FinderSync: FIFinderSync {
    override init() {
        super.init()
        // FinderSync only invokes the extension for items inside its registered
        // directories, and quarantined files can live anywhere the user browses.
        FIFinderSyncController.default().directoryURLs = [URL(filePath: "/")]
        logger.info("FinderSync initialized, observing /")
    }

    // MARK: - Context menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        // Menu construction runs synchronously inside Finder — don't getxattr
        // the whole selection just for a count.
        let hasQuarantinedItem = urls.contains(where: { Self.hasQuarantine($0) })
        logger.debug(
            "menu(for:) kind=\(menuKind.rawValue) selection=\(urls.count) quarantined=\(hasQuarantinedItem)")

        guard hasQuarantinedItem else {
            return NSMenu(title: "")
        }

        let submenu = NSMenu(title: "Smuggler")
        submenu.addItem(
            withTitle: String(
                localized: "Remove Quarantine and Open",
                comment: "Finder context menu: remove quarantine and open the file"),
            action: #selector(removeAndOpen(_:)),
            keyEquivalent: ""
        )
        submenu.addItem(
            withTitle: String(
                localized: "Remove Quarantine",
                comment: "Finder context menu: remove quarantine only"),
            action: #selector(removeOnly(_:)),
            keyEquivalent: ""
        )

        let parentItem = NSMenuItem(title: "Smuggler", action: nil, keyEquivalent: "")
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

        var fixedItems = [
            URLQueryItem(name: "action", value: action),
            URLQueryItem(name: "quitAfter", value: "true"),
        ]
        if let token = ServiceTokenStore().issueToken() {
            fixedItems.append(URLQueryItem(name: "token", value: token))
        } else {
            logger.warning("Could not issue service token — app will show a confirmation dialog")
        }

        let paths = urls.map { $0.path(percentEncoded: false) }

        var components = URLComponents()
        components.scheme = "smuggler"
        components.host = "process"
        // One query item per path — avoids breakage from filenames containing newlines.
        components.queryItems = paths.map { URLQueryItem(name: "path", value: $0) } + fixedItems

        // Past this length Launch Services can refuse the whole request, and a
        // refusal here is invisible to the person who clicked. The paths go
        // through the shared container instead, leaving a constant-length URL.
        if (components.url?.absoluteString.utf8.count ?? .max) > Self.maxDirectURLLength {
            if let batch = ServiceBatchStore().write(paths: paths) {
                components.queryItems = [URLQueryItem(name: "batch", value: batch)] + fixedItems
                logger.info("Selection too large for a direct URL — handing \(paths.count) path(s) over as a batch")
            } else {
                logger.error("Could not write the path batch — falling back to a URL that may be refused")
            }
        }

        guard let url = components.url else {
            logger.error("Failed to construct smuggler:// URL")
            return
        }

        logger.info("Opening smuggler URL for \(urls.count) item(s), action: \(action)")

        Task { @MainActor in
            if !NSWorkspace.shared.open(url) {
                logger.error("NSWorkspace declined to open the smuggler:// URL (\(urls.count) items)")
            }
        }
    }

    private static let maxDirectURLLength = 6000

    // Duplicates `QuarantineService.hasQuarantine` deliberately: sharing the file
    // via target membership would drag unused recursion code and localized error
    // strings into the extension for a single 4-line function.
    private static func hasQuarantine(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
        }
    }
}
