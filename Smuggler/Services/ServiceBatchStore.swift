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
    static let maxAge: TimeInterval = 60

    private let store: SingleUseFileStore

    init(
        containerURL: URL? = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ServiceTokenStore.appGroupID)
    ) {
        store = SingleUseFileStore(containerURL: containerURL, subdirectory: "ServiceBatches", maxAge: Self.maxAge)
    }

    func write(paths: [String]) -> String? {
        guard !paths.isEmpty, let payload = try? JSONEncoder().encode(paths) else { return nil }
        return store.issue(payload)
    }

    func consume(_ name: String) -> [String] {
        guard let payload = store.consume(name) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: payload)) ?? []
    }
}
