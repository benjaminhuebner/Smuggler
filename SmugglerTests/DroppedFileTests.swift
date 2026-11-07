//
//  DroppedFileTests.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import CoreTransferable
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import Smuggler

@Suite("DroppedFile")
struct DroppedFileTests {
    private let sandbox = TestSandbox()

    private func drop(_ string: String) async throws -> URL {
        try await DroppedFile(importing: Data(string.utf8), contentType: .fileURL).url
    }

    private func fileReference(to url: URL) throws -> String {
        let reference = try #require(CFURLCreateFileReferenceURL(nil, url as CFURL, nil)?.takeRetainedValue())
        return CFURLGetString(reference) as String
    }

    @Test("Only a file URL can activate the drop target, never a web link")
    func importsFileURLsAlone() {
        #expect(DroppedFile(url: URL(filePath: "/tmp/x")).importedContentTypes() == [.fileURL])
    }

    @Test("A path URL arrives as that path")
    func pathURLPassesThrough() async throws {
        let url = try await drop("file:///tmp/Some%20Download.dmg")
        #expect(url.path(percentEncoded: false) == "/tmp/Some Download.dmg")
    }

    @Test("A folder keeps its trailing slash, as the open panel hands it over")
    func folderKeepsDirectoryForm() async throws {
        let url = try await drop("file:///tmp/Folder/")
        #expect(url == URL(filePath: "/tmp/Folder/", directoryHint: .isDirectory))
    }

    @Test("A web link is refused", arguments: ["https://example.com/app.dmg", "http://example.com/"])
    func webLinkIsRefused(link: String) async {
        await #expect(throws: (any Error).self) { try await drop(link) }
    }

    @Test("A Finder file reference resolves to the item's own path, not a copy")
    func fileReferenceResolvesToPath() async throws {
        let file = try sandbox.file("Installer.pkg", in: sandbox.canonicalRoot())
        let reference = try fileReference(to: file)
        try #require(reference.hasPrefix("file:///.file/id="))

        let url = try await drop(reference)
        #expect(!(url as NSURL).isFileReferenceURL())
        #expect(url.path(percentEncoded: false) == file.path(percentEncoded: false))
    }

    @Test("A file reference whose item is gone is refused")
    func danglingReferenceIsRefused() async throws {
        let file = try sandbox.file(in: sandbox.canonicalRoot())
        let reference = try fileReference(to: file)
        try FileManager.default.removeItem(at: file)

        await #expect(throws: (any Error).self) { try await drop(reference) }
    }
}
