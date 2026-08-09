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
}

// MARK: - QuarantineError

nonisolated enum QuarantineError: LocalizedError, Equatable, Sendable {
    case invalidURL(URL)
    case fileNotFound(URL)
    case permissionDenied(URL)
    case timeout(URL)
    case systemError(URL, Int32)
    case blockedPath(URL)
    case unreadableDirectory(URL)

    var isSkippedDirectory: Bool {
        if case .unreadableDirectory = self { true } else { false }
    }

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            String(
                localized: "Invalid URL: \(url.absoluteString)",
                comment: "Error: URL is not a valid file URL")
        case .fileNotFound(let url):
            String(
                localized: "File not found: \(url.lastPathComponent)",
                comment: "Error: file does not exist")
        case .permissionDenied(let url):
            String(
                localized: "Permission denied: \(url.lastPathComponent)",
                comment: "Error: no permission to access file")
        case .timeout(let url):
            String(
                localized: "Processing timed out: \(url.lastPathComponent)",
                comment: "Error: operation took too long")
        case .systemError(let url, let code):
            String(
                localized: "System error \(code) for: \(url.lastPathComponent)",
                comment: "Error: unexpected system error with errno code")
        case .blockedPath(let url):
            String(
                localized: "System location cannot be modified: \(url.lastPathComponent)",
                comment: "Error: path is in a protected system location")
        case .unreadableDirectory(let url):
            String(
                localized: "Could not read \(url.lastPathComponent) — the files inside were skipped",
                comment: "Error: a subfolder could not be descended into, so its contents were never processed")
        }
    }
}

// MARK: - QuarantineService

nonisolated struct QuarantineService: Sendable {
    private static let xattrName = "com.apple.quarantine"

    // Quarantine removal on these trees would weaken system integrity far beyond
    // "free a downloaded file", so they are refused regardless of origin — enforced
    // in AppModel.enqueue (every entry point) and here as defense in depth.
    static let blockedPathPrefixes = [
        "/System/", "/Library/LaunchDaemons/", "/Library/LaunchAgents/",
        "/Library/Extensions/", "/usr/", "/bin/", "/sbin/",
    ]

    private static let lowercasedBlockedPrefixes = blockedPathPrefixes.map { $0.lowercased() }

    private static let dataVolumeRoot = "/system/volumes/data/"

    static func isBlockedPath(_ url: URL) -> Bool {
        // Resolve symlinks so an alias cannot smuggle a blocked tree past the check.
        hasBlockedPrefix(url.resolvingSymlinksInPath())
    }

    // String-only, no filesystem syscalls: safe on the main actor for arbitrarily
    // large batches. Case-insensitive — the default APFS volume resolves
    // /library/... to the same item as /Library/...
    static func hasBlockedPrefix(_ url: URL) -> Bool {
        var path = url.standardizedFileURL.path(percentEncoded: false).lowercased() + "/"
        // The Data volume firmlinks onto the root: /System/Volumes/Data/Users/… is
        // the same item as /Users/…, the form Finder hands us. The bare mount point
        // stays blocked — that is the whole volume.
        if path.hasPrefix(dataVolumeRoot), path.count > dataVolumeRoot.count {
            path = "/" + path.dropFirst(dataVolumeRoot.count)
        }
        return lowercasedBlockedPrefixes.contains { path.hasPrefix($0) }
    }

    func hasQuarantine(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, Self.xattrName, nil, 0, 0, 0) >= 0
        }
    }

    @discardableResult
    func removeQuarantine(_ url: URL) throws -> Bool {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                throw QuarantineError.invalidURL(url)
            }
            guard removexattr(path, Self.xattrName, 0) == 0 else {
                let code = errno
                switch code {
                case ENOENT: throw QuarantineError.fileNotFound(url)
                case EACCES, EPERM: throw QuarantineError.permissionDenied(url)
                case ENOATTR: return false
                default: throw QuarantineError.systemError(url, code)
                }
            }
            return true
        }
    }

    // Throws only if `url` itself is invalid or missing; per-file errors inside a
    // directory are collected in the returned `QuarantineResult` rather than thrown.
    func removeQuarantineRecursively(_ url: URL) throws -> QuarantineResult {
        guard url.isFileURL else {
            throw QuarantineError.invalidURL(url)
        }

        guard !Self.isBlockedPath(url) else {
            throw QuarantineError.blockedPath(url)
        }

        // Reject symlinks as direct input to prevent traversal attacks.
        if let linkValues = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
            linkValues.isSymbolicLink == true
        {
            throw QuarantineError.invalidURL(url)
        }

        // Check existence and directory status in one call — avoids TOCTOU with removexattr.
        let isDir: Bool
        do {
            isDir = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw QuarantineError.permissionDenied(url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            throw QuarantineError.fileNotFound(url)
        } catch {
            // An I/O fault on an existing file must not masquerade as "not found".
            throw QuarantineError.systemError(url, -1)
        }

        var result = QuarantineResult()
        removeQuarantineFromItem(url, into: &result)

        if isDir {
            // Collected separately: `result` is passed inout inside the loop, so the
            // escaping error handler must not capture it as well.
            var descentErrors: [QuarantineFileError] = []
            guard
                let enumerator = FileManager.default.enumerator(
                    at: url,
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
                // enumeration stops and frees its cooperative-pool thread.
                if Task.isCancelled { break }
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

    private func removeQuarantineFromItem(_ url: URL, into result: inout QuarantineResult) {
        result.processed += 1
        do {
            if try removeQuarantine(url) {
                result.cleaned += 1
            }
        } catch let error as QuarantineError {
            result.errors.append(QuarantineFileError(url: url, error: error))
        } catch {
            assertionFailure("Unexpected error type: \(error)")
            result.errors.append(QuarantineFileError(url: url, error: .systemError(url, -1)))
        }
    }
}
