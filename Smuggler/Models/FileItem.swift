import Foundation

nonisolated enum ServiceAction: String, Sendable {
    case open
    case remove
}

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
