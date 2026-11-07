import Foundation
import Testing

@testable import Smuggler

@Suite("ServiceTokenStore")
struct ServiceTokenStoreTests {
    let sandbox = TestSandbox()

    private var store: ServiceTokenStore { ServiceTokenStore(containerURL: sandbox.root) }
    private var tokensDirectory: URL { sandbox.root.appending(path: "ServiceTokens") }

    @Test("A freshly issued token validates exactly once, a replay is rejected")
    func replayedTokenFails() throws {
        let token = try #require(store.issueToken())
        #expect(store.consumeToken(token) == true)
        #expect(store.consumeToken(token) == false)
    }

    @Test("A stale token is rejected")
    func staleTokenFails() throws {
        let token = try #require(store.issueToken())
        let file = tokensDirectory.appending(path: token)
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSinceNow: -(ServiceTokenStore.maxAge + 60))],
            ofItemAtPath: file.path(percentEncoded: false)
        )

        #expect(store.consumeToken(token) == false)
    }

    @Test("A token aged just under the max age is still honored")
    func tokenInsideMaxAgeValidates() throws {
        let token = try #require(store.issueToken())
        let file = tokensDirectory.appending(path: token)
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSinceNow: -(ServiceTokenStore.maxAge - 10))],
            ofItemAtPath: file.path(percentEncoded: false)
        )

        #expect(store.consumeToken(token) == true)
    }
}
