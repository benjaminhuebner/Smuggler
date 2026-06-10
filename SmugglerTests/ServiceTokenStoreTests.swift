import Foundation
import Testing

@testable import Smuggler

@Suite("ServiceTokenStore")
struct ServiceTokenStoreTests {
    private func makeStore() throws -> (store: ServiceTokenStore, container: URL) {
        let container = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        return (ServiceTokenStore(containerURL: container), container)
    }

    @Test("A freshly issued token validates exactly once")
    func validTokenConsumes() throws {
        let (store, container) = try makeStore()
        defer { try? FileManager.default.removeItem(at: container) }

        let token = try #require(store.issueToken())
        #expect(store.consumeToken(token) == true)
    }

    @Test("A replayed token is rejected")
    func replayedTokenFails() throws {
        let (store, container) = try makeStore()
        defer { try? FileManager.default.removeItem(at: container) }

        let token = try #require(store.issueToken())
        #expect(store.consumeToken(token) == true)
        #expect(store.consumeToken(token) == false)
    }

    @Test("A stale token is rejected")
    func staleTokenFails() throws {
        let (store, container) = try makeStore()
        defer { try? FileManager.default.removeItem(at: container) }

        let token = try #require(store.issueToken())
        let file = container.appending(path: "ServiceTokens").appending(path: token)
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSinceNow: -(ServiceTokenStore.defaultMaxAge + 60))],
            ofItemAtPath: file.path(percentEncoded: false)
        )

        #expect(store.consumeToken(token) == false)
    }

    @Test("A token that was never issued is rejected")
    func missingTokenFails() throws {
        let (store, container) = try makeStore()
        defer { try? FileManager.default.removeItem(at: container) }

        #expect(store.consumeToken(UUID().uuidString) == false)
    }

    @Test("Malformed tokens are rejected without touching the filesystem")
    func malformedTokenFails() throws {
        let (store, container) = try makeStore()
        defer { try? FileManager.default.removeItem(at: container) }

        #expect(store.consumeToken("not-a-uuid") == false)
        #expect(store.consumeToken("../../../etc/passwd") == false)
        #expect(store.consumeToken("") == false)
    }

    @Test("An unavailable group container fails safe")
    func unavailableContainerFailsSafe() {
        let store = ServiceTokenStore(containerURL: nil)

        #expect(store.issueToken() == nil)
        #expect(store.consumeToken(UUID().uuidString) == false)
    }
}
