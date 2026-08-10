//
//  ServiceBatchStore.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 10.08.26.
//

import Foundation

// A batch grants no trust: it only carries paths, and what it yields passes the
// same blocked-path, symlink and confirmation gates a directly addressed request
// does. The token remains the only thing that proves a sender.
nonisolated struct ServiceBatchStore: Sendable {
    static let defaultMaxAge: TimeInterval = 60

    private let batchesDirectory: URL?

    init(
        containerURL: URL? = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ServiceTokenStore.appGroupID)
    ) {
        batchesDirectory = containerURL?.appending(path: "ServiceBatches", directoryHint: .isDirectory)
    }

    func write(paths: [String]) -> String? {
        guard let batchesDirectory, !paths.isEmpty else { return nil }
        let name = UUID().uuidString
        do {
            try FileManager.default.createDirectory(at: batchesDirectory, withIntermediateDirectories: true)
            ServiceDropDirectory.pruneStaleFiles(in: batchesDirectory, olderThan: Self.defaultMaxAge)
            try JSONEncoder().encode(paths).write(to: batchesDirectory.appending(path: name))
        } catch {
            return nil
        }
        return name
    }

    // Single-use. The payload has to be read before the delete, so the delete is
    // what the result hangs on: a batch that could not be removed stays
    // presentable and is therefore refused rather than served twice.
    func consume(_ name: String, maxAge: TimeInterval = ServiceBatchStore.defaultMaxAge) -> [String] {
        // The UUID parse also guards against path traversal via the query parameter.
        guard let batchesDirectory, UUID(uuidString: name) != nil else { return [] }
        // Also pruned here, not only on write: a batch whose flow died before this
        // point is otherwise reclaimed only by the next Finder-extension click.
        ServiceDropDirectory.pruneStaleFiles(in: batchesDirectory, olderThan: maxAge)
        let file = batchesDirectory.appending(path: name)
        guard
            let issuedAt = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
            let data = try? Data(contentsOf: file)
        else {
            // An unreadable batch is unusable, so its path list must not survive
            // the attempt just because the read failed before the delete.
            try? FileManager.default.removeItem(at: file)
            return []
        }
        guard (try? FileManager.default.removeItem(at: file)) != nil else { return [] }
        guard Date().timeIntervalSince(issuedAt) <= maxAge else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}
