//
//  SingleUseFileStore.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 05.09.26.
//

import Foundation

// The UUID name doubles as the traversal guard for a query parameter, the
// delete comes before the trust decision so nothing stays presentable, and a
// failed delete refuses the file rather than risk serving it twice.
nonisolated struct SingleUseFileStore: Sendable {
    private let directory: URL?
    private let maxAge: TimeInterval

    // Creation dates follow the wall clock, which can be set back, so a file dated
    // ahead of now fits no window this store can vouch for. The slack covers a
    // container on a volume whose timestamps come from another machine's clock.
    private static let clockSlack: TimeInterval = 2

    init(containerURL: URL?, subdirectory: String, maxAge: TimeInterval) {
        directory = containerURL?.appending(path: subdirectory, directoryHint: .isDirectory)
        self.maxAge = maxAge
    }

    func issue(_ payload: Data) -> String? {
        guard let directory else { return nil }
        let name = UUID().uuidString
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            pruneStaleFiles(in: directory)
            try payload.write(to: directory.appending(path: name))
        } catch {
            return nil
        }
        return name
    }

    func consume(_ name: String) -> Data? {
        guard let directory, UUID(uuidString: name) != nil else { return nil }
        // Pruned here too, not only on issue: a flow that died before this point
        // is otherwise reclaimed only by the next Finder-extension click.
        pruneStaleFiles(in: directory)
        let file = directory.appending(path: name)
        guard
            let issuedAt = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
            let payload = try? Data(contentsOf: file)
        else {
            // Unreadable is unusable, so it must not survive the failed read.
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        guard (try? FileManager.default.removeItem(at: file)) != nil else { return nil }
        guard isWithinWindow(issuedAt, now: Date()) else { return nil }
        return payload
    }

    private func isWithinWindow(_ created: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(created)
        return age >= -Self.clockSlack && age <= maxAge
    }

    private func pruneStaleFiles(in directory: URL) {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.creationDateKey])
        else { return }
        let now = Date()
        for file in files {
            let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            if let created, !isWithinWindow(created, now: now) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
