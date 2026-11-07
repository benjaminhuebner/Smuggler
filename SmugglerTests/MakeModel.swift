//
//  MakeModel.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 05.09.26.
//

import Foundation

@testable import Smuggler

// Inert: every handler records into `recorder`, confirm answers `confirming`, and the
// handover stores reach no shared container. A passed confirm, terminate or notify runs
// after the recording, so a negative assertion can't pass on an unrecorded handler.
@MainActor
func makeModel(
    recorder: HandlerRecorder = HandlerRecorder(),
    confirming: Bool = false,
    minimumProcessingDuration: Duration = .zero,
    processingTimeout: Duration = .seconds(30),
    terminationGrace: Duration = .milliseconds(50),
    confirm: AppModel.ConfirmHandler? = nil,
    terminate: AppModel.TerminateHandler? = nil,
    notify: AppModel.NotifyHandler? = nil,
    tokenStore: ServiceTokenStore = ServiceTokenStore(containerURL: nil),
    batchStore: ServiceBatchStore = ServiceBatchStore(containerURL: nil),
    walkExecutor: any TaskExecutor = WalkExecutor()
) -> AppModel {
    AppModel(
        handlers: AppModel.Handlers(
            confirm: { urls, kind in
                let recorded = recorder.confirm(answering: confirming)(urls, kind)
                return confirm?(urls, kind) ?? recorded
            },
            open: { recorder.openedURLs = $0 },
            terminate: {
                recorder.terminateCount += 1
                terminate?()
            },
            authorize: { recorder.authorizeCount += 1 },
            notify: { batch in
                recorder.notifiedBatches.append(batch)
                await notify?(batch)
            },
            notifyFailure: { recorder.failureNotifications += 1 },
            sessionStays: { recorder.sessionStaysCount += 1 }
        ),
        tokenStore: tokenStore,
        batchStore: batchStore,
        minimumProcessingDuration: minimumProcessingDuration,
        processingTimeout: processingTimeout,
        terminationGrace: terminationGrace,
        walkExecutor: walkExecutor
    )
}
