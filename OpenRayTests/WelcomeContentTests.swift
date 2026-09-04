import Testing
@testable import OpenRay

struct WelcomeContentTests {
    @Test
    func copyIdentifiesOpenRayAsAPrivateMacLauncher() {
        let content = WelcomeContent.default

        #expect(content.title == "OpenRay")
        #expect(content.subtitle == "A fast, private launcher for macOS.")
    }
}
