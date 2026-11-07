//
//  RecoveryGroup.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import Foundation

nonisolated struct RecoveryGroup: Identifiable, Equatable, Sendable {
    let recovery: String
    var errors: [QuarantineFileError]

    var id: String { recovery }
}

nonisolated extension Collection<QuarantineFileError> {
    // Keyed on the advice itself, not the error's case: two system errors with
    // different codes read differently and can call for different fixes.
    var groupedByRecovery: [RecoveryGroup] {
        var groups: [RecoveryGroup] = []
        var indexByRecovery: [String: Int] = [:]
        for fileError in self {
            let recovery = fileError.error.recovery
            if let index = indexByRecovery[recovery] {
                groups[index].errors.append(fileError)
            } else {
                indexByRecovery[recovery] = groups.count
                groups.append(RecoveryGroup(recovery: recovery, errors: [fileError]))
            }
        }
        // Largest first. The sort is stable, so ties keep the walk's order and a
        // popover reads the same every time it opens.
        return groups.sorted { $0.errors.count > $1.errors.count }
    }
}
