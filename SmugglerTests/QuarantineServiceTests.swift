import Foundation
import Testing

@testable import Smuggler

@Suite("QuarantineService")
struct QuarantineServiceTests {
    let service = QuarantineService()
    let sandbox = TestSandbox()

    @Test("An undescendable subfolder is reported as a skipped location, not a failed file")
    func unreadableSubfolderIsReportedAsSkipped() throws {
        let root = try sandbox.directory(files: 1, quarantined: true)
        let locked = try sandbox.directory("locked", in: root)
        try sandbox.lock(locked)

        let result = try service.removeQuarantineRecursively(root)

        #expect(result.cleaned == 1)
        // The locked folder fails twice over: once as an item of its own, once as
        // a subtree the walk could not enter. Only the latter is a skip.
        #expect(result.errors.count(where: { $0.error.isSkippedDirectory }) == 1)
    }

    // MARK: - removeQuarantine

    @Test("Removes quarantine attribute and reports it was present")
    func removesQuarantine() throws {
        let url = try sandbox.file(in: sandbox.canonicalRoot(), quarantined: true)

        let removed = try service.removeQuarantine(url)

        #expect(removed == true)
        #expect(hasQuarantine(url) == false)
    }

    @Test("Removing from a clean file does not throw and reports nothing removed")
    func removingFromCleanFileReportsNothingRemoved() throws {
        let url = try sandbox.file(in: sandbox.canonicalRoot())

        let removed = try service.removeQuarantine(url)

        #expect(removed == false)
    }

    @Test("Throws fileNotFound for non-existent file")
    func throwsForNonExistentFile() throws {
        let url = try sandbox.canonicalRoot().appending(path: UUID().uuidString)

        #expect(throws: QuarantineError.fileNotFound(url)) {
            try service.removeQuarantine(url)
        }
    }

    @Test("A link as the item is refused, and its target keeps quarantine")
    func removalRefusesLinkAsItem() throws {
        let target = try sandbox.file(in: sandbox.canonicalRoot(), quarantined: true)
        let link = try sandbox.symlink(in: sandbox.canonicalRoot(), to: target)

        #expect(throws: QuarantineError.symbolicLink(link)) {
            try service.removeQuarantine(link)
        }
        #expect(hasQuarantine(target))
    }

    @Test("A link anywhere in the path fails the removal instead of redirecting it")
    func removalRefusesLinkInPath() throws {
        let real = try sandbox.directory(in: sandbox.canonicalRoot())
        let inner = try sandbox.file("inner", in: real, quarantined: true)
        let alias = try sandbox.symlink(in: sandbox.canonicalRoot(), to: real)
        let throughAlias = alias.appending(path: "inner")

        #expect(throws: QuarantineError.symbolicLink(throughAlias)) {
            try service.removeQuarantine(throughAlias)
        }
        #expect(hasQuarantine(inner))
    }

    // MARK: - removeQuarantineRecursively

    @Test("Removes quarantine from all files in directory")
    func removesQuarantineRecursively() throws {
        let dir = try sandbox.directory(files: 3, quarantined: true)

        let result = try service.removeQuarantineRecursively(dir)

        // 1 dir (no quarantine) + 3 quarantined files
        #expect(result.processed == 4)
        #expect(result.cleaned == 3)
        #expect(result.errors.isEmpty)
    }

    @Test("Single quarantined file processed recursively")
    func processesSingleFile() throws {
        let url = try sandbox.file(quarantined: true)

        let result = try service.removeQuarantineRecursively(url)

        #expect(result.processed == 1)
        #expect(result.cleaned == 1)
        #expect(result.errors.isEmpty)
        #expect(hasQuarantine(url) == false)
    }

    @Test("Throws fileNotFound for non-existent path")
    func throwsFileNotFoundForMissingDirectory() {
        let url = sandbox.url()

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
        let target = try sandbox.file(quarantined: true)
        let link = try sandbox.symlink(to: target)

        // Its own case, not invalidURL: the link exists and can be revealed, and
        // the way out is to drag in what it points at.
        #expect(throws: QuarantineError.symbolicLink(link)) {
            _ = try service.removeQuarantineRecursively(link)
        }
        #expect(!QuarantineError.symbolicLink(link).refersToMissingFile)
    }

    @Test("Descends into subdirectories and skips symlinks instead of following them")
    func descendsIntoSubdirectoriesAndSkipsSymlinks() throws {
        let dir = try sandbox.directory(files: 1, quarantined: true)
        let target = try sandbox.file(quarantined: true)
        let sub = try sandbox.directory("sub", in: dir)
        let nested = try sandbox.file("nested", in: sub, quarantined: true)
        _ = try sandbox.symlink("link", in: sub, to: target)

        let result = try service.removeQuarantineRecursively(dir)

        #expect(result.errors.isEmpty)
        #expect(result.cleaned == 2)  // top-level file + nested file; the link is skipped
        #expect(hasQuarantine(nested) == false)
        #expect(hasQuarantine(target) == true)
    }

    @Test("A walk reached through a linked folder frees the item")
    func walkThroughLinkedFolderFreesItem() throws {
        let real = try sandbox.directory()
        try sandbox.file("inner", in: real, quarantined: true)
        let alias = try sandbox.symlink(to: real)

        let result = try service.removeQuarantineRecursively(alias.appending(path: "inner"))

        #expect(result == QuarantineResult(processed: 1, cleaned: 1))
    }

    @Test("A failure on the item names it as it was handed over, not by its resolved path")
    func itemErrorNamesTheGivenURL() throws {
        let file = try sandbox.file(quarantined: true)
        try sandbox.lock(file)

        let result = try service.removeQuarantineRecursively(file)

        #expect(result.errors == [QuarantineFileError(url: file, error: .permissionDenied(file))])
    }

    @Test("A walk through a linked folder into a protected tree is refused on its resolved path")
    func walkThroughLinkIntoBlockedTreeIsRefusedOnResolvedPath() throws {
        let item = try sandbox.symlink(to: URL(filePath: "/usr/bin")).appending(path: "true")

        #expect(throws: QuarantineError.blockedPath(item)) {
            try service.removeQuarantineRecursively(item, deadline: .now)
        }
    }

    // Foundation takes a trailing "." or ".." apart differently depending on how
    // the URL was built, so both forms a sender can hand over are walked.
    @Test(
        "A walk handed a dot spelling frees the folder the kernel reads it as, and nothing around it",
        arguments: ["a/b/..", "a/b/../", "link/..", "a/.", "a/./"], [false, true])
    func dotSpellingWalksOnlyTheFolderItNames(spelling: String, parsedFromPath: Bool) throws {
        let dir = try sandbox.directory()
        try setQuarantine(on: dir)
        let named = try sandbox.directory("a", in: dir)
        try setQuarantine(on: named)
        let inner = try sandbox.directory("b", in: named)
        let inside = try sandbox.file("inside", in: named, quarantined: true)
        let outside = try sandbox.file("outside", in: sandbox.directory("sibling", in: dir), quarantined: true)
        _ = try sandbox.symlink("link", in: dir, to: inner)

        let url =
            parsedFromPath
            ? URL(filePath: dir.path(percentEncoded: false) + "/" + spelling) : dir.appending(path: spelling)

        let result = try service.removeQuarantineRecursively(url)

        #expect(result == QuarantineResult(processed: 3, cleaned: 2))
        #expect(!hasQuarantine(named))
        #expect(!hasQuarantine(inside))
        #expect(hasQuarantine(outside))
        #expect(hasQuarantine(dir))
    }

    @Test("A walk cancelled before it starts leaves the item and its contents untouched")
    func cancelledWalkTouchesNothing() async throws {
        let dir = try sandbox.directory(files: 3, quarantined: true)
        try setQuarantine(on: dir)
        let service = self.service

        let result = try await withThrowingTaskGroup(of: QuarantineResult.self) { group in
            // A child added to a cancelled group starts cancelled.
            group.cancelAll()
            group.addTask { try service.removeQuarantineRecursively(dir) }
            return try #require(try await group.next())
        }

        #expect(result == QuarantineResult())
        #expect(hasQuarantine(dir))
        #expect(
            try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).allSatisfy(
                hasQuarantine))
    }

    @Test("A walk past its deadline frees its root, stops at the first item it lists and keeps what it freed")
    func expiredWalkKeepsWhatItFreed() throws {
        let dir = try sandbox.directory(files: 3, quarantined: true)
        try setQuarantine(on: dir)

        let result = try service.removeQuarantineRecursively(dir, deadline: .now)

        #expect(result == QuarantineResult(processed: 1, cleaned: 1, timedOut: true))
        #expect(!hasQuarantine(dir))
        #expect(
            try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).allSatisfy(
                hasQuarantine))
        #expect(
            FileStatus(outcomeOf: result, for: dir)
                == .partialSuccess(cleaned: 1, errors: [QuarantineFileError(url: dir, error: .timeout(dir))]))
    }

    @Test("A single file whose walk starts late is freed, not reported as too slow")
    func lateSingleFileIsFreed() throws {
        let url = try sandbox.file(quarantined: true)

        let result = try service.removeQuarantineRecursively(url, deadline: .now)

        #expect(result == QuarantineResult(processed: 1, cleaned: 1))
        #expect(!hasQuarantine(url))
    }

    @Test("Processes empty directory without errors")
    func processesEmptyDirectory() throws {
        let dir = try sandbox.directory()

        let result = try service.removeQuarantineRecursively(dir)

        #expect(result.processed == 1)  // only the directory itself
        #expect(result.cleaned == 0)
        #expect(result.errors.isEmpty)
    }

    @Test("Permission failure on the input maps to permissionDenied, not fileNotFound")
    func permissionFailureMapsToPermissionDenied() throws {
        let dir = try sandbox.directory()
        // Built by hand, not taken from a directory listing — listing APIs cache
        // resource values on the returned URLs, which would mask the stat failure.
        let file = try sandbox.file("unreachable", in: dir)
        try sandbox.lock(dir)

        #expect(throws: QuarantineError.permissionDenied(file)) {
            _ = try service.removeQuarantineRecursively(file)
        }
    }

    @Test("Removes quarantine from directory that itself has the attribute")
    func removesQuarantineFromDirectoryItself() throws {
        let dir = try sandbox.directory(files: 2, quarantined: true)
        try setQuarantine(on: dir)

        let result = try service.removeQuarantineRecursively(dir)

        #expect(result.cleaned == 3)  // dir + 2 files
        #expect(result.errors.isEmpty)
        #expect(hasQuarantine(dir) == false)
    }

    @Test("Removal takes off com.apple.quarantine and writes nothing else")
    func removalTouchesOnlyQuarantine() throws {
        let dir = try sandbox.directory()
        let file = dir.appending(path: "keep")
        try Data("payload".utf8).write(to: file)
        for item in [dir, file] {
            try setQuarantine(on: item)
            try setXattr("com.example.smuggler.keep", "v", on: item)
        }
        // Snapshotted, not spelled out: the system tags new files with attributes
        // of its own, and those must survive the walk as well.
        let namesBefore = [dir, file].map { xattrNames(of: $0) }
        let stampsBefore = try [dir, file].map(Stamp.init)

        _ = try service.removeQuarantineRecursively(dir)

        #expect([dir, file].map { xattrNames(of: $0) } == namesBefore.map { $0.subtracting(["com.apple.quarantine"]) })
        #expect([dir, file].map { xattrValue("com.example.smuggler.keep", of: $0) } == ["v", "v"])
        #expect(try [dir, file].map(Stamp.init) == stampsBefore)
        #expect(try Data(contentsOf: file) == Data("payload".utf8))
    }

    private struct Stamp: Equatable {
        let modified: Date?
        let permissions: Int?

        init(_ url: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
            modified = attributes[.modificationDate] as? Date
            permissions = attributes[.posixPermissions] as? Int
        }
    }
}

nonisolated private let blockedRoots = [
    "/System", "/Library/LaunchDaemons", "/Library/LaunchAgents",
    "/Library/Extensions", "/usr", "/bin", "/sbin",
]

nonisolated private let blockedSpellings: [String] = blockedRoots.flatMap { root -> [String] in
    let dataVolumeForm = "/System/Volumes/Data" + root
    return [
        root, root + "/", root + "/child", root.uppercased() + "/child",
        dataVolumeForm, dataVolumeForm + "/", dataVolumeForm + "/child",
    ]
}

extension QuarantineServiceTests {
    @Suite("QuarantineService — Blocked paths")
    struct BlockedPathTests {
        let sandbox = TestSandbox()

        @Test(
            "Every spelling of a protected tree is refused by both checks",
            arguments: blockedSpellings + [
                "//usr/bin/true", "/./usr/bin", "/tmp/../usr/bin/true",
                // Case-folded spellings APFS resolves, the missing one beyond realpath's reach.
                "/u\u{017F}r/bin/true", "/Library/LaunchDaemon\u{017F}", "/Library/LaunchDaemon\u{017F}/child",
                "/Sy\u{FB06}em/child",
            ])
        func refusesBlockedSpellings(path: String) {
            let url = URL(filePath: path)
            #expect(QuarantineService.hasBlockedPrefix(url))
            #expect(QuarantineService.isBlockedPath(url))
        }

        @Test(
            "A folder that holds a protected tree is refused whole",
            arguments: [
                "/", "/Library", "/Library/", "/LIBRARY",
                "/System/Volumes/Data", "/System/Volumes/Data/", "/SYSTEM/VOLUMES/DATA/",
                "/System/Volumes/Data/Library", "/System/Volumes/Data/Library/",
            ])
        func refusesAncestorsOfBlockedTrees(path: String) {
            let url = URL(filePath: path)
            #expect(QuarantineService.hasBlockedPrefix(url))
            #expect(QuarantineService.isBlockedPath(url))
        }

        @Test("The Data volume's mount point is refused in the form a drop delivers it")
        func refusesStattedDataVolumeRoot() {
            // Stats the disk, so the existing folder comes back with its trailing slash.
            let url = URL(fileURLWithPath: "/System/Volumes/Data")

            #expect(url.hasDirectoryPath)
            #expect(QuarantineService.hasBlockedPrefix(url))
            #expect(QuarantineService.isBlockedPath(url))
        }

        @Test(
            "Kernel lookup aliases at the volume root are refused by both checks",
            arguments: [
                "/.nofollow/usr/bin/true", "/.resolve/1/usr/bin/true", "/.vol/16777234/2",
                "/.nofollow/Library/LaunchDaemons/com.example.plist",
                "/System/Volumes/Data/.nofollow/usr/bin/true",
            ])
        func refusesKernelLookupAliases(path: String) {
            let url = URL(filePath: path)
            #expect(QuarantineService.hasBlockedPrefix(url))
            #expect(QuarantineService.isBlockedPath(url))
        }

        @Test(
            "Look-alikes and user paths are allowed by both checks",
            arguments: [
                "/usrlocal", "/usrlocal/x", "/binary", "/sbinx", "/Systemic/x", "/us", "/Sys", "/Library/Launch",
                "/Library/LaunchDaemonsX", "/Library/LaunchDaemonsBackup/x", "/Library/ExtensionsOld/x",
                "/Library/Fonts/", "/Library/Fonts/MyFont.ttf", "/Applications/", "/tmp/MyApp.app",
                "/private/var/folders/x", "/Users/me/Downloads/a.dmg", "/Users/me/.config/x",
                "/System/../tmp/foo", "/System/Volumes/Data/Users/", "/System/Volumes/Data/Users/me/a.dmg",
            ])
        func allowsNonBlockedPaths(path: String) {
            let url = URL(filePath: path)
            #expect(!QuarantineService.hasBlockedPrefix(url))
            #expect(!QuarantineService.isBlockedPath(url))
        }

        @Test("A symlink alias passes the lexical check but is caught by the resolved check")
        func symlinkAliasFallsToResolvedCheck() throws {
            let link = try sandbox.symlink(to: URL(filePath: "/usr/bin"))

            #expect(!QuarantineService.hasBlockedPrefix(link.appending(path: "true")))
            #expect(QuarantineService.isBlockedPath(link.appending(path: "true")))
        }

        @Test("A symlink to the volume root is caught by the resolved check")
        func symlinkToRootIsRefused() throws {
            let link = try sandbox.symlink(to: URL(filePath: "/"))

            #expect(!QuarantineService.hasBlockedPrefix(link))
            #expect(QuarantineService.isBlockedPath(link))
        }

        @Test(
            "Recursive removal refuses blocked paths as defense in depth",
            arguments: [
                "/usr/bin/true", "/", "/System/Volumes/Data/", "/.nofollow/usr/bin/true", "/u\u{017F}r/bin/true",
            ])
        func recursiveRemovalThrowsOnBlockedPath(path: String) {
            let blocked = URL(filePath: path)
            // Past its deadline from the start, so a regressed refusal stops the
            // walk instead of sweeping the disk.
            #expect(throws: QuarantineError.blockedPath(blocked)) {
                try QuarantineService().removeQuarantineRecursively(blocked, deadline: .now)
            }
        }
    }
}
