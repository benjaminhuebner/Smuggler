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

nonisolated extension FileStatus {
    // A walk that ran out of time still freed what it freed: the timeout joins
    // the errors instead of replacing a result the run actually achieved. With
    // nothing freed the deadline is the reason, not the first file it stopped at.
    init(outcomeOf result: QuarantineResult, for url: URL) {
        var errors = result.errors
        if result.timedOut {
            errors.append(QuarantineFileError(url: url, error: .timeout(url)))
        }
        if errors.isEmpty {
            self = result.cleaned > 0 ? .clean : .alreadyClean
        } else if result.cleaned > 0 {
            self = .partialSuccess(cleaned: result.cleaned, errors: errors)
        } else if result.timedOut {
            self = .error(.timeout(url))
        } else {
            self = .error(errors[0].error)
        }
    }
}

nonisolated struct FileItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    var status: FileStatus

    // Kept on the item, not in the row: a lazy list cancels a row's tasks when it
    // scrolls out, and a crawl timed from the view would start over on its return.
    var processingSince: ContinuousClock.Instant?

    var name: String { url.displayName }

    // Only a run that failed to find this item proves it gone: a descendant that
    // vanished mid-walk says nothing about the folder that held it.
    var provedMissing: Bool {
        if case .error(let error) = status { error.refersToMissingFile && error.url == url } else { false }
    }

    init(url: URL, status: FileStatus) {
        self.id = UUID()
        self.url = url
        self.status = status
        self.processingSince = status == .processing ? .now : nil
    }
}

// Shared by the window's status bar and the headless notification: two summaries
// of the same batch counting differently is how they came to contradict each other.
nonisolated extension Collection<FileItem> {
    var freedCount: Int { count(where: \.status.didFreeSomething) }

    var alreadyFreeCount: Int { count { $0.status == .alreadyClean } }

    var failedCount: Int { count(where: \.status.hasErrors) }

    var cancelledCount: Int { count { $0.status == .cancelled } }

    // Cancelled rows count toward nothing: a batch the user stopped themselves
    // must not read as one where the remaining items failed.
    var attemptedCount: Int { count { $0.status.isSuccessful || $0.status.hasErrors } }
}
