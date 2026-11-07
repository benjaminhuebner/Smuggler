import Foundation

// Separate from AppModel so a superseded batch's lifecycle tasks can be
// cancelled without touching item management.
@MainActor
final class ServiceModeCoordinator {
    let entryIDs: Set<UUID>
    let action: ServiceAction

    var processingTask: Task<Void, Never>?
    var terminationTask: Task<Void, Never>?
    var authorizationTask: Task<Void, Never>?

    init(entryIDs: Set<UUID>, action: ServiceAction) {
        self.entryIDs = entryIDs
        self.action = action
    }

    func cancel() {
        processingTask?.cancel()
        processingTask = nil
        terminationTask?.cancel()
        terminationTask = nil
        authorizationTask?.cancel()
        authorizationTask = nil
    }
}
