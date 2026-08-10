//
//  AppModel+ServiceMode.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 09.08.26.
//

import AppKit
import Foundation

extension AppModel {
    // MARK: - URL Scheme Handling

    @discardableResult
    func handleIncomingRequest(_ request: IncomingRequest, isColdLaunch: Bool) -> Task<Void, Never> {
        // The token is consumed on arrival: queued behind an open confirm
        // dialog, a valid 60s Finder-extension token would otherwise expire
        // and demote the user's own action to an untrusted request.
        let trusted = request.token.map { tokenStore.consumeToken($0) } ?? false
        let quitAfter = request.quitAfter && isColdLaunch
        lastRequestID += 1
        let requestID = lastRequestID
        // Chained on the previous request: the existence filter hops off-main,
        // and supersession must follow arrival order, not filter latency.
        let task = Task { [previous = incomingRequestTask] in
            defer { liveRequestTasks.removeValue(forKey: requestID) }
            // Read before waiting on the queue ahead, for the same reason the
            // token is consumed on arrival: the batch expires 60s after the
            // extension wrote it, and a dialog ahead of us outlives that.
            let requested = await IncomingRequest.requestedURLs(for: request)
            await previous?.value
            guard !Task.isCancelled else { return }
            guard case .urls(let requestedURLs) = requested else {
                await reportUnreadableBatch(quitAfter: quitAfter, requestID: requestID)
                return
            }
            let (urls, removableURLs) = await IncomingRequest.resolvedURLs(from: requestedURLs)
            guard !Task.isCancelled else { return }
            guard !urls.isEmpty else {
                // A headless launch must honor its quit contract even when every
                // path was dropped.
                quitIfStillCurrent(quitAfter: quitAfter, requestID: requestID)
                return
            }
            handleURLRequest(
                urls: urls,
                removableURLs: removableURLs,
                action: request.action,
                quitAfter: quitAfter,
                trusted: trusted
            )
        }
        liveRequestTasks[requestID] = task
        incomingRequestTask = task
        return task
    }

    // The paths never arrived, so there is no row to fail and nothing to show in
    // the window; the notification is the only place this can surface.
    private func reportUnreadableBatch(quitAfter: Bool, requestID: Int) async {
        await notifyFailure()
        quitIfStillCurrent(quitAfter: quitAfter, requestID: requestID)
    }

    // Only the newest request may end the session. Every exit here sits after a
    // suspension, and a request that arrived meanwhile would die with the app
    // before it ran.
    private func quitIfStillCurrent(quitAfter: Bool, requestID: Int) {
        if quitAfter, requestID == lastRequestID { terminate() }
    }

    // A URL the parser rejected still carries its sender's quit contract: a cold
    // launch that exists only to serve it must not leave an orphan window behind.
    func rejectIncomingRequest(_ url: URL, isColdLaunch: Bool) {
        guard isColdLaunch, IncomingRequest.requestsQuit(url) else { return }
        terminate()
    }

    // A smuggler:// URL can come from any process and both actions strip quarantine,
    // so untrusted requests need human approval; a valid Finder-extension token skips
    // it. `removableURLs` excludes blocked paths — the pipeline refuses those anyway.
    func handleURLRequest(
        urls: [URL],
        removableURLs: [URL],
        action: ServiceAction,
        quitAfter: Bool,
        trusted: Bool
    ) {
        if !trusted, !removableURLs.isEmpty, !confirm(removableURLs, .remove) {
            if quitAfter { terminate() }
            return
        }
        handleServiceURLs(urls, action: action, quitAfter: quitAfter)
    }

    // MARK: - Service Mode

    func handleServiceURLs(_ urls: [URL], action: ServiceAction, quitAfter: Bool) {
        // enqueue answers for every requested URL, in-flight rows included, so
        // the open and notify steps don't silently skip an adopted item.
        let entryIDs = Set(enqueue(urls: urls).map(\.id))

        if quitAfter {
            // A superseded batch must not fire its termination or notification.
            serviceMode?.cancel()
            let coordinator = ServiceModeCoordinator(
                entryIDs: entryIDs,
                action: action,
                quitAfter: true
            )
            coordinator.authorizationTask = Task { [authorize] in await authorize() }
            serviceMode = coordinator

            coordinator.processingTask = Task { [weak self] in
                guard let self else { return }
                await process(urls: urls)
                guard !Task.isCancelled else { return }
                await finishServiceMode(coordinator)
            }
        } else {
            // A warm batch hands the session back to the window; a pending
            // headless quit from the previous batch must not kill the new work.
            if let pending = serviceMode {
                pending.terminationTask?.cancel()
                serviceMode = nil
            }
            serviceHandlerTask = Task { [weak self] in
                guard let self else { return }
                await process(urls: urls)
                guard !Task.isCancelled, action == .open else { return }
                confirmAndOpenSuccessful(in: items.filter { entryIDs.contains($0.id) })
            }
        }
    }

    // The notify suspension and the confirmation's nested modal run loop are
    // supersession points: a second batch can replace `serviceMode` meanwhile,
    // so every later step must re-check identity before clearing or terminating.
    private func finishServiceMode(_ coordinator: ServiceModeCoordinator) async {
        let batchItems = items.filter { coordinator.entryIDs.contains($0.id) }
        // A subtree the walk could not descend into is reported in the notification
        // but leaves nothing to inspect here, so it must not hold the window open.
        if batchItems.contains(where: \.status.hasActionableErrors) {
            // Tell the user why the window lingers instead of failing silently.
            await notify(batchItems)
            if serviceMode === coordinator {
                serviceMode = nil
            }
            return
        }

        if coordinator.action == .open {
            confirmAndOpenSuccessful(in: batchItems)
        } else {
            // Posted before the termination grace: a warm takeover cancelling
            // the pending quit must not drop the batch's result notification.
            await notify(batchItems)
        }

        guard serviceMode === coordinator else { return }
        coordinator.terminationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            if coordinator.quitAfter {
                self?.terminate()
            } else if self?.serviceMode === coordinator {
                self?.serviceMode = nil
            }
        }
    }

    // MARK: - Open (confirmed)

    // Removing the quarantine attribute strips Gatekeeper's launch check, so a
    // human must approve before we open anything on the request's behalf.
    private func confirmAndOpenSuccessful(in batchItems: [FileItem]) {
        let urls = batchItems.filter(\.status.isSuccessful).map(\.url)
        guard !urls.isEmpty else { return }
        guard confirm(urls, .open) else { return }
        open(urls)
    }

    static func confirmViaAlert(_ urls: [URL], kind: ConfirmKind) -> Bool {
        // The dialog may be triggered while another app is frontmost (URL scheme,
        // headless service launch) — without activation it would appear behind.
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        switch kind {
        case .open:
            alert.messageText =
                urls.count == 1
                ? String(
                    localized: "Open \(urls[0].lastPathComponent)?",
                    comment: "Confirm dialog title: open a single file after removing quarantine")
                : String(
                    localized: "Open \(urls.count) items?",
                    comment: "Confirm dialog title: open multiple files after removing quarantine")
            alert.informativeText = String(
                localized: "Quarantine was removed. Only open items you trust.",
                comment: "Confirm dialog body: warn before opening files after quarantine removal")
            alert.addButton(withTitle: String(localized: "Open", comment: "Confirm dialog: open button"))
        case .remove:
            alert.messageText =
                urls.count == 1
                ? String(
                    localized: "Remove quarantine from \(urls[0].lastPathComponent)?",
                    comment: "Confirm dialog title: external request to remove quarantine from one file")
                : String(
                    localized: "Remove quarantine from \(urls.count) items?",
                    comment: "Confirm dialog title: external request to remove quarantine from multiple files")
            let (shownURLs, hiddenCount) = urls.cappedPrefix(10)
            var pathList = shownURLs.map { $0.path(percentEncoded: false) }.joined(separator: "\n")
            if hiddenCount > 0 {
                pathList +=
                    "\n"
                    + String(
                        localized: "and \(hiddenCount) more",
                        comment: "Confirm dialog: suffix when the path list is truncated")
            }
            alert.informativeText = String(
                localized: """
                    Only continue if you started this yourself.

                    \(pathList)
                    """,
                comment: "Confirm dialog body: warn about an external quarantine-removal request")
            alert.addButton(
                withTitle: String(
                    localized: "Remove Quarantine",
                    comment: "Confirm dialog: remove quarantine button"))
        }
        let cancelButton = alert.addButton(
            withTitle: String(localized: "Cancel", comment: "Confirm dialog: cancel button"))
        // AppKit assigns Escape by matching the literal title "Cancel", which no
        // localized build carries — without this the dialog answers no key at all.
        cancelButton.keyEquivalent = "\u{1b}"

        if kind == .remove {
            // An external request can land mid-keystroke — a stray Return must not
            // approve stripping Gatekeeper's check. The confirmed open keeps its
            // default button; the user asked for that one.
            alert.buttons[0].keyEquivalent = ""
        }

        return alert.runModal() == .alertFirstButtonReturn
    }
}
