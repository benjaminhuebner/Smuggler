//
//  ConfirmationAlert.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 05.09.26.
//

import AppKit

// Cancel answers Escape by hand — AppKit binds it only to the literal title
// "Cancel", which no localized build carries — and a dialog guarding against a
// stray keystroke gives Return nothing to approve.
enum ConfirmationAlert {
    struct Content {
        let title: String
        let body: String
        let confirmTitle: String
    }

    static func confirmRequest(_ urls: [URL], kind: AppModel.ConfirmKind) -> Bool {
        // The dialog may be triggered while another app is frontmost (URL scheme,
        // headless service launch) — without activation it would appear behind.
        NSApp.activate(ignoringOtherApps: true)

        return run(
            requestContent(for: urls, kind: kind),
            // The person asked for an open, so it keeps its default button. An external
            // remove can land mid-keystroke, and a stray Return must not approve it.
            returnConfirms: kind == .open)
    }

    // Built apart from the alert: this is where an arbitrary sender's names reach a
    // person about to lift Gatekeeper's check, so a test has to be able to read it.
    static func requestContent(for urls: [URL], kind: AppModel.ConfirmKind) -> Content {
        switch kind {
        case .open:
            return Content(
                title: urls.count == 1
                    ? String(
                        localized: "Open \(urls[0].displayName)?",
                        comment: "Confirm dialog title: open the one named item after removing quarantine")
                    : String(
                        localized: "Open \(urls.count) items?",
                        comment: "Confirm dialog title: the number of items to open after removing quarantine"),
                body: String(
                    localized: "Quarantine was removed. Only open items you trust.",
                    comment: "Confirm dialog body: warn before opening items after quarantine removal"),
                confirmTitle: String(localized: "Open", comment: "Confirm dialog: open button"))
        case .remove:
            let (shownURLs, hiddenCount) = urls.cappedPrefix(10)
            var pathList = shownURLs.map(\.displayPath).joined(separator: "\n")
            if hiddenCount > 0 {
                pathList += "\n" + hiddenItemsLabel(hiddenCount)
            }
            return Content(
                title: urls.count == 1
                    ? String(
                        localized: "Remove quarantine from \(urls[0].displayName)?",
                        comment: "Confirm dialog title: external request to remove quarantine from one named item")
                    : String(
                        localized: "Remove quarantine from \(urls.count) items?",
                        comment: "Confirm dialog title: external request to remove quarantine from a number of items"),
                body: String(
                    localized: """
                        Only continue if you started this yourself.

                        \(pathList)
                        """,
                    comment: "Confirm dialog body: warn about an external quarantine-removal request"),
                confirmTitle: String(
                    localized: "Remove Quarantine",
                    comment: "Confirm dialog: remove quarantine button"))
        }
    }

    static func confirmQuitWhileProcessing() -> Bool {
        run(
            Content(
                title: String(
                    localized: "Quit while items are still being freed?",
                    comment: "Alert title: quitting with work in flight"),
                body: String(
                    localized: "Items still in progress stop where they are. Some may already be partly freed.",
                    comment: "Alert body: quitting with work in flight; must not claim nothing changed"),
                confirmTitle: String(localized: "Quit", comment: "Alert button: quit anyway")),
            returnConfirms: false)
    }

    private static func run(_ content: Content, returnConfirms: Bool) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = content.title
        alert.informativeText = content.body
        let confirmButton = alert.addButton(withTitle: content.confirmTitle)
        let cancelButton = alert.addButton(withTitle: String(localized: "Cancel", comment: "Alert button: cancel"))
        cancelButton.keyEquivalent = "\u{1b}"
        if !returnConfirms {
            confirmButton.keyEquivalent = ""
        }
        return alert.runModal() == .alertFirstButtonReturn
    }
}
