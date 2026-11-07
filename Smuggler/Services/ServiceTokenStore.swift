import Foundation

// The Finder extension drops a one-time token file into the shared group
// container; the app consumes (deletes) it on arrival. Replayed, invented,
// or stale tokens fall back to the confirmation dialog — never fail-open.
nonisolated struct ServiceTokenStore: Sendable {
    static let appGroupID = "F6A5PBNZF2.group.com.benjaminhuebner.Smuggler"

    // Must survive a slow cold launch (Gatekeeper scan, app translocation)
    // between issue and consumption. Tokens are single-use, so this only
    // bounds how long a leaked-but-unconsumed token stays valid.
    static let maxAge: TimeInterval = 60

    private let store: SingleUseFileStore

    init(
        containerURL: URL? = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ServiceTokenStore.appGroupID)
    ) {
        store = SingleUseFileStore(containerURL: containerURL, subdirectory: "ServiceTokens", maxAge: Self.maxAge)
    }

    func issueToken() -> String? {
        store.issue(Data())
    }

    func consumeToken(_ token: String) -> Bool {
        store.consume(token) != nil
    }
}
