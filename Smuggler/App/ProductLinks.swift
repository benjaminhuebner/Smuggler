//
//  ProductLinks.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 07.11.26.
//

import Foundation

nonisolated enum ProductLinks {
    static let website = url("https://smuggler.benjaminhuebner.com")
    static let support = url("https://smuggler.benjaminhuebner.com/support")
    static let guide = url("https://github.com/benjaminhuebner/Smuggler#readme")
    static let sourceCode = url("https://github.com/benjaminhuebner/Smuggler")
    static let developer = url("https://benjaminhuebner.com")
    static let email = "hello@benjaminhuebner.com"
    static let emailURL = url("mailto:hello@benjaminhuebner.com")

    private static func url(_ string: StaticString) -> URL {
        guard let url = URL(string: "\(string)") else { preconditionFailure("Malformed link: \(string)") }
        return url
    }
}
