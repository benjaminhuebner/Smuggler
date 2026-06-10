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

    @Test("Removes quarantine attribute")
    func removesQuarantine() throws {
        let url = try makeTempFile(withQuarantine: true)
        defer { try? FileManager.default.removeItem(at: url) }

        try service.removeQuarantine(url)

        #expect(service.hasQuarantine(url) == false)
    }

    @Test("Does not throw when removing quarantine from clean file")
    func doesNotThrowForCleanFile() throws {
        let url = try makeTempFile(withQuarantine: false)
        defer { try? FileManager.default.removeItem(at: url) }

        try service.removeQuarantine(url)
    }

    @Test("Throws fileNotFound for non-existent file")
    func throwsForNonExistentFile() {
        let url = URL(filePath: "/tmp/smuggler-no-such-file-\(UUID().uuidString)")

        #expect(throws: QuarantineError.self) {
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

        #expect(throws: QuarantineError.self) {
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

        #expect(throws: QuarantineError.self) {
            _ = try service.removeQuarantineRecursively(link)
        }
    }

    @Test("Returns false when removing quarantine from clean file")
    func returnsFalseWhenRemovingFromCleanFile() throws {
        let url = try makeTempFile(withQuarantine: false)
        defer { try? FileManager.default.removeItem(at: url) }

        let removed = try service.removeQuarantine(url)
        #expect(removed == false)
    }

    @Test("Returns true when removing quarantine from quarantined file")
    func returnsTrueWhenRemovingFromQuarantinedFile() throws {
        let url = try makeTempFile(withQuarantine: true)
        defer { try? FileManager.default.removeItem(at: url) }

        let removed = try service.removeQuarantine(url)
        #expect(removed == true)
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
