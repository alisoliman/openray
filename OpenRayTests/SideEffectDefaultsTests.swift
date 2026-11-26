import AppKit
import Testing

@testable import OpenRay

/// A default-built launcher in an inert launch (this test host, or verification mode) must use
/// a private pasteboard and an in-memory library. Nothing here runs a real executor: the model is
/// only built, and the live case only names the pasteboard it would use.
@MainActor
struct SideEffectDefaultsTests {
    @Test func theTestHostIsInert() {
        #expect(SideEffectGuard.current.isTestHost)
        #expect(SideEffectGuard.isInert)
        #expect(RuntimeMode.usesInMemoryLibrary)
    }

    @Test(arguments: [SideEffectGuard.Mode.testHost, .verification])
    func aDefaultBuiltModelIsIsolated(mode: SideEffectGuard.Mode) {
        let model = LauncherModel(ai: AIChatModel(engine: TestAIEngine()), sideEffects: SideEffectGuard(mode: mode))
        defer { model.stop() }
        #expect(model.store.fileURL == nil)
        #expect(model.memory.fileURL == nil)
        #expect(!model.clipboard.usesGeneralPasteboard)
    }

    @Test func theProcessDefaultsAreIsolatedToo() {
        let model = LauncherModel(ai: AIChatModel(engine: TestAIEngine()))
        defer { model.stop() }
        #expect(model.store.fileURL == nil)
        #expect(!model.clipboard.usesGeneralPasteboard)
    }

    @Test func theAppDelegatesPasteboardFollowsTheLaunch() {
        let plain = ["OpenRay"]
        for mode in [SideEffectGuard.Mode.testHost, .verification] {
            #expect(RuntimeMode.launchPasteboard(arguments: plain, sideEffects: SideEffectGuard(mode: mode)).name != .general)
        }
        #expect(RuntimeMode.launchPasteboard(arguments: plain, sideEffects: SideEffectGuard(mode: .live)).name == .general)
        // A named verification pasteboard is kept, and a bad name never falls back to the system one.
        let named = ["OpenRay", "--in-memory-library", "--verification-pasteboard", "OpenRayVerification.check"]
        #expect(RuntimeMode.launchPasteboard(arguments: named).name.rawValue == "OpenRayVerification.check")
        let bad = ["OpenRay", "--verification-pasteboard", "general"]
        #expect(RuntimeMode.launchPasteboard(arguments: bad, sideEffects: SideEffectGuard(mode: .live)).name != .general)
    }
}
