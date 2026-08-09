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

nonisolated struct IncomingRequest: Sendable {
    let urls: [URL]
    let action: ServiceAction
    let quitAfter: Bool
    let token: String?
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

        // Absolute paths only: URL(filePath:) resolves "" and relative values
        // against the working directory — "/" for a LaunchServices launch — so
        // a degenerate request would silently target the boot volume.
        let paths = queryItems.filter { $0.name == "path" }
            .compactMap(\.value)
            .filter { $0.hasPrefix("/") }
        guard !paths.isEmpty else {
            logger.warning("URL missing usable path parameter(s): \(url, privacy: .private)")
            return nil
        }

        let rawAction = queryItems.first(where: { $0.name == "action" })?.value ?? ServiceAction.open.rawValue
        guard let action = ServiceAction(rawValue: rawAction) else {
            logger.warning("Invalid action in URL: \(rawAction)")
            return nil
        }

        self.init(
            // Parsing stays free of filesystem calls: it runs on the main actor as
            // the request arrives, and the directory form is resolved off-main by
            // the caller instead.
            urls: paths.map { URL(filePath: $0, directoryHint: .inferFromPath).standardizedFileURL },
            action: action,
            quitAfter: Self.requestsQuit(queryItems),
            token: queryItems.first(where: { $0.name == "token" })?.value
        )
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
