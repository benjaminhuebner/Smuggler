import Foundation

// MARK: - QuarantineResult

nonisolated struct QuarantineFileError: Equatable, Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let error: QuarantineError

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.url == rhs.url && lhs.error == rhs.error
    }
}

nonisolated struct QuarantineResult: Equatable, Sendable {
    var processed: Int = 0
    var cleaned: Int = 0
    var errors: [QuarantineFileError] = []
    var timedOut: Bool = false
}

// MARK: - QuarantineError

nonisolated enum QuarantineError: LocalizedError, Equatable, Sendable {
    case invalidURL(URL)
    case symbolicLink(URL)
    case fileNotFound(URL)
    case permissionDenied(URL)
    case timeout(URL)
    case systemError(URL, Int32)
    case blockedPath(URL)
    case unreadableDirectory(URL)

    var url: URL {
        switch self {
        case .invalidURL(let url), .symbolicLink(let url), .fileNotFound(let url), .permissionDenied(let url),
            .timeout(let url), .systemError(let url, _), .blockedPath(let url), .unreadableDirectory(let url):
            url
        }
    }

    var isSkippedDirectory: Bool {
        if case .unreadableDirectory = self { true } else { false }
    }

    var refersToMissingFile: Bool {
        switch self {
        case .fileNotFound, .invalidURL: true
        default: false
        }
    }

    var message: String {
        switch self {
        case .invalidURL(let url):
            String(
                localized: "\(url.displayName) can’t be used",
                comment: "Error: URL is not a valid file URL")
        case .symbolicLink(let url):
            String(
                localized: "\(url.displayName) is an alias, not a file",
                comment: "Error: the item is a symbolic link, which Finder calls an alias")
        case .fileNotFound(let url):
            String(
                localized: "\(url.displayName) could not be found",
                comment: "Error: the item does not exist")
        case .permissionDenied(let url):
            String(
                localized: "No permission to change \(url.displayName)",
                comment: "Error: no permission to change the item")
        case .timeout(let url):
            String(
                localized: "\(url.displayName) took too long",
                comment: "Error: operation took too long")
        case .systemError(let url, _):
            String(
                localized: "\(url.displayName) could not be changed",
                comment: "Error: unexpected system error")
        case .blockedPath(let url):
            String(
                localized: "\(url.displayName) belongs to macOS",
                comment: "Error: path is in a protected system location")
        case .unreadableDirectory(let url):
            String(
                localized: "Could not look inside \(url.displayName)",
                comment: "Error: a subfolder could not be descended into, so its contents were never processed")
        }
    }

    // The message names the problem in one line so a row stays one line;
    // the way out is longer than a row can carry and belongs in the popover.
    var recovery: String {
        switch self {
        case .invalidURL:
            String(
                localized: "This isn’t a file on this Mac. Drag it in from Finder instead.",
                comment: "Error recovery: not a file URL")
        case .symbolicLink:
            String(
                localized: """
                    Quarantine sits on the original. Select the alias in Finder, press Command-R, \
                    then drag the original in.
                    """,
                comment: "Error recovery: a symbolic link; Command-R is Finder's Show Original")
        case .fileNotFound:
            String(
                localized: "It may have been moved or deleted. Drag it in again from where it is now.",
                comment: "Error recovery: the item is gone")
        case .permissionDenied:
            String(
                localized: """
                    Select the item in Finder and press Command-I. Deselect “Locked”, set your account to \
                    “Read & Write” under “Sharing & Permissions”, then try again.
                    """,
                comment: "Error recovery: unlock and allow writing in Finder's Get Info; quotes Finder's labels")
        case .timeout:
            String(
                localized:
                    "A very large folder can run past the time limit. Try again, or drag in the folders inside it one at a time.",
                comment: "Error recovery: operation took too long")
        case .systemError(_, let code):
            String(
                localized:
                    "macOS refused the change (code \(Int(code))). Try again — if it keeps happening, restart your Mac.",
                comment: "Error recovery: unexpected system error, code shown for support")
        case .blockedPath:
            String(
                localized: "Smuggler never changes files in protected system folders.",
                comment: "Error recovery: protected system location")
        case .unreadableDirectory:
            String(
                localized:
                    "The files in this folder were skipped. Check that you can open it in Finder, then try again.",
                comment: "Error recovery: folder could not be descended into")
        }
    }

    // Forwarded rather than declared as `String`: a non-optional property of these
    // names compiles but misses the protocol requirement, and bridging reads nil.
    var errorDescription: String? { message }

    var recoverySuggestion: String? { recovery }
}

// MARK: - QuarantineService

nonisolated struct QuarantineService: Sendable {
    private static let xattrName = "com.apple.quarantine"

    // Quarantine removal on these trees would weaken system integrity far beyond
    // "free a downloaded file", so they are refused regardless of origin — enforced
    // in AppModel.enqueue (every entry point) and here as defense in depth.
    private static let blockedPathPrefixes = [
        "/System/", "/Library/LaunchDaemons/", "/Library/LaunchAgents/",
        "/Library/Extensions/", "/usr/", "/bin/", "/sbin/",
    ].map(caseFolded)

    private static let dataVolumeRoot = "/system/volumes/data/"

    static func isBlockedPath(_ url: URL) -> Bool {
        // Both spellings: a link must not smuggle a blocked tree past the check, and
        // resolving must not wash a refused alias like /.vol/… into an allowed path.
        hasBlockedPrefix(url) || hasBlockedPrefix(url.resolvingSymlinksInPath())
    }

    // String-only, no filesystem syscalls: safe on the main actor for arbitrarily
    // large batches. Case-folded the way APFS matches names, so /library/… and
    // /Library/LaunchDaemonſ/… count as the items they reach.
    static func hasBlockedPrefix(_ url: URL) -> Bool {
        var path = caseFolded(url.standardizedFileURL.path(percentEncoded: false))
        // One spelling per folder, however it arrived: a drop, the open panel and
        // the request filter hand a directory over with its trailing slash.
        while path.hasSuffix("/") { path.removeLast() }
        path += "/"
        // The Data volume firmlinks onto the root: /System/Volumes/Data/Users/… is
        // the same item as /Users/…, the form Finder hands us, and the bare mount
        // point is the root itself.
        if path.hasPrefix(dataVolumeRoot) {
            path = "/" + path.dropFirst(dataVolumeRoot.count)
        }
        // The root's dot entries belong to the system, and /.nofollow, /.resolve and
        // /.vol are kernel lookup aliases that reach any path and survive realpath.
        if path.hasPrefix("/.") { return true }
        // An ancestor of a blocked tree is refused whole, or the walk would descend
        // into it: "/", /Library and the Data volume's mount point.
        return blockedPathPrefixes.contains { path.hasPrefix($0) || $0.hasPrefix(path) }
    }

    // Full Unicode folding, not lowercased(): that leaves ſ and ﬆ alone, which APFS
    // matches to s and st.
    private static func caseFolded(_ path: String) -> String {
        path.folding(options: .caseInsensitive, locale: nil)
    }

    // No link is followed in any component of the path, so a folder swapped for a
    // link after the walk listed it fails the call instead of redirecting it.
    @discardableResult
    func removeQuarantine(_ url: URL, reportingAs shown: URL? = nil) throws(QuarantineError) -> Bool {
        let shown = shown ?? url
        // The syscall's outcome leaves the closure as a plain value: errno is
        // only valid right after the call, and the closure cannot throw typed.
        let outcome: Int32? = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return nil }
            return removexattr(path, Self.xattrName, XATTR_NOFOLLOW_ANY) == 0 ? 0 : errno
        }
        guard let code = outcome else { throw .invalidURL(shown) }
        switch code {
        case 0: return true
        case ENOATTR: return false
        default: throw Self.error(forCode: code, at: shown)
        }
    }

    // Throws only if `url` itself is invalid or missing; per-file errors inside a
    // directory are collected in the returned `QuarantineResult` rather than thrown.
    func removeQuarantineRecursively(
        _ url: URL, deadline: ContinuousClock.Instant? = nil
    ) throws(QuarantineError) -> QuarantineResult {
        guard url.isFileURL else { throw .invalidURL(url) }
        guard !Self.isBlockedPath(url) else { throw .blockedPath(url) }

        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw .permissionDenied(url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            throw .fileNotFound(url)
        } catch {
            // An I/O fault on an existing file must not masquerade as "not found".
            throw .systemError(url, -1)
        }
        // A symlink as input would let an alias smuggle a blocked tree past the path check.
        guard values.isSymbolicLink != true else { throw .symbolicLink(url) }
        let isDir = values.isDirectory == true

        let root = try Self.canonicalLocation(of: url, isDirectory: isDir)
        guard !Self.hasBlockedPrefix(root) else { throw .blockedPath(url) }

        var result = QuarantineResult()
        // A walk abandoned before it ran must leave the item as it was found.
        if Task.isCancelled { return result }
        removeQuarantineFromItem(root, reportingAs: url, into: &result)

        if isDir {
            // Collected separately: `result` is passed inout inside the loop, so the
            // escaping error handler must not capture it as well.
            var descentErrors: [QuarantineFileError] = []
            guard
                let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isSymbolicLinkKey],
                    options: [],
                    errorHandler: { failedURL, _ in
                        // A skipped subtree must surface as an error — a silent skip
                        // would report "clean" for files that were never touched. Its
                        // own case: how many files it hid is unknowable from here, so
                        // it must not read as a single failed file.
                        descentErrors.append(
                            QuarantineFileError(url: failedURL, error: .unreadableDirectory(failedURL)))
                        return true
                    }
                )
            else {
                result.errors.append(QuarantineFileError(url: url, error: .permissionDenied(url)))
                return result
            }
            while let itemURL = enumerator.nextObject() as? URL {
                // Abort promptly on timeout or user cancellation so the blocking
                // enumeration stops and frees its thread.
                if Task.isCancelled { break }
                // Stopping here rather than letting an outer race cancel the walk is
                // what keeps the files already freed in the reported result. The root
                // is exempt: one syscall cannot overrun, so a late start still frees it.
                if Self.isPastDeadline(deadline) {
                    result.timedOut = true
                    break
                }
                // Skipped so a link is neither counted nor reported; the no-follow
                // syscall would refuse it anyway.
                if let values = try? itemURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
                    values.isSymbolicLink == true
                {
                    continue
                }
                removeQuarantineFromItem(itemURL, into: &result)
            }
            result.errors.append(contentsOf: descentErrors)
        }

        return result
    }

    // MARK: - Private

    // The syscalls follow no link, so they need the kernel's spelling of where the
    // item lives (/var and /tmp are links). Only the parent resolves: a link as the
    // last component stays one, and the symlink refusal keeps its meaning.
    private static func canonicalLocation(of url: URL, isDirectory: Bool) throws(QuarantineError) -> URL {
        let name = url.lastPathComponent
        // "." and ".." are never links, and split off the path before them they name
        // another folder, so the kernel reads the whole path instead.
        if name == "." || name == ".." {
            return try realPath(of: url, reportingAs: url)
        }
        return try realPath(of: url.deletingLastPathComponent(), reportingAs: url)
            .appending(path: name, directoryHint: isDirectory ? .isDirectory : .notDirectory)
    }

    private static func realPath(of url: URL, reportingAs shown: URL) throws(QuarantineError) -> URL {
        let resolved: Result<URL, QuarantineError> = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return .failure(.invalidURL(shown)) }
            guard let real = realpath(path, nil) else {
                let code = errno
                // A loop among the folders on the way says nothing about the item being a link.
                return .failure(code == ELOOP ? .systemError(shown, code) : error(forCode: code, at: shown))
            }
            defer { free(real) }
            let canonical = FileManager.default.string(withFileSystemRepresentation: real, length: strlen(real))
            return .success(URL(filePath: canonical, directoryHint: .isDirectory))
        }
        return try resolved.get()
    }

    private static func error(forCode code: Int32, at url: URL) -> QuarantineError {
        switch code {
        case ENOENT: .fileNotFound(url)
        case EACCES, EPERM: .permissionDenied(url)
        case ELOOP: .symbolicLink(url)
        default: .systemError(url, code)
        }
    }

    private static func isPastDeadline(_ deadline: ContinuousClock.Instant?) -> Bool {
        guard let deadline else { return false }
        return ContinuousClock.now >= deadline
    }

    private func removeQuarantineFromItem(
        _ url: URL, reportingAs shown: URL? = nil, into result: inout QuarantineResult
    ) {
        result.processed += 1
        do throws(QuarantineError) {
            if try removeQuarantine(url, reportingAs: shown) {
                result.cleaned += 1
            }
        } catch {
            result.errors.append(QuarantineFileError(url: shown ?? url, error: error))
        }
    }
}
