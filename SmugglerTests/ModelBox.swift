//
//  ModelBox.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import Foundation

@testable import Smuggler

// Lets handler closures reach the model they are installed on, since the
// model cannot capture itself during its own init.
@MainActor
final class ModelBox {
    var model: AppModel?
}
