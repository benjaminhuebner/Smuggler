//
//  TestSandbox.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import Foundation

// A class for its deinit: Swift Testing builds a suite instance per test, so a
// sandbox held by the suite cleans up after every test, failed ones included.
nonisolated final class TestSandbox {
    let root = FileManager.default.temporaryDirectory.appending(path: "SmugglerTests-\(UUID().uuidString)")
    private var lockedItems: [URL] = []

    // Children keep the inferred directory hint: tests depend on the plain path
    // form a Finder or URL-scheme sender hands over, without a trailing slash.
    func url(_ name: String = UUID().uuidString) -> URL {
        root.appending(path: name)
    }

    // The kernel's spelling of `root`: /var is a link to /private/var, and the
    // service's syscall refuses any path that runs through a link.
    func canonicalRoot() throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let resolved: (path: String?, code: Int32) = root.withUnsafeFileSystemRepresentation { path in
            guard let path, let real = realpath(path, nil) else { return (nil, errno) }
            defer { free(real) }
            return (FileManager.default.string(withFileSystemRepresentation: real, length: strlen(real)), 0)
        }
        guard let path = resolved.path else { throw POSIXError(POSIXErrorCode(rawValue: resolved.code) ?? .EIO) }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    @discardableResult
    func file(_ name: String = UUID().uuidString, in parent: URL? = nil, quarantined: Bool = false) throws -> URL {
        let url = (parent ?? root).appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test".utf8).write(to: url)
        if quarantined {
            try setQuarantine(on: url)
        }
        return url
    }

    func directory(
        _ name: String = UUID().uuidString, in parent: URL? = nil, files: Int = 0, quarantined: Bool = false
    ) throws -> URL {
        let url = (parent ?? root).appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for _ in 0..<files {
            try file(in: url, quarantined: quarantined)
        }
        return url
    }

    func symlink(_ name: String = UUID().uuidString, in parent: URL? = nil, to destination: URL) throws -> URL {
        let url = (parent ?? root).appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
        return url
    }

    func lock(_ url: URL, permissions: Int16 = 0o000) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions], ofItemAtPath: url.path(percentEncoded: false))
        lockedItems.append(url)
    }

    deinit {
        // Newest first: a folder is locked after its contents, so it has to
        // open up again before they can.
        for url in lockedItems.reversed() {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: url.path(percentEncoded: false))
        }
        try? FileManager.default.removeItem(at: root)
    }
}
