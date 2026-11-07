//
//  ServiceRequestURL.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import Foundation
import os

// Both targets compile this file, so each process logs under its own bundle.
nonisolated private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.benjaminhuebner.Smuggler", category: "ServiceRequestURL")

nonisolated enum ServiceAction: String, Sendable {
    case open
    case remove
}

nonisolated enum ServiceRequestURL {
    static let scheme = "smuggler"
    static let host = "process"
    static let pathKey = "path"
    static let batchKey = "batch"
    static let actionKey = "action"
    static let quitAfterKey = "quitAfter"
    static let tokenKey = "token"

    // Past this length Launch Services can refuse the whole request, and a
    // refusal is invisible to the person who clicked.
    static let maxDirectLength = 6000

    // One query item per path, so no character in a file name can split it. A failed
    // batch write still sends the direct URL: a possible refusal beats a certain one.
    static func make(
        paths: [String], action: ServiceAction, quitAfter: Bool, token: String?, batchStore: ServiceBatchStore
    ) -> URL? {
        var trailingItems = [URLQueryItem(name: actionKey, value: action.rawValue)]
        if quitAfter {
            trailingItems.append(URLQueryItem(name: quitAfterKey, value: "true"))
        }
        if let token {
            trailingItems.append(URLQueryItem(name: tokenKey, value: token))
        }

        let direct = url(with: paths.map { URLQueryItem(name: pathKey, value: $0) } + trailingItems)
        if let direct, direct.absoluteString.utf8.count <= maxDirectLength {
            return direct
        }
        guard let batch = batchStore.write(paths: paths) else {
            logger.error("Could not write the path batch — falling back to a URL that may be refused")
            return direct
        }
        logger.info("Selection too large for a direct URL — handing \(paths.count) path(s) over as a batch")
        return url(with: [URLQueryItem(name: batchKey, value: batch)] + trailingItems)
    }

    private static func url(with queryItems: [URLQueryItem]) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = queryItems
        return components.url
    }
}
