//
//  TestHostIsolationTests.swift
//  Smuggler
//
//  Created by Benjamin Hübner on 26.09.26.
//

import Foundation
import Testing

@Suite("Test host isolation")
struct TestHostIsolationTests {
    // The host is the full app under the shipped bundle ID and against the real
    // defaults domain; only the scheme's Test-action arguments keep it from
    // checking online or asking for notification permission.
    private let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)

    @Test("The test host runs with Sparkle's automatic update checks off")
    func automaticUpdateChecksAreOff() {
        #expect(arguments["SUEnableAutomaticChecks"] as? String == "NO")
    }

    @Test("The test host launches without asking for notification permission")
    func launchNotificationPromptIsSkipped() {
        #expect(arguments["SmugglerSkipsLaunchNotificationPrompt"] as? String == "YES")
    }
}
