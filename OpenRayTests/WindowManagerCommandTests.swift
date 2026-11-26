import CoreGraphics
import Foundation
import Testing

@testable import OpenRay

@MainActor
struct WindowManagerCommandTests {
    private let original = CGRect(x: 100, y: 200, width: 600, height: 400)

    private func makeManager(
        displays: [DisplaySnapshot] = [WindowFixture.laptop, WindowFixture.secondary]
    ) -> (WindowManager, FakeWindowSystem) {
        let system = FakeWindowSystem(
            displays: displays,
            windows: [
                WindowFixture.window(pid: 100, token: 1, title: "Draft", frame: original),
                WindowFixture.window(
                    pid: 200, token: 2, app: "Mail", bundle: "com.example.mail", title: "Inbox",
                    frame: CGRect(x: 300, y: 300, width: 800, height: 500)),
            ])
        return (WindowManager(system: system), system)
    }

    private let first = WindowHandle(pid: 100, token: 1)

    @Test func tilingTheFocusedWindowSetsItsFrameThenFocusesIt() throws {
        let (manager, system) = makeManager()
        try manager.perform(.leftHalf, focusedWindowOf: 100)
        #expect(system.events == [.setFrame(1, CGRect(x: 0, y: 76, width: 720, height: 800)), .focus(1)])
    }

    @Test(arguments: WindowCommand.allCases.filter { WindowGeometry.region($0) != nil })
    func everyTileReachesTheWindowThroughTheSystem(_ command: WindowCommand) throws {
        let (manager, system) = makeManager()
        try manager.perform(command, on: first)
        #expect(
            system.frames == [WindowGeometry.frame(for: command, in: WindowFixture.laptop.visibleFrame, current: original)])
    }

    @Test func gapsFromSettingsApplyToCommands() throws {
        let (manager, system) = makeManager()
        manager.settings.gaps = WindowGaps(uniform: 10)
        try manager.perform(.maximize, on: first)
        #expect(system.frames == [CGRect(x: 10, y: 86, width: 1420, height: 780)])
    }

    @Test func repeatingAHalfCyclesOnlyWhenTheSettingIsOn() throws {
        let (manager, system) = makeManager()
        for _ in 0..<4 { try manager.perform(.leftHalf, on: first) }
        #expect(system.frames.map(\.width) == [720, 720, 720, 720])
        system.clearEvents()
        manager.settings.cyclesHalves = true
        for _ in 0..<4 { try manager.perform(.leftHalf, on: first) }
        #expect(system.frames.map(\.width) == [960, 480, 720, 960])
    }

    @Test func restoreReturnsToTheFrameFromBeforeTheFirstCommand() throws {
        let (manager, system) = makeManager()
        try manager.perform(.leftHalf, on: first)
        try manager.perform(.maximize, on: first)
        try manager.perform(.restore, on: first)
        #expect(system.frames.last == original)
        // Restoring consumes the saved frame.
        #expect(throws: LibraryValidationError.self) { try manager.perform(.restore, on: first) }
    }

    @Test func restoreWithoutAnEarlierCommandFailsWithoutMovingAnything() {
        let (manager, system) = makeManager()
        #expect(throws: LibraryValidationError.self) { try manager.perform(.restore, on: first) }
        #expect(system.events.isEmpty)
    }

    @Test func minimizeAndToggleFullscreenChangeStateNotFrames() throws {
        let (manager, system) = makeManager()
        try manager.perform(.toggleFullscreen, on: first)
        try manager.perform(.toggleFullscreen, on: first)
        try manager.perform(.minimize, on: first)
        #expect(
            system.events == [.fullScreen(1, true), .focus(1), .fullScreen(1, false), .focus(1), .minimized(1, true)])
        // Minimizing doesn't record a frame to restore.
        #expect(throws: LibraryValidationError.self) { try manager.perform(.restore, on: first) }
    }

    @Test func displayMovesFollowTheSystemDisplayOrderAndCenterWithoutRounding() throws {
        // System order is laptop, then the display on its left, then the one on its
        // right: not reading order, which would go from the laptop to the right.
        let (manager, system) = makeManager(displays: [WindowFixture.laptop, WindowFixture.secondary, WindowFixture.portrait])
        try manager.perform(.nextDisplay, on: first)
        #expect(system.frames.last == CGRect(x: -1260, y: 125, width: 600, height: 400))
        try manager.perform(.nextDisplay, on: first)
        #expect(system.frames.last == CGRect(x: 1680, y: 245, width: 600, height: 400))
        try manager.perform(.nextDisplay, on: first)
        #expect(system.frames.last == CGRect(x: 420, y: 276, width: 600, height: 400))
        try manager.perform(.previousDisplay, on: first)
        #expect(system.frames.last == CGRect(x: 1680, y: 245, width: 600, height: 400))
    }

    @Test func legacyNextDisplayKeepsOddSizesUnrounded() throws {
        let odd = DisplaySnapshot(
            id: 9, name: "Odd", frame: CGRect(x: 1440, y: 0, width: 1001, height: 701),
            visibleFrame: CGRect(x: 1440, y: 0, width: 1001, height: 701))
        let system = FakeWindowSystem(
            displays: [WindowFixture.laptop, odd],
            windows: [WindowFixture.window(pid: 100, token: 1, frame: CGRect(x: 100, y: 200, width: 600, height: 400))])
        try WindowManager(system: system).perform(.nextDisplay, on: first)
        #expect(system.frames == [CGRect(x: 1640.5, y: 150.5, width: 600, height: 400)])
    }

    @Test func displayMovesNeedASecondDisplay() {
        let (manager, system) = makeManager(displays: [WindowFixture.laptop])
        #expect(throws: LibraryValidationError.self) { try manager.perform(.nextDisplay, on: first) }
        #expect(throws: LibraryValidationError.self) { try manager.perform(.previousDisplay, on: first) }
        #expect(system.events.isEmpty)
    }

    @Test func windowsOnTheSecondaryDisplayTileThere() throws {
        let (manager, system) = makeManager()
        let secondary = WindowHandle(pid: 300, token: 3)
        system.windowList.append(
            WindowFixture.window(pid: 300, token: 3, frame: CGRect(x: -1500, y: 0, width: 500, height: 400)))
        try manager.perform(.rightHalf, on: secondary)
        #expect(system.frames == [CGRect(x: -960, y: -200, width: 960, height: 1050)])
    }

    @Test func customCommandsUseTheWindowsDisplay() throws {
        let (manager, system) = makeManager()
        try manager.perform(CustomWindowCommand.resize(width: 500, height: 300), focusedWindowOf: 100)
        #expect(system.frames == [CGRect(x: 100, y: 300, width: 500, height: 300)])
        try manager.perform(.restore, on: first)
        #expect(system.frames.last == original)
    }

    @Test func invalidOrOversizedExactCommandsFailBeforeAnythingMoves() {
        let (manager, system) = makeManager()
        let negative = CustomWindowCommand(name: "Bad", width: .points(-20), height: .points(300), anchor: .current)
        #expect(throws: LibraryValidationError.self) { try manager.perform(negative, on: first) }
        #expect(throws: LibraryValidationError.self) { try manager.perform(negative, focusedWindowOf: 100) }
        let farOffset = CustomWindowCommand(name: "Far", anchor: .topLeft, xOffset: .percent(250))
        #expect(throws: LibraryValidationError.self) { try manager.perform(farOffset, on: first) }
        // 1920 points don't fit the laptop's 1440-point visible width: an error, not a smaller window.
        #expect(throws: LibraryValidationError.self) {
            try manager.perform(CustomWindowCommand.resize(width: 1920, height: 1080), on: first)
        }
        #expect(system.events.isEmpty)
    }

    @Test func exactMoveOfAFractionalFixedSizeWindowOnlyMovesIt() throws {
        let fractional = CGRect(x: 100.5, y: 200.25, width: 600.5, height: 400.25)
        let system = FakeWindowSystem(windows: [WindowFixture.window(pid: 100, token: 1, frame: fractional)])
        system.fixedSizeTokens = [1]
        try WindowManager(system: system).perform(CustomWindowCommand.move(x: 40, y: 30), on: first)
        #expect(system.frames.map(\.size) == [fractional.size])
    }

    @Test func anAppThatClampsAnExactResizeIsReported() {
        let (manager, system) = makeManager()
        system.clampedSizes[1] = CGSize(width: 640, height: 300)
        #expect(throws: LibraryValidationError.self) {
            try manager.perform(CustomWindowCommand.resize(width: 900, height: 300), on: first)
        }
        #expect(system.frames == [CGRect(x: 100, y: 300, width: 900, height: 300)])
    }

    @Test func commandsRefuseWithoutAccessibilityAndForOpenRayItself() {
        let (manager, system) = makeManager()
        system.isTrusted = false
        #expect(!manager.hasPermission)
        #expect(throws: LibraryValidationError.self) { try manager.perform(.leftHalf, on: first) }
        #expect(throws: LibraryValidationError.self) { try manager.captureLayout(named: "Desk") }
        system.isTrusted = true
        let own = WindowHandle(pid: system.ownPID, token: 9)
        #expect(throws: LibraryValidationError.self) { try manager.perform(.leftHalf, on: own) }
        #expect(throws: LibraryValidationError.self) { try manager.perform(.leftHalf, focusedWindowOf: system.ownPID) }
        #expect(throws: LibraryValidationError.self) { try manager.perform(.leftHalf, focusedWindowOf: nil) }
        #expect(throws: LibraryValidationError.self) { try manager.perform(.leftHalf, application: nil) }
        // An app that has quit.
        #expect(throws: LibraryValidationError.self) {
            try manager.perform(.leftHalf, on: WindowHandle(pid: 999, token: 1))
        }
        #expect(system.events.isEmpty)
    }

    @Test func requestingPermissionGoesThroughTheSystem() {
        let (manager, system) = makeManager()
        manager.requestPermission()
        #expect(system.trustRequests == 1)
    }

    @Test func aWindowThatRefusesToMoveSurfacesTheError() {
        let (manager, system) = makeManager()
        system.lockedTokens = [1]
        #expect(throws: LibraryValidationError.self) { try manager.perform(.leftHalf, on: first) }
        #expect(!system.events.contains(.focus(1)))
    }

    @Test func focusedWindowTitleComesFromTheSystem() {
        let (manager, _) = makeManager()
        #expect(manager.focusedWindowTitle(of: nil) == nil)
    }

    @Test func theTargetChipListingReadsTitlesOnly() {
        let (manager, system) = makeManager()
        _ = manager.listWindows()
        #expect(system.titleListings == 1)
        #expect(system.frameListings == 0)
    }

    @Test(arguments: [SideEffectGuard.Mode.testHost, .verification])
    func inertLaunchesGetAnInertWindowSystem(_ mode: SideEffectGuard.Mode) {
        let sideEffects = SideEffectGuard(mode: mode)
        let system = WindowSystemEnvironment.makeSystem(sideEffects: sideEffects)
        #expect(system is InertWindowSystem)
        #expect(!system.isTrusted)
        #expect(system.windows(includeMinimized: true, readFrames: true).isEmpty)
        #expect(WindowSystemEnvironment.makeListing(sideEffects: sideEffects) is InertWindowServerListing)
        let handle = WindowHandle(pid: 0, token: 0)
        #expect(throws: SideEffectGuard.Blocked(what: "moving a window", mode: mode)) {
            try system.setFrame(.zero, of: handle)
        }
        // The hosted default is inert too, so no test reads the developer's real windows.
        #expect(WindowManager().system is InertWindowSystem)
        #expect(!WindowManager().hasPermission)
    }

    @Test(arguments: [SideEffectGuard.Mode.testHost, .verification])
    func theAccessibilitySystemRefusesEveryChangeInInertLaunches(_ mode: SideEffectGuard.Mode) {
        // Element-less handles: nothing could happen even if a guard were missing.
        let system = AXWindowSystem(sideEffects: SideEffectGuard(mode: mode))
        let handle = WindowHandle(pid: 0, token: 0)
        #expect(throws: SideEffectGuard.Blocked.self) { try system.setFrame(.zero, of: handle) }
        #expect(throws: SideEffectGuard.Blocked.self) { try system.setMinimized(true, of: handle) }
        #expect(throws: SideEffectGuard.Blocked.self) { try system.setFullScreen(true, of: handle) }
        #expect(throws: SideEffectGuard.Blocked.self) { try system.focus(handle) }
        #expect(throws: SideEffectGuard.Blocked.self) { try system.close(handle) }
        #expect(throws: SideEffectGuard.Blocked.self) { try system.hideApplication(-1) }
    }

    @Test func handlesCompareByProcessAndToken() {
        #expect(WindowHandle(pid: 1, token: 2) == WindowHandle(pid: 1, token: 2))
        #expect(WindowHandle(pid: 1, token: 2) != WindowHandle(pid: 1, token: 3))
        #expect(WindowHandle(pid: 1, token: 2) != WindowHandle(pid: 2, token: 2))
        #expect(Set([WindowHandle(pid: 1, token: 2), WindowHandle(pid: 1, token: 2)]).count == 1)
    }
}
