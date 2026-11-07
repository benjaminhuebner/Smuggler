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
    private static let containingAppURL = ContainingApp.url(containing: Bundle.main.bundleURL)

    override init() {
        super.init()
        // FinderSync only invokes the extension for items inside its registered
        // directories, and quarantined files can live anywhere the user browses.
        FIFinderSyncController.default().directoryURLs = [URL(filePath: "/")]
        logger.info("FinderSync initialized, observing /")
    }

    // MARK: - Context menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        // Sidebar and background clicks point at something other than the
        // selection the actions read, so only a click on items gets the menu.
        guard menuKind == .contextualMenuForItems else {
            logger.debug("menu(for:) kind=\(menuKind.rawValue) skipped")
            return NSMenu(title: "")
        }
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
                comment: "Finder context menu: remove quarantine, then open the item"),
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
        sendToApp(action: .open)
    }

    @objc func removeOnly(_ sender: Any?) {
        sendToApp(action: .remove)
    }

    // MARK: - Private

    private func sendToApp(action: ServiceAction) {
        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        guard !urls.isEmpty else { return }

        let token = ServiceTokenStore().issueToken()
        if token == nil {
            logger.warning("Could not issue service token — app will show a confirmation dialog")
        }

        guard
            let url = ServiceRequestURL.make(
                paths: urls.map { $0.path(percentEncoded: false) },
                action: action,
                quitAfter: true,
                token: token,
                batchStore: ServiceBatchStore()
            )
        else {
            logger.error("Failed to construct smuggler:// URL")
            return
        }

        let count = urls.count
        logger.info("Opening smuggler URL for \(count) item(s), action: \(action.rawValue)")

        // No fallback to the default handler on failure: that is the route the
        // token must never take.
        NSWorkspace.shared.open(
            [url], withApplicationAt: Self.containingAppURL, configuration: ContainingApp.openConfiguration()
        ) { _, error in
            if let error {
                logger.error(
                    "Could not hand \(count) item(s) to Smuggler: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // A link would report its target's attribute, and the app never follows one.
    private static func hasQuarantine(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
        }
    }
}
