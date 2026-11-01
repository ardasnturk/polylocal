import Testing
@testable import Polylocal

@Suite struct SetupTests {
    @Test func opensUntilFinishedAndWorking() {
        #expect(AppModel.needsSetup(completedOnboarding: false, accessibilityTrusted: true, hasUsableModel: true))
        #expect(AppModel.needsSetup(completedOnboarding: true, accessibilityTrusted: false, hasUsableModel: true))
        #expect(AppModel.needsSetup(completedOnboarding: true, accessibilityTrusted: true, hasUsableModel: false))
        #expect(!AppModel.needsSetup(completedOnboarding: true, accessibilityTrusted: true, hasUsableModel: true))
    }
}
