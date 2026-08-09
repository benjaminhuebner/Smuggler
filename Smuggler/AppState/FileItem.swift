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
