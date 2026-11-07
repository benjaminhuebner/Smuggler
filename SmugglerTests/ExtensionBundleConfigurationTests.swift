//
//  ExtensionBundleConfigurationTests.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import Foundation
import Security
import Testing

@Suite("Finder extension bundle configuration")
struct ExtensionBundleConfigurationTests {
    private static let readOnlyKey = "com.apple.security.temporary-exception.files.absolute-path.read-only"
    private static let readWriteKey = "com.apple.security.temporary-exception.files.absolute-path.read-write"

    private let appexURL = Bundle.main.builtInPlugInsURL?.appending(path: "SmugglerFinderExtension.appex")

    @Test("System Settings lists the extension under the brand name alone")
    func displayNameIsTheBrand() throws {
        let appex = try #require(appexURL.flatMap(Bundle.init(url:)))

        #expect(appex.infoDictionary?["CFBundleDisplayName"] as? String == "Smuggler")
    }

    @Test("The extension may read every path but write none outside its app group")
    func sandboxExceptionIsReadOnly() throws {
        let declared = try declaredEntitlements()
        let signed = try signedEntitlements(of: try #require(appexURL))

        #expect(declared["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(declared[Self.readOnlyKey] as? [String] == ["/"])
        #expect(declared[Self.readWriteKey] == nil)
        #expect(signed["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(signed[Self.readWriteKey] == nil)
    }

    // Debug signing adds a read-only "/" exception of its own, so only the source
    // file shows whether a release build still carries the one the menu needs.
    private func declaredEntitlements() throws -> [String: Any] {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "SmugglerFinderExtension/SmugglerFinderExtension.entitlements")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try #require(plist as? [String: Any])
    }

    private func signedEntitlements(of url: URL) throws -> [String: Any] {
        var code: SecStaticCode?
        try #require(SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess)
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        try #require(SecCodeCopySigningInformation(try #require(code), flags, &info) == errSecSuccess)
        let signing = try #require(info as? [String: Any])
        return try #require(signing[kSecCodeInfoEntitlementsDict as String] as? [String: Any])
    }
}
