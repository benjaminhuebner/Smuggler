//
//  AppBundleConfigurationTests.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import Foundation
import Testing

@testable import Smuggler

@Suite("App bundle configuration")
struct AppBundleConfigurationTests {
    private let info = Bundle.main.infoDictionary ?? [:]

    @Test("Sparkle reads its feed from the latest GitHub release")
    func feedIsTheLatestReleaseAsset() throws {
        let feed = try #require(info["SUFeedURL"] as? String)
        let expected = ProductLinks.sourceCode.appending(path: "releases/latest/download/appcast.xml")
        #expect(feed == expected.absoluteString)
    }

    @Test("Sparkle verifies an update's EdDSA signature before extracting it")
    func updatesAreVerifiedBeforeExtraction() {
        #expect(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
        #expect((info["SUPublicEDKey"] as? String)?.isEmpty == false)
    }

    @Test("Sparkle trusts the appcast only with a valid EdDSA signature")
    func feedMustBeSigned() {
        #expect(info["SURequireSignedFeed"] as? Bool == true)
    }

    // The About panel prefers a localized InfoPlist.strings value, so a copy pinned
    // there would outlive the next change to the build setting.
    @Test("The build setting is the only copyright, in every localization", arguments: ["en", "de"])
    func buildSettingIsTheOnlyCopyright(localization: String) throws {
        #expect((info["NSHumanReadableCopyright"] as? String)?.isEmpty == false)
        #expect(try stringsTable("InfoPlist", localization: localization)?["NSHumanReadableCopyright"] == nil)
    }

    @Test("The Services entry makes macOS ask the user before it runs")
    func servicesEntryIsRestricted() throws {
        let services = try #require(info["NSServices"] as? [[String: Any]])
        #expect(services.map { $0["NSRestricted"] as? Bool } == [true])
    }

    // The Services menu looks its title up in ServicesMenu.strings, keyed on the
    // unlocalized title, and never reads InfoPlist.strings for it. A reworded title
    // would drop back to English without a single warning.
    @Test("The Services menu title has its German entry in the table macOS reads it from")
    func servicesMenuTitleIsLocalized() throws {
        let services = try #require(info["NSServices"] as? [[String: Any]])
        let menuItem = try #require(services.first?["NSMenuItem"] as? [String: String])
        let title = try #require(menuItem["default"])

        let german = try #require(try stringsTable("ServicesMenu", localization: "de"))
        let english = try #require(try stringsTable("ServicesMenu", localization: "en"))
        #expect(german[title] == "Quarantäne mit Smuggler aufheben")
        #expect(english[title] == title)
    }

    @Test("The privacy manifest covers the required-reason APIs of the app and its embedded Sparkle")
    func privacyManifestDeclaresRequiredReasons() throws {
        let url = try #require(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        let manifest = try #require(plist as? [String: Any])
        let entries = try #require(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])

        var reasons: [String: [String]] = [:]
        for entry in entries {
            let category = try #require(entry["NSPrivacyAccessedAPIType"] as? String)
            reasons[category] = try #require(entry["NSPrivacyAccessedAPITypeReasons"] as? [String])
        }

        #expect(
            reasons == [
                "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
                "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
                "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"],
                "NSPrivacyAccessedAPICategoryDiskSpace": ["E174.1"],
            ])
    }

    private func stringsTable(_ name: String, localization: String) throws -> [String: String]? {
        guard
            let url = Bundle.main.url(
                forResource: name, withExtension: "strings", subdirectory: nil, localization: localization)
        else { return nil }
        return try #require(NSDictionary(contentsOf: url) as? [String: String])
    }
}
