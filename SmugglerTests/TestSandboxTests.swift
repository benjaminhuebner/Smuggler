//
//  TestSandboxTests.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import Foundation
import Testing

@Suite("TestSandbox")
struct TestSandboxTests {
    private func rootOfReleasedSandbox() throws -> URL {
        let sandbox = TestSandbox()
        let outer = try sandbox.directory(files: 1, quarantined: true)
        let inner = try sandbox.directory(in: outer, files: 1)
        try sandbox.lock(inner)
        try sandbox.lock(outer)
        try sandbox.lock(sandbox.file())
        return sandbox.root
    }

    @Test("Releasing the sandbox removes everything it made, locked folders included")
    func releaseRemovesRoot() throws {
        let root = try rootOfReleasedSandbox()

        #expect(!FileManager.default.fileExists(atPath: root.path(percentEncoded: false)))
    }
}
