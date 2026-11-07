//
//  DroppedFile.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import CoreTransferable
import Foundation
import UniformTypeIdentifiers

// Imports public.file-url alone: URL's own conformance also takes public.url, so a
// browser link would light the drop target and tear the tape for a drop it refuses.
nonisolated struct DroppedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .fileURL) { data in
            // Finder hands over file:///.file/id= references; filePathURL turns one into
            // the item's own path and is nil for one that no longer resolves.
            guard let url = URL(dataRepresentation: data, relativeTo: nil),
                let path = (url as NSURL).filePathURL
            else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            return DroppedFile(url: path)
        }
    }
}
