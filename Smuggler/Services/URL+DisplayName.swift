//
//  URL+DisplayName.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import Foundation

nonisolated extension URL {
    var displayName: String { Self.neutralizingControls(in: lastPathComponent) }

    var displayPath: String { Self.neutralizingControls(in: path(percentEncoded: false)) }

    // A bidi override or a line break makes a name render as something other than
    // the file it names: "Rechnung\u{202E}fdp.app" displays as "Rechnungppa.pdf".
    private static func neutralizingControls(in text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            scalars.append(isDisplayHazard(scalar) ? "\u{FFFD}" : scalar)
        }
        return String(scalars)
    }

    // Joiners and tag characters stay: emoji sequences and several scripts need
    // them to render, and neither can reorder or hide the text around them.
    private static func isDisplayHazard(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator:
            true
        case .format:
            !scalar.properties.isJoinControl && !(0xE0020...0xE007F).contains(scalar.value)
        default:
            false
        }
    }
}
