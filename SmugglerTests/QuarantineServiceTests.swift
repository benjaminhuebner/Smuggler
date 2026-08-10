import Foundation
import Testing

@testable import Smuggler

@Suite("QuarantineService")
struct QuarantineServiceTests {
    let service = QuarantineService()

    // MARK: - Helpers

    private func makeTempFile(withQuarantine: Bool = false) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try "test".write(to: url, atomically: true, encoding: .utf8)
        if withQuarantine {
            setQuarantine(on: url)
        }
        return url
    }

    private func makeTempDirectory(fileCount: Int, withQuarantine: Bool = false) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for _ in 0..<fileCount {
            let file = dir.appending(path: UUID().uuidString)
            try "test".write(to: file, atomically: true, encoding: .utf8)
            if withQuarantine {
                setQuarantine(on: file)
            }
        }
        return dir
    }

    @Test("An undescendable subfolder is reported as a skipped location, not a failed file")
    func unreadableSubfolderIsReportedAsSkipped() throws {
        let root = try makeTempDirectory(fileCount: 1, withQuarantine: true)
        let locked = root.appending(path: "locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let lockedPath = locked.path(percentEncoded: false)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lockedPath)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedPath)

        let result = try service.removeQuarantineRecursively(root)

        #expect(result.cleaned == 1)
        // The locked folder fails twice over: once as an item of its own, once as
        // a subtree the walk could not enter. Only the latter is a skip.
        #expect(result.errors.count(where: { $0.error.isSkippedDirectory }) == 1)
    }

    private func setQuarantine(on url: URL) {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            let value = "0001;00000000;Test;"
            let result = value.withCString { cValue in
                setxattr(path, "com.apple.quarantine", cValue, strlen(cValue), 0, 0)
            }
            assert(result == 0, "setxattr failed with errno \(errno)")
        }
    }

    // MARK: - hasQuarantine

    @Test("Detects quarantine attribute on quarantined file")
    func detectsQuarantine() throws {
        let url = try makeTempFile(withQuarantine: true)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(service.hasQuarantine(url) == true)
    }

    @Test("Returns false for clean file")
    func returnsFalseForCleanFile() throws {
        let url = try makeTempFile(withQuarantine: false)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(service.hasQuarantine(url) == false)
    }

    @Test("Returns false for non-existent file")
    func returnsFalseForNonExistentFile() {
        let url = URL(filePath: "/tmp/smuggler-no-such-file-\(UUID().uuidString)")
        #expect(service.hasQuarantine(url) == false)
    }

    // MARK: - removeQuarantine

    @Test("Removes quarantine attribute and reports it was present")
    func removesQuarantine() throws {
        let url = try makeTempFile(withQuarantine: true)
        defer { try? FileManager.default.removeItem(at: url) }

        let removed = try service.removeQuarantine(url)

        #expect(removed == true)
        #expect(service.hasQuarantine(url) == false)
    }

    @Test("Removing from a clean file does not throw and reports nothing removed")
    func removingFromCleanFileReportsNothingRemoved() throws {
        let url = try makeTempFile(withQuarantine: false)
        defer { try? FileManager.default.removeItem(at: url) }

        let removed = try service.removeQuarantine(url)

        #expect(removed == false)
    }

    @Test("Throws fileNotFound for non-existent file")
    func throwsForNonExistentFile() {
        let url = URL(filePath: "/tmp/smuggler-no-such-file-\(UUID().uuidString)")

        #expect(throws: QuarantineError.fileNotFound(url)) {
            try service.removeQuarantine(url)
        }
    }

    // MARK: - removeQuarantineRecursively

    @Test("Removes quarantine from all files in directory")
    func removesQuarantineRecursively() throws {
        let dir = try makeTempDirectory(fileCount: 3, withQuarantine: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = try service.removeQuarantineRecursively(dir)

        // 1 dir (no quarantine) + 3 quarantined files
        #expect(result.processed == 4)
        #expect(result.cleaned == 3)
        #expect(result.errors.isEmpty)
    }

    @Test("Single quarantined file processed recursively")
    func processesSingleFile() throws {
        let url = try makeTempFile(withQuarantine: true)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try service.removeQuarantineRecursively(url)

        #expect(result.processed == 1)
        #expect(result.cleaned == 1)
        #expect(result.errors.isEmpty)
        #expect(service.hasQuarantine(url) == false)
    }

    @Test("Throws fileNotFound for non-existent path")
    func throwsFileNotFoundForMissingDirectory() {
        let url = URL(filePath: "/tmp/smuggler-no-such-dir-\(UUID().uuidString)")

        #expect(throws: QuarantineError.fileNotFound(url)) {
            _ = try service.removeQuarantineRecursively(url)
        }
    }

    @Test("Throws invalidURL for non-file URL")
    func throwsInvalidURLForNonFileURL() throws {
        let url = try #require(URL(string: "https://example.com"))

        #expect(throws: QuarantineError.invalidURL(url)) {
            _ = try service.removeQuarantineRecursively(url)
        }
    }

    @Test("Rejects symlink as direct input")
    func rejectsSymlinkAsDirectInput() throws {
        let target = try makeTempFile(withQuarantine: true)
        let link = FileManager.default.temporaryDirectory
            .appending(path: "smuggler-symlink-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: target)
        }

        // Its own case, not invalidURL: the link exists and can be revealed, and
        // the way out is to drag in what it points at.
        #expect(throws: QuarantineError.symbolicLink(link)) {
            _ = try service.removeQuarantineRecursively(link)
        }
        #expect(!QuarantineError.symbolicLink(link).refersToMissingFile)
    }

    @Test("Descends into subdirectories and skips symlinks instead of following them")
    func descendsIntoSubdirectoriesAndSkipsSymlinks() throws {
        let dir = try makeTempDirectory(fileCount: 1, withQuarantine: true)
        let target = try makeTempFile(withQuarantine: true)
        let sub = dir.appending(path: "sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let nested = sub.appending(path: "nested")
        try "test".write(to: nested, atomically: true, encoding: .utf8)
        setQuarantine(on: nested)
        // removexattr follows symlinks, so a link inside the tree must be
        // skipped — otherwise it would strip quarantine from its target.
        try FileManager.default.createSymbolicLink(
            at: sub.appending(path: "link"), withDestinationURL: target)
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: target)
        }

        let result = try service.removeQuarantineRecursively(dir)

        #expect(result.errors.isEmpty)
        #expect(result.cleaned == 2)  // top-level file + nested file; the link is skipped
        #expect(service.hasQuarantine(nested) == false)
        #expect(service.hasQuarantine(target) == true)
    }

    @Test("Processes empty directory without errors")
    func processesEmptyDirectory() throws {
        let dir = try makeTempDirectory(fileCount: 0)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = try service.removeQuarantineRecursively(dir)

        #expect(result.processed == 1)  // only the directory itself
        #expect(result.cleaned == 0)
        #expect(result.errors.isEmpty)
    }

    @Test("Permission failure on the input maps to permissionDenied, not fileNotFound")
    func permissionFailureMapsToPermissionDenied() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Built by hand, not taken from a directory listing — listing APIs cache
        // resource values on the returned URLs, which would mask the stat failure.
        let file = dir.appending(path: "unreachable")
        try "test".write(to: file, atomically: true, encoding: .utf8)
        let dirPath = dir.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dirPath)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dirPath)
            try? FileManager.default.removeItem(at: dir)
        }

        #expect(throws: QuarantineError.permissionDenied(file)) {
            _ = try service.removeQuarantineRecursively(file)
        }
    }

    @Test("Removes quarantine from directory that itself has the attribute")
    func removesQuarantineFromDirectoryItself() throws {
        let dir = try makeTempDirectory(fileCount: 2, withQuarantine: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        setQuarantine(on: dir)

        let result = try service.removeQuarantineRecursively(dir)

        #expect(result.cleaned == 3)  // dir + 2 files
        #expect(result.errors.isEmpty)
        #expect(service.hasQuarantine(dir) == false)
    }
}
