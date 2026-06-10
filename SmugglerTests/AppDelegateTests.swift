import Foundation
import Testing

@testable import Smuggler

@Suite("AppDelegate — cold launch")
@MainActor
struct AppDelegateColdLaunchTests {
    @Test("Default launches are immediately ready")
    func defaultLaunchIsReady() {
        let delegate = AppDelegate()

        delegate.completeLaunch(isDefaultLaunch: true)

        #expect(delegate.isReady)
        #expect(delegate.consumeColdLaunch() == false)
    }

    @Test("First request after a non-default launch is the cold-launch request")
    func nonDefaultLaunchConsumesColdLaunchOnce() {
        let delegate = AppDelegate()

        delegate.completeLaunch(isDefaultLaunch: false)

        #expect(delegate.consumeColdLaunch() == true)
        #expect(delegate.consumeColdLaunch() == false)
    }

    @Test("An unconsumed cold launch expires after the grace period")
    func unconsumedColdLaunchExpires() async throws {
        let delegate = AppDelegate()
        delegate.coldLaunchGracePeriod = .milliseconds(50)

        delegate.completeLaunch(isDefaultLaunch: false)

        try await Task.sleep(for: .milliseconds(250))
        #expect(delegate.consumeColdLaunch() == false)
    }

    @Test("A request consumed before launch completion is not re-armed")
    func earlyRequestIsNotRearmed() {
        let delegate = AppDelegate()

        #expect(delegate.consumeColdLaunch() == true)
        delegate.completeLaunch(isDefaultLaunch: false)

        #expect(delegate.consumeColdLaunch() == false)
    }
}
