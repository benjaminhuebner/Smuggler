//
//  QuarantineService.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 21.03.26.
//

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

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            let path = url.absoluteString
            return String(
                localized: "Invalid URL: \(path)",
                comment: "Error: URL is not a valid file URL")
        case .fileNotFound(let url):
            let name = url.lastPathComponent
            return String(
                localized: "File not found: \(name)",
                comment: "Error: file does not exist")
        case .permissionDenied(let url):
            let name = url.lastPathComponent
            return String(
                localized: "Permission denied: \(name)",
                comment: "Error: no permission to access file")
        case .timeout(let url):
            let name = url.lastPathComponent
            return String(
                localized: "Processing timed out: \(name)",
                comment: "Error: operation took too long")
        case .systemError(let url, let code):
            let name = url.lastPathComponent
            return String(
                localized: "System error \(code) for: \(name)",
                comment: "Error: unexpected system error with errno code")
        }
    }
}

// MARK: - QuarantineService

nonisolated struct QuarantineService: Sendable {
    private static let xattrName = "com.apple.quarantine"

    /// Returns true if the file at `url` has the com.apple.quarantine extended attribute.
    func hasQuarantine(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, Self.xattrName, nil, 0, 0, 0) >= 0
        }
    }

    /// Removes the com.apple.quarantine attribute from the file at `url`.
    /// Returns `true` if the attribute was present and removed, `false` if it was already absent.
    /// Throws if the file does not exist, permission is denied, or another system error occurs.
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
                case ENOATTR: return false  // Attribute was not present
                default: throw QuarantineError.systemError(url, code)
                }
            }
            return true  // Attribute was present and has been removed
        }
    }

    /// Removes the quarantine attribute from `url` and, if `url` is a directory,
    /// from every file inside it recursively.
    /// Throws immediately if `url` does not exist.
    /// Per-file errors are collected in the returned `QuarantineResult` rather than thrown.
    func removeQuarantineRecursively(_ url: URL) throws -> QuarantineResult {
        guard url.isFileURL else {
            throw QuarantineError.invalidURL(url)
        }

        // Reject symlinks as direct input to prevent traversal attacks.
        if let linkValues = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
            linkValues.isSymbolicLink == true
        {
            throw QuarantineError.invalidURL(url)
        }

        // Check existence and directory status in one call — avoids TOCTOU with removexattr.
        let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey])
        guard resourceValues != nil else {
            throw QuarantineError.fileNotFound(url)
        }
        let isDir = resourceValues?.isDirectory == true

        var result = QuarantineResult()
        removeQuarantineFromItem(url, into: &result)

        if isDir {
            guard
                let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isSymbolicLinkKey]
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
