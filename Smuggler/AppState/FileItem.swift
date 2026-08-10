import Foundation

nonisolated enum FileStatus: Equatable, Sendable {
    case processing
    case clean
    case alreadyClean
    case partialSuccess(cleaned: Int, errors: [QuarantineFileError])
    case cancelled
    case error(QuarantineError)

    var isSuccessful: Bool {
        switch self {
        case .clean, .alreadyClean, .partialSuccess: true
        default: false
        }
    }

    var hasErrors: Bool {
        switch self {
        case .error, .partialSuccess: true
        default: false
        }
    }

    // Narrower than `isSuccessful`, which also covers a file that never had
    // quarantine: only these actually had something taken off them, and a
    // summary that counts the others would contradict its own rows.
    var didFreeSomething: Bool {
        switch self {
        case .clean: true
        case .partialSuccess(let cleaned, _): cleaned > 0
        default: false
        }
    }

    // A subtree the walk could not descend into is reported like any other error,
    // but it leaves nothing to act on in the window — it must not hold a headless
    // session open the way a real failure does.
    var hasActionableErrors: Bool {
        switch self {
        case .error(let error): !error.isSkippedDirectory
        case .partialSuccess(_, let errors): errors.contains { !$0.error.isSkippedDirectory }
        default: false
        }
    }
}

nonisolated struct FileItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    var status: FileStatus

    var name: String { url.lastPathComponent }

    init(url: URL, status: FileStatus) {
        self.id = UUID()
        self.url = url
        self.status = status
    }
}

// Shared by the window's status bar and the headless notification: two summaries
// of the same batch counting differently is how they came to contradict each other.
nonisolated extension Collection<FileItem> {
    var freedCount: Int { count(where: \.status.didFreeSomething) }

    var alreadyFreeCount: Int { count { $0.status == .alreadyClean } }

    var failedCount: Int { count(where: \.status.hasErrors) }

    // Cancelled rows count toward nothing: a batch the user stopped themselves
    // must not read as one where the remaining items failed.
    var attemptedCount: Int { count { $0.status.isSuccessful || $0.status.hasErrors } }
}
