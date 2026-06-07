//
//  FileItem.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 21.03.26.
//

import Foundation

nonisolated enum FileStatus: Equatable, Sendable {
    case processing
    case clean
    case partialSuccess(cleaned: Int, failed: Int)
    case cancelled
    case error(QuarantineError)

    var isSuccessful: Bool {
        switch self {
        case .clean, .partialSuccess: true
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

/// Tracks progress for directory processing (file count based).
nonisolated struct ProcessingProgress: Equatable, Sendable {
    var processed: Int = 0
    var total: Int = 0

    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(processed) / Double(total)
    }
}

nonisolated struct FileItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    var status: FileStatus
    var progress: ProcessingProgress = ProcessingProgress()
    let timestamp: Date

    var name: String { url.lastPathComponent }

    init(url: URL, status: FileStatus, timestamp: Date = .now) {
        self.id = UUID()
        self.url = url
        self.status = status
        self.timestamp = timestamp
    }
}
