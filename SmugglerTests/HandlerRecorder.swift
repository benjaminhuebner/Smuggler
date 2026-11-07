//
//  HandlerRecorder.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import Foundation

@testable import Smuggler

@MainActor
final class HandlerRecorder {
    nonisolated struct Confirmation: Equatable {
        let kind: AppModel.ConfirmKind
        let urls: [URL]
    }

    var confirmations: [Confirmation] = []
    var openedURLs: [URL] = []
    var terminateCount = 0
    var authorizeCount = 0
    var notifiedBatches: [[FileItem]] = []
    var failureNotifications = 0
    var statusAtTerminate: FileStatus?
    var injectedSecondBatch = false
    var quitPromptCount = 0
    var windowReopenCount = 0
    var sessionStaysCount = 0

    func confirm(answering answer: Bool) -> AppModel.ConfirmHandler {
        { urls, kind in
            self.confirmations.append(Confirmation(kind: kind, urls: urls))
            return answer
        }
    }
}
