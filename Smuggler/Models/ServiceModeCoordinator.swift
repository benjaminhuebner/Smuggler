//
//  ServiceModeCoordinator.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 24.03.26.
//

import Foundation

/// Encapsulates service-mode state (Finder Extension / Services Menu).
/// Owns the lifecycle tasks for processing and termination so they can
/// be cancelled independently of AppModel's item management.
@MainActor
final class ServiceModeCoordinator {
    let entryIDs: Set<UUID>
    let action: String
    let quitAfter: Bool

    var processingTask: Task<Void, Never>?
    var terminationTask: Task<Void, Never>?

    init(entryIDs: Set<UUID>, action: String, quitAfter: Bool) {
        self.entryIDs = entryIDs
        self.action = action
        self.quitAfter = quitAfter
    }

    func cancel() {
        processingTask?.cancel()
        processingTask = nil
        terminationTask?.cancel()
        terminationTask = nil
    }
}
