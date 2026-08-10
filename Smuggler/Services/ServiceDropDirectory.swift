//
//  ServiceDropDirectory.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 10.08.26.
//

import Foundation

// Both service stores hand single-use files to the app through the shared group
// container. A flow that crashed or was abandoned leaves its file behind, so the
// same reclaim rule has to run for both — and it deletes, which is never copied.
nonisolated enum ServiceDropDirectory {
    static func pruneStaleFiles(in directory: URL, olderThan maxAge: TimeInterval) {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.creationDateKey])
        else { return }
        let now = Date()
        for file in files {
            let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            if let created, now.timeIntervalSince(created) > maxAge {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
