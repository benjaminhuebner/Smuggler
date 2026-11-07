//
//  AppModel+ServiceMode.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 09.08.26.
//

import Foundation

extension AppModel {
    // MARK: - Incoming Requests

    @discardableResult
    func handleIncomingRequest(_ request: IncomingRequest, isColdLaunch: Bool) -> Task<Void, Never> {
        // The token is consumed on arrival: queued behind an open confirm
        // dialog, a valid 60s Finder-extension token would otherwise expire
        // and demote the user's own action to an untrusted request.
        let trusted = request.token.map { tokenStore.consumeToken($0) } ?? false
        return chainRequest(request, trusted: trusted, isColdLaunch: isColdLaunch)
    }

    // Trusted without a token: macOS itself asks the user before the restricted service
    // runs (NSRestricted), even when Finder is the caller.
    @discardableResult
    func handleServicesRequest(_ urls: [URL], isColdLaunch: Bool) -> Task<Void, Never> {
        chainRequest(
            IncomingRequest(urls: urls, action: .remove, quitAfter: true, token: nil),
            trusted: true,
            isColdLaunch: isColdLaunch
        )
    }

    private func chainRequest(_ request: IncomingRequest, trusted: Bool, isColdLaunch: Bool) -> Task<Void, Never> {
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
            let requested = await IncomingRequest.requestedURLs(for: request, batchStore: batchStore)
            await previous?.value
            guard !Task.isCancelled else { return }
            guard case .urls(let requestedURLs) = requested else {
                // The paths never arrived: no row can fail and the window has
                // nothing to show, so the notification is the only trace.
                await handlers.notifyFailure()
                quitIfStillCurrent(quitAfter: quitAfter, requestID: requestID)
                return
            }
            let (urls, removableURLs) = await IncomingRequest.resolvedURLs(from: requestedURLs)
            guard !Task.isCancelled else { return }
            guard !urls.isEmpty else {
                // Every path named was gone: no row can say so, and a headless
                // launch still honors its quit contract.
                if !requestedURLs.isEmpty { await handlers.notifyFailure() }
                quitIfStillCurrent(quitAfter: quitAfter, requestID: requestID)
                return
            }
            // A smuggler:// URL can come from any process and both actions strip
            // quarantine, so an untrusted request needs human approval. Blocked paths
            // stay out of the dialog: the pipeline refuses them anyway.
            guard trusted || removableURLs.isEmpty || handlers.confirm(removableURLs, .remove) else {
                await quitAfterDecline(quitAfter: quitAfter, requestID: requestID)
                return
            }
            handleServiceURLs(urls, action: request.action, quitAfter: quitAfter)
        }
        liveRequestTasks[requestID] = task
        incomingRequestTask = task
        return task
    }

    // A request sent while the dialog was up may only be delivered once it closes;
    // it gets the same chance to take the session over as a finished batch does.
    private func quitAfterDecline(quitAfter: Bool, requestID: Int) async {
        guard quitAfter, requestID == lastRequestID else { return }
        try? await Task.sleep(for: terminationGrace)
        guard !Task.isCancelled else { return }
        quitIfStillCurrent(quitAfter: quitAfter, requestID: requestID)
    }

    // Only the newest request may end the session, and work dropped into the window
    // meanwhile keeps it: every exit here sits after a suspension, and whatever
    // arrived during it would die with the app.
    private func quitIfStillCurrent(quitAfter: Bool, requestID: Int) {
        guard quitAfter, requestID == lastRequestID else { return }
        if isProcessing {
            handlers.sessionStays()
        } else {
            handlers.terminate()
        }
    }

    // A URL the parser rejected still carries its sender's quit contract: a cold
    // launch that exists only to serve it must not leave an orphan window behind.
    func rejectIncomingRequest(_ url: URL, isColdLaunch: Bool) {
        guard isColdLaunch, IncomingRequest.requestsQuit(url) else { return }
        handlers.terminate()
    }

    // MARK: - Service Mode

    func handleServiceURLs(_ urls: [URL], action: ServiceAction, quitAfter: Bool) {
        // enqueue answers for every requested URL, in-flight rows included, so
        // the open and notify steps don't silently skip an adopted item.
        let entryIDs = Set(enqueue(urls: urls).map(\.id))

        if quitAfter {
            // A superseded batch must not fire its termination or notification.
            serviceMode?.cancel()
            let coordinator = ServiceModeCoordinator(entryIDs: entryIDs, action: action)
            coordinator.authorizationTask = Task { [authorize = handlers.authorize] in await authorize() }
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
            // Unconditional: a cold request that never asked to quit keeps its window
            // too, and no later step would hand that session back.
            handlers.sessionStays()
            serviceHandlerTask = Task { [weak self] in
                guard let self else { return }
                await process(urls: urls)
                guard !Task.isCancelled, action == .open else { return }
                confirmAndOpenSuccessful(in: items.filter { entryIDs.contains($0.id) })
            }
        }
    }

    // The confirmation's nested modal run loop and the notify suspension are
    // supersession points: a second batch can replace `serviceMode` meanwhile,
    // so every later step must re-check identity before clearing or terminating.
    private func finishServiceMode(_ coordinator: ServiceModeCoordinator) async {
        let batchItems = items.filter { coordinator.entryIDs.contains($0.id) }
        // Offered whatever else failed, as a warm batch is: the failures stay in the
        // window and the notification, and the dialog still gates every launch.
        if coordinator.action == .open {
            confirmAndOpenSuccessful(in: batchItems)
        }

        // A subtree the walk could not descend into is reported in the notification
        // but leaves nothing to inspect here, so it must not hold the window open.
        if batchItems.contains(where: \.status.hasActionableErrors) {
            // Tell the user why the window lingers instead of failing silently.
            await handlers.notify(batchItems)
            if serviceMode === coordinator {
                serviceMode = nil
                handlers.sessionStays()
            }
            return
        }

        if coordinator.action != .open {
            // Posted before the termination grace: a warm takeover cancelling
            // the pending quit must not drop the batch's result notification.
            await handlers.notify(batchItems)
        }

        guard serviceMode === coordinator else { return }
        coordinator.terminationTask = Task { [weak self, grace = terminationGrace] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled, let self, serviceMode === coordinator else { return }
            // Whatever arrived meanwhile owns the session: a request still resolving
            // or asking, or work started outside the request chain.
            guard !hasRequestsInFlight, !isProcessing else {
                serviceMode = nil
                handlers.sessionStays()
                return
            }
            handlers.terminate()
        }
    }

    // MARK: - Open (confirmed)

    // Removing the quarantine attribute strips Gatekeeper's launch check, so a
    // human must approve before we open anything on the request's behalf.
    private func confirmAndOpenSuccessful(in batchItems: [FileItem]) {
        let urls = batchItems.filter(\.status.isSuccessful).map(\.url)
        guard !urls.isEmpty else { return }
        guard handlers.confirm(urls, .open) else { return }
        handlers.open(urls)
    }
}
