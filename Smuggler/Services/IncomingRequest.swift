//
//  IncomingRequest.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 09.08.26.
//

import Foundation
import os

nonisolated private let logger = Logger(subsystem: "com.benjaminhuebner.Smuggler", category: "IncomingRequest")

nonisolated enum ServiceAction: String, Sendable {
    case open
    case remove
}

// A handover that could not be read is its own outcome: served as an empty
// selection it would be indistinguishable from a request with nothing to do,
// and a headless session would quit without telling anyone.
nonisolated enum RequestedURLs: Sendable {
    case urls([URL])
    case batchUnavailable
}

nonisolated struct IncomingRequest: Sendable {
    let urls: [URL]
    let action: ServiceAction
    let quitAfter: Bool
    let token: String?
    // Set when the sender handed its paths over through the shared container
    // instead of the URL; `urls` is then empty until the batch is read off-main.
    var batchName: String?
}

nonisolated extension IncomingRequest {
    init?(url: URL) {
        // Launch Services routes schemes and hosts case-insensitively; the
        // parser must accept the same spellings or a valid click does nothing.
        guard url.scheme?.lowercased() == "smuggler", url.host?.lowercased() == "process" else {
            logger.warning("Received unknown URL: \(url, privacy: .private)")
            return nil
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        // Parsing stays free of filesystem calls: it runs on the main actor as
        // the request arrives, and the directory form is resolved off-main by
        // the caller instead.
        let urls = Self.fileURLs(fromPaths: queryItems.filter { $0.name == "path" }.compactMap(\.value))
        // A batch stands in for the paths when the selection outgrew the URL.
        let batchName = queryItems.first(where: { $0.name == "batch" })?.value
        guard !urls.isEmpty || batchName != nil else {
            logger.warning("URL missing usable path parameter(s): \(url, privacy: .private)")
            return nil
        }

        let rawAction = queryItems.first(where: { $0.name == "action" })?.value ?? ServiceAction.open.rawValue
        guard let action = ServiceAction(rawValue: rawAction) else {
            logger.warning("Invalid action in URL: \(rawAction)")
            return nil
        }

        self.init(
            urls: urls,
            action: action,
            quitAfter: Self.requestsQuit(queryItems),
            token: queryItems.first(where: { $0.name == "token" })?.value,
            batchName: batchName
        )
    }

    // Reading the batch is a file read, so it stays off the main actor alongside
    // the existence filter rather than happening in the parser.
    @concurrent
    static func requestedURLs(
        for request: IncomingRequest,
        batchStore: ServiceBatchStore? = nil
    ) async -> RequestedURLs {
        guard let batchName = request.batchName else { return .urls(request.urls) }
        // Built here rather than as a default argument, which Swift would evaluate
        // in the caller's main-actor context — the group-container lookup is a
        // synchronous round trip that can materialize the directory.
        let store = batchStore ?? ServiceBatchStore()
        let urls = Self.fileURLs(fromPaths: store.consume(batchName))
        // A batch always carries at least one path, so nothing here means the
        // handover failed — that is a different outcome from "the user picked
        // nothing" and must not be served as an empty selection.
        guard !urls.isEmpty else {
            logger.error("Batch \(batchName, privacy: .public) yielded no usable paths")
            return .batchUnavailable
        }
        return .urls(urls)
    }

    // Absolute paths only: URL(filePath:) resolves "" and relative values
    // against the working directory — "/" for a LaunchServices launch — so
    // a degenerate request would silently target the boot volume.
    private static func fileURLs(fromPaths paths: [String]) -> [URL] {
        paths.filter { $0.hasPrefix("/") }
            .map { URL(filePath: $0, directoryHint: .inferFromPath).standardizedFileURL }
    }

    // Readable without a successful parse: a rejected URL still states whether its
    // sender expects the app to quit afterwards.
    static func requestsQuit(_ url: URL) -> Bool {
        requestsQuit(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
    }

    static func requestsQuit(_ queryItems: [URLQueryItem]) -> Bool {
        let raw = queryItems.first(where: { $0.name == "quitAfter" })?.value?.lowercased()
        return raw == "true" || raw == "1"
    }

    // Blocked paths skip the existence filter — a refusal must surface as a row,
    // and symlinks resolve so an alias into a blocked tree is refused, not dropped.
    // The partition is returned so the approval dialog needn't re-resolve on-main.
    @concurrent
    static func resolvedURLs(from urls: [URL]) async -> (urls: [URL], removableURLs: [URL]) {
        var kept: [URL] = []
        var removable: [URL] = []
        for url in urls {
            // Resolved here, not at parse time: it costs a stat per path and the
            // parser runs on the main actor. One stat answers both questions —
            // dedup needs the same URL form a drop or an open panel would produce.
            let path = url.path(percentEncoded: false)
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            let resolved = URL(
                filePath: path,
                directoryHint: isDirectory.boolValue ? .isDirectory : .notDirectory
            ).standardizedFileURL
            if QuarantineService.isBlockedPath(resolved) {
                kept.append(resolved)
            } else if exists {
                kept.append(resolved)
                removable.append(resolved)
            }
        }
        return (kept, removable)
    }
}
