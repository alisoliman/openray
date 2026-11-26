import AppKit
import Testing

@testable import OpenRay

/// The process rule wins over an injected guard: tests (and isolated verification) can never
/// re-enable side effects by passing a `.live` guard into a live adapter.
@MainActor
struct SideEffectGuardProcessTests {
    @Test func theTestHostIsInert() {
        #expect(SideEffectGuard.current.isInert)
    }

    @Test func anInjectedLiveGuardIsRestrictedByTheInertProcess() {
        let live = SideEffectGuard(mode: .live)
        #expect(live.effective.isInert)
        #expect(throws: SideEffectGuard.Blocked.self) { try live.check("quitting an app") }
        #expect(!live.mayWrite(toPasteboardNamed: .general))
        #expect(throws: SideEffectGuard.Blocked.self) { try live.checkWrite(toPasteboardNamed: .general) }
    }

    @Test func privatePasteboardsStayWritable() {
        #expect(SideEffectGuard(mode: .live).mayWrite(toPasteboardNamed: NSPasteboard.Name("openray.tests.private")))
        #expect(SideEffectGuard(mode: .verification).mayWrite(toPasteboardNamed: NSPasteboard.Name("openray.tests.private")))
    }

    @Test func inertInstancesKeepTheirOwnMode() {
        #expect(SideEffectGuard(mode: .verification).effective.mode == .verification)
        #expect(SideEffectGuard(mode: .testHost).effective.mode == .testHost)
    }
}
