import AppKit
import Foundation
import Testing

@testable import OpenRay

struct SideEffectGuardTests {
    private let executable = "/Applications/OpenRay.app/Contents/MacOS/OpenRay"

    @Test func aNormalLaunchIsLive() {
        let sideEffects = SideEffectGuard(arguments: [executable], environment: [:], xcTestLoaded: false)
        #expect(sideEffects.mode == .live)
        #expect(!sideEffects.isInert && !sideEffects.isTestHost && !sideEffects.isVerificationMode)
    }

    @Test(arguments: [
        ["--in-memory-library"],
        ["--verification-pasteboard", "OpenRayVerification.Manual"],
        ["--in-memory-library", "--verification-pasteboard", "OpenRayVerification.Manual", "--first-run"],
    ])
    func isolatedVerificationLaunchesAreInert(_ arguments: [String]) {
        let sideEffects = SideEffectGuard(arguments: [executable] + arguments, environment: [:], xcTestLoaded: false)
        #expect(sideEffects.mode == .verification)
        #expect(sideEffects.isVerificationMode && sideEffects.isInert && !sideEffects.isTestHost)
        #expect(throws: SideEffectGuard.Blocked(what: "moving a window", mode: .verification)) {
            try sideEffects.check("moving a window")
        }
    }

    @Test(arguments: [
        ["XCTestConfigurationFilePath": "/tmp/config.xctestconfiguration"],
        ["XCTestBundlePath": "/tmp/OpenRayTests.xctest"],
        ["XCTestSessionIdentifier": "session"],
    ])
    func theXCTestHostIsInert(_ environment: [String: String]) {
        let sideEffects = SideEffectGuard(arguments: [executable], environment: environment, xcTestLoaded: false)
        #expect(sideEffects.mode == .testHost)
        #expect(sideEffects.isTestHost && sideEffects.isInert)
    }

    @Test func xcTestWinsOverVerificationArgumentsAndLoadedXCTestCounts() {
        let both = SideEffectGuard(
            arguments: [executable, "--in-memory-library"], environment: ["XCTestBundlePath": "/tmp/t.xctest"],
            xcTestLoaded: false)
        #expect(both.mode == .testHost)
        #expect(SideEffectGuard(arguments: [executable], environment: [:], xcTestLoaded: true).mode == .testHost)
    }

    @Test func unrelatedArgumentsStayLive() {
        let sideEffects = SideEffectGuard(
            arguments: [executable, "--open-settings", "permissions", "--first-run"], environment: [:],
            xcTestLoaded: false)
        #expect(sideEffects.mode == .live)
        // Classified live, but this process is the test host: the stricter rule applies.
        #expect(throws: SideEffectGuard.Blocked(what: "anything", mode: .testHost)) { try sideEffects.check("anything") }
    }

    @Test func thisProcessIsTheInertTestHost() {
        #expect(SideEffectGuard.current.mode == .testHost)
        #expect(SideEffectGuard.isTestHost && SideEffectGuard.isInert && !SideEffectGuard.isVerificationMode)
        #expect(throws: SideEffectGuard.Blocked.self) { try SideEffectGuard.check("posting a key") }
    }

    @Test func blockedErrorsNameTheLaunch() {
        #expect(
            SideEffectGuard.Blocked(what: "emptying the Trash", mode: .testHost).errorDescription
                == "OpenRay doesn't allow emptying the Trash while tests run.")
        #expect(
            SideEffectGuard.Blocked(what: "emptying the Trash", mode: .verification).errorDescription
                == "OpenRay doesn't allow emptying the Trash in isolated verification mode.")
    }

    @Test(arguments: [SideEffectGuard.Mode.testHost, .verification])
    func inertLaunchesRefuseTheGeneralPasteboardButNotPrivateOnes(_ mode: SideEffectGuard.Mode) {
        let sideEffects = SideEffectGuard(mode: mode)
        #expect(!sideEffects.mayWrite(toPasteboardNamed: .general))
        #expect(throws: SideEffectGuard.Blocked.self) { try sideEffects.checkWrite(toPasteboardNamed: .general) }
        let verification = NSPasteboard.Name("OpenRayVerification.Manual")
        #expect(sideEffects.mayWrite(toPasteboardNamed: verification))
        #expect((try? sideEffects.checkWrite(toPasteboardNamed: verification)) != nil)
    }

    @Test func anInjectedLiveGuardCannotWriteTheGeneralPasteboardFromTheTestHost() {
        #expect(!SideEffectGuard(mode: .live).mayWrite(toPasteboardNamed: .general))
        #expect(SideEffectGuard(mode: .live).effective.isTestHost)
        #expect(!SideEffectGuard.mayWrite(toPasteboardNamed: .general))
    }

    @MainActor @Test func pasteboardObjectsAreCheckedByName() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenRayTests.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        #expect(SideEffectGuard.mayWrite(to: pasteboard))
        #expect((try? SideEffectGuard.checkWrite(to: pasteboard)) != nil)
    }
}
