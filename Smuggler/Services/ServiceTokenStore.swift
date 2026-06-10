import Foundation

// The Finder extension drops a one-time token file into the shared group
// container; the app consumes (deletes) it on arrival. Replayed, invented,
// or stale tokens fall back to the confirmation dialog — never fail-open.
nonisolated struct ServiceTokenStore: Sendable {
    static let appGroupID = "F6A5PBNZF2.group.com.benjaminhuebner.Smuggler"

    // Must survive a slow cold launch (Gatekeeper scan, app translocation)
    // between issue and consumption. Tokens are single-use, so this only
    // bounds how long a leaked-but-unconsumed token stays valid.
    static let defaultMaxAge: TimeInterval = 60

    private let tokensDirectory: URL?

    init(
        containerURL: URL? = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ServiceTokenStore.appGroupID)
    ) {
        tokensDirectory = containerURL?.appending(path: "ServiceTokens", directoryHint: .isDirectory)
    }

    func issueToken() -> String? {
        guard let tokensDirectory else { return nil }
        let token = UUID().uuidString
        do {
            try FileManager.default.createDirectory(at: tokensDirectory, withIntermediateDirectories: true)
            pruneStaleTokens(in: tokensDirectory)
            try Data().write(to: tokensDirectory.appending(path: token))
        } catch {
            return nil
        }
        return token
    }

    func consumeToken(_ token: String, maxAge: TimeInterval = ServiceTokenStore.defaultMaxAge) -> Bool {
        // The UUID parse also guards against path traversal via the query parameter.
        guard let tokensDirectory, UUID(uuidString: token) != nil else { return false }
        let file = tokensDirectory.appending(path: token)
        guard
            let issuedAt = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        else { return false }

        // Delete first so even a stale token cannot be presented twice.
        try? FileManager.default.removeItem(at: file)
        return Date().timeIntervalSince(issuedAt) <= maxAge
    }

    // Tokens from crashed or abandoned flows would otherwise accumulate forever.
    private func pruneStaleTokens(in directory: URL) {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.creationDateKey])
        else { return }
        let now = Date()
        for file in files {
            let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            if let created, now.timeIntervalSince(created) > Self.defaultMaxAge {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
