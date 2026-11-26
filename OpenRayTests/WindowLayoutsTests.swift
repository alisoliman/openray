import CoreGraphics
import Foundation
import Testing

@testable import OpenRay

@MainActor
struct WindowLayoutsTests {
    private let displays = [WindowFixture.laptop, WindowFixture.secondary]

    private func desk() -> [WindowSnapshot] {
        [
            WindowFixture.window(
                pid: 100, token: 1, app: "Editor", bundle: "com.example.editor", title: "main.swift",
                frame: CGRect(x: 0, y: 76, width: 720, height: 800)),
            WindowFixture.window(
                pid: 200, token: 2, app: "Browser", bundle: "com.example.browser", title: "Docs",
                frame: CGRect(x: 720, y: 76, width: 720, height: 800)),
            WindowFixture.window(
                pid: 300, token: 3, app: "Chat", bundle: "com.example.chat", title: "Team",
                frame: CGRect(x: -1920, y: -200, width: 960, height: 1050)),
            WindowFixture.window(
                pid: 300, token: 4, app: "Chat", bundle: "com.example.chat", title: "Hidden", minimized: true),
        ]
    }

    /// A manager whose window server sees `onScreen` front to back (all of the desk by default).
    private func makeManager(
        windows: [WindowSnapshot]? = nil, onScreen: [WindowSnapshot]? = nil
    ) -> (WindowManager, FakeWindowSystem) {
        let windows = windows ?? desk()
        let system = FakeWindowSystem(displays: displays, windows: windows)
        let listing = FakeWindowServerListing(WindowFixture.entries(for: onScreen ?? windows.filter { !$0.isMinimized }))
        return (WindowManager(system: system, listing: listing), system)
    }

    // MARK: Capture

    @Test func savingTheCurrentLayoutRecordsVisibleWindowsRelativeToTheirDisplay() throws {
        let layout = WindowLayoutPlanner.capture(named: "Desk", displays: displays, windows: desk())
        #expect(layout.name == "Desk")
        #expect(layout.slots.map(\.bundleIdentifier) == ["com.example.editor", "com.example.browser", "com.example.chat"])
        #expect(layout.slots[0].region == UnitRect(x: 0, y: 0, width: 0.5, height: 1))
        #expect(layout.slots[1].region == UnitRect(x: 0.5, y: 0, width: 0.5, height: 1))
        #expect(layout.slots[2].region == UnitRect(x: 0, y: 0, width: 0.5, height: 1))
        // Reading order puts the secondary display (left of the laptop) first.
        #expect(layout.slots.map(\.displayIndex) == [1, 1, 0])
        #expect(layout.slots.map(\.displayName) == ["Built-in Display", "Built-in Display", "Studio Display"])
        #expect(layout.slots[0].windowTitle == "main.swift")
        #expect(layout.otherWindows == .leave)
        try layout.validate()
    }

    @Test func capturingKeepsAtMostEightWindowsPerDisplayAndSkipsUnknownWindows() {
        var windows = (0..<10).map {
            WindowFixture.window(pid: pid_t(1_000 + $0), token: $0, bundle: "com.example.app\($0)")
        }
        windows.insert(WindowFixture.window(pid: 50, token: 50, bundle: nil), at: 0)
        windows.insert(WindowFixture.window(pid: 51, token: 51, bundle: "com.example.noframe", frame: nil), at: 0)
        windows.insert(
            WindowFixture.window(
                pid: 52, token: 52, bundle: "com.example.offscreen", frame: CGRect(x: 9_000, y: 0, width: 100, height: 100)),
            at: 0)
        let layout = WindowLayoutPlanner.capture(named: "Busy", displays: displays, windows: windows)
        #expect(layout.slots.count == SavedWindowLayout.maximumWindowsPerDisplay)
        #expect(layout.slots.first?.bundleIdentifier == "com.example.app0")
    }

    @Test func saveCurrentLayoutUsesTheWindowServersStackingNotAccessibilityOrder() throws {
        // Accessibility lists apps alphabetically: Browser before Editor. On screen, Editor is in front.
        let editor = WindowFixture.window(
            pid: 100, token: 1, app: "Editor", bundle: "com.example.editor",
            frame: CGRect(x: 0, y: 76, width: 720, height: 800))
        let browser = WindowFixture.window(
            pid: 200, token: 2, app: "Browser", bundle: "com.example.browser",
            frame: CGRect(x: 720, y: 76, width: 720, height: 800))
        let hiddenApp = WindowFixture.window(pid: 300, token: 3, app: "Hidden", bundle: "com.example.hidden")
        let otherSpace = WindowFixture.window(
            pid: 400, token: 4, app: "Elsewhere", bundle: "com.example.elsewhere",
            frame: CGRect(x: 200, y: 200, width: 500, height: 400))
        let (manager, _) = makeManager(
            windows: [browser, editor, hiddenApp, otherSpace], onScreen: [editor, browser])
        let layout = try manager.captureLayout(named: "Desk")
        #expect(layout.slots.map(\.appName) == ["Editor", "Browser"])
    }

    @Test func savingThroughTheManagerNeedsVisibleWindows() throws {
        let (manager, system) = makeManager()
        #expect(try manager.captureLayout(named: "Desk").slots.count == 3)
        system.windowList.removeAll()
        #expect(throws: LibraryValidationError.self) { try manager.captureLayout(named: "Empty") }
        let (offScreen, _) = makeManager(onScreen: [])
        #expect(throws: LibraryValidationError.self) { try offScreen.captureLayout(named: "Nothing visible") }
    }

    // MARK: Planning

    @Test func planningMatchesSlotsByAppThenTitleThenFrontToBack() {
        let windows = [
            WindowFixture.window(pid: 1, token: 1, bundle: "com.example.browser", title: "News"),
            WindowFixture.window(pid: 1, token: 2, bundle: "com.example.browser", title: "Docs"),
            WindowFixture.window(pid: 1, token: 3, bundle: "com.example.browser", title: "Mail"),
        ]
        let layout = SavedWindowLayout(
            name: "Research",
            slots: [
                slot("com.example.browser", title: "Docs", region: UnitRect(x: 0, y: 0, width: 0.5, height: 1)),
                slot("com.example.browser", title: "Gone", region: UnitRect(x: 0.5, y: 0, width: 0.5, height: 1)),
            ])
        let plan = WindowLayoutPlanner.plan(layout, displays: displays, windows: windows)
        #expect(plan.moves.map(\.window.token) == [2, 1])
        #expect(plan.moves.map(\.frame) == [
            CGRect(x: 0, y: 76, width: 720, height: 800), CGRect(x: 720, y: 76, width: 720, height: 800),
        ])
        #expect(plan.moves.map(\.displayIndex) == [0, 0])
        #expect(plan.launches.isEmpty && plan.unmatchedSlots.isEmpty)
    }

    @Test func exactTitleMatchesAreReservedBeforeFallbacks() {
        // The first slot's document is gone; the second slot's document survives
        // and belongs on the other display. Fallbacks must not take it.
        let windows = [
            WindowFixture.window(pid: 1, token: 2, bundle: "com.example.editor", title: "Report"),
            WindowFixture.window(pid: 1, token: 1, bundle: "com.example.editor", title: "Scratch"),
        ]
        let layout = SavedWindowLayout(
            name: "Writing",
            slots: [
                slot("com.example.editor", title: "Deleted draft", display: 1, name: "Built-in Display"),
                slot("com.example.editor", title: "Report", display: 0, name: "Studio Display"),
            ])
        let plan = WindowLayoutPlanner.plan(layout, displays: displays, windows: windows)
        #expect(plan.moves.map(\.window.token) == [1, 2])
        #expect(plan.moves.map(\.displayIndex) == [0, 1])
        #expect(plan.moves[1].frame == WindowFixture.secondary.visibleFrame)
        #expect(plan.unmatchedSlots.isEmpty)
    }

    @Test func planningLaunchesMissingAppsOnceAndPrefersVisibleWindows() {
        let windows = [
            WindowFixture.window(pid: 1, token: 1, bundle: "com.example.chat", minimized: true),
            WindowFixture.window(pid: 1, token: 2, bundle: "com.example.chat"),
        ]
        let layout = SavedWindowLayout(
            name: "Chat",
            slots: [
                slot("com.example.chat"), slot("com.example.chat"), slot("com.example.music"),
                slot("com.example.music"),
            ])
        let plan = WindowLayoutPlanner.plan(layout, displays: displays, windows: windows)
        #expect(plan.moves.map(\.window.token) == [2, 1])
        #expect(plan.moves.map(\.unminimize) == [false, true])
        #expect(plan.launches == ["com.example.music"])
        #expect(plan.unmatchedSlots == [layout.slots[2].id, layout.slots[3].id])
    }

    @Test func cleanupTakesOnlyKnownUnclaimedWindowsOnDisplaysThatGotAWindow() {
        var windows = desk()
        windows.append(WindowFixture.window(pid: 500, token: 5, bundle: "com.example.unknown", frame: nil))
        windows.append(
            WindowFixture.window(
                pid: 600, token: 6, bundle: "com.example.lost", frame: CGRect(x: 9_000, y: 0, width: 100, height: 100)))
        let targets = WindowLayoutPlanner.cleanupTargets(
            visible: windows, claimed: [WindowHandle(pid: 100, token: 1)], displays: displays, placedDisplays: [0])
        // The browser shares the laptop. Chat is on the other display, the minimized
        // window is skipped, and windows with unknown or off-display frames are left alone.
        #expect(targets.map(\.token) == [2])
        #expect(
            WindowLayoutPlanner.cleanupTargets(visible: windows, claimed: [], displays: displays, placedDisplays: [])
                .isEmpty)
    }

    @Test func slotsFindTheirDisplayByNameThenPositionThenFallBackToTheMainDisplay() {
        #expect(WindowLayoutPlanner.displayIndex(for: slot("a", display: 0, name: "Built-in Display"), in: displays) == 0)
        #expect(WindowLayoutPlanner.displayIndex(for: slot("a", display: 0, name: "Unplugged"), in: displays) == 1)
        #expect(WindowLayoutPlanner.displayIndex(for: slot("a", display: 1, name: nil), in: displays) == 0)
        #expect(WindowLayoutPlanner.displayIndex(for: slot("a", display: 5, name: nil), in: displays) == 0)
        let plan = WindowLayoutPlanner.plan(
            SavedWindowLayout(name: "x", slots: [slot("a")]), displays: [], windows: [])
        #expect(plan.moves.isEmpty && plan.unmatchedSlots.count == 1)
    }

    // MARK: Applying

    @Test func applyingPlacesWindowsMinimizesOthersAndRaisesTheFirstSlotLast() async throws {
        let (manager, system) = makeManager()
        var layout = SavedWindowLayout(
            name: "Swap",
            slots: [
                slot("com.example.browser", display: 1, region: UnitRect(x: 0, y: 0, width: 0.5, height: 1)),
                slot("com.example.chat", title: "Hidden", display: 1, region: UnitRect(x: 0.5, y: 0, width: 0.5, height: 1)),
            ])
        layout.otherWindows = .minimize
        let outcome = try await manager.apply(layout, launcher: FakeApplicationLauncher(), sleep: { _ in })
        #expect(outcome == WindowLayoutOutcome(requested: 2, placed: 2))
        #expect(outcome.message == "Arranged 2 windows")
        #expect(
            system.events == [
                .setFrame(2, CGRect(x: 0, y: 76, width: 720, height: 800)),
                .minimized(4, false),
                .setFrame(4, CGRect(x: 720, y: 76, width: 720, height: 800)),
                .minimized(1, true),
                .focus(4),
                .focus(2),
            ])
    }

    @Test func applyingLaunchesMissingAppsAndWaitsForTheirWindows() async throws {
        let (manager, system) = makeManager(windows: [])
        let launcher = FakeApplicationLauncher()
        launcher.onLaunch = { bundle in
            system.windowList.append(WindowFixture.window(pid: 400, token: 40, app: "Music", bundle: bundle))
        }
        let layout = SavedWindowLayout(name: "Music", slots: [slot("com.example.music", app: "Music")])
        let outcome = try await manager.apply(layout, launcher: launcher, sleep: { _ in })
        #expect(launcher.launched == ["com.example.music"])
        #expect(outcome == WindowLayoutOutcome(requested: 1, placed: 1))
        #expect(system.frames == [CGRect(x: 0, y: 76, width: 1440, height: 800)])
    }

    @Test func applyingGivesUpOnAppsThatNeverShowAWindowAndCountsEverySlot() async throws {
        let (manager, _) = makeManager()
        let log = SleepLog()
        let layout = SavedWindowLayout(
            name: "Mixed",
            slots: [slot("com.example.editor", app: "Editor"), slot("com.example.ghost", app: "Ghost"),
                    slot("com.example.ghost", app: "Ghost")])
        let outcome = try await manager.apply(
            layout, launcher: FakeApplicationLauncher(), launchTimeout: .seconds(1), pollInterval: .milliseconds(250),
            sleep: { log.record($0) })
        #expect(outcome == WindowLayoutOutcome(requested: 3, placed: 1, missing: ["Ghost"]))
        #expect(outcome.message == "Arranged 1 of 3 windows. No window for Ghost.")
        #expect(log.durations == Array(repeating: .milliseconds(250), count: 4))
    }

    @Test func nothingIsClosedWhenNoWindowWasPlaced() async throws {
        let (manager, system) = makeManager()
        var layout = SavedWindowLayout(
            name: "Uninstalled", slots: [slot("com.example.uninstalled", app: "Gone", display: 1)])
        layout.otherWindows = .close
        let outcome = try await manager.apply(
            layout, launcher: FakeApplicationLauncher(), launchTimeout: .milliseconds(250), sleep: { _ in })
        #expect(outcome == WindowLayoutOutcome(requested: 1, placed: 0, missing: ["Gone"]))
        #expect(system.events.isEmpty)
    }

    @Test func aFailedPlacementIsReportedNotFocusedAndDoesNotClearItsDisplay() async throws {
        let (manager, system) = makeManager()
        system.lockedTokens = [1]
        var layout = SavedWindowLayout(
            name: "Two",
            slots: [slot("com.example.editor", app: "Editor", display: 1), slot("com.example.chat", app: "Chat", display: 0)])
        layout.otherWindows = .close
        let outcome = try await manager.apply(layout, launcher: FakeApplicationLauncher(), sleep: { _ in })
        #expect(outcome == WindowLayoutOutcome(requested: 2, placed: 1, failed: ["Editor"]))
        #expect(outcome.message == "Arranged 1 of 2 windows. Editor didn't move.")
        // Only Chat's display had a placement, and nothing else is visible there.
        #expect(!system.events.contains { if case .close = $0 { return true } else { return false } })
        #expect(!system.events.contains(.focus(1)))
        #expect(system.events.contains(.focus(3)))
    }

    @Test func cleanupFailuresAreReported() async throws {
        let (manager, system) = makeManager()
        system.closeFailures = [1]
        var layout = SavedWindowLayout(name: "Browser", slots: [slot("com.example.browser", display: 1)])
        layout.otherWindows = .close
        let outcome = try await manager.apply(layout, launcher: FakeApplicationLauncher(), sleep: { _ in })
        #expect(outcome == WindowLayoutOutcome(requested: 1, placed: 1, cleanupFailures: 1))
        #expect(outcome.message == "Arranged 1 of 1 window. 1 other window stayed open.")
    }

    @Test func cancellingStopsBeforeAnythingMovesOrCloses() async {
        let (manager, system) = makeManager()
        let launcher = FakeApplicationLauncher()
        var layout = SavedWindowLayout(
            name: "Cancelled", slots: [slot("com.example.browser"), slot("com.example.music", app: "Music")])
        layout.otherWindows = .close
        let run = Task { try await manager.apply(layout, launcher: launcher, sleep: { _ in }) }
        // The person cancels while the missing app launches.
        launcher.onLaunch = { _ in run.cancel() }
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(launcher.launched == ["com.example.music"])
        #expect(system.events.isEmpty)
    }

    @Test func aCancelledWaitStopsTheLayout() async {
        let (manager, system) = makeManager()
        let layout = SavedWindowLayout(
            name: "Waiting", slots: [slot("com.example.browser"), slot("com.example.music", app: "Music")])
        await #expect(throws: CancellationError.self) {
            try await manager.apply(layout, launcher: FakeApplicationLauncher(), sleep: { _ in throw CancellationError() })
        }
        #expect(system.events.isEmpty)
    }

    @Test func applyingNeedsAccessibilityAndAValidLayout() async {
        let (manager, system) = makeManager()
        await #expect(throws: LibraryValidationError.self) {
            try await manager.apply(SavedWindowLayout(name: "Empty", slots: []), launcher: FakeApplicationLauncher())
        }
        system.isTrusted = false
        await #expect(throws: LibraryValidationError.self) {
            try await manager.apply(
                SavedWindowLayout(name: "x", slots: [slot("a")]), launcher: FakeApplicationLauncher())
        }
        #expect(system.events.isEmpty)
    }

    @Test(arguments: [SideEffectGuard.Mode.testHost, .verification])
    func theRealLauncherRefusesInInertLaunches(_ mode: SideEffectGuard.Mode) async {
        let launcher = WorkspaceApplicationLauncher(sideEffects: SideEffectGuard(mode: mode))
        await #expect(throws: SideEffectGuard.Blocked.self) {
            try await launcher.launch(bundleIdentifier: "com.example.never-launched")
        }
    }

    @Test func aMoveTheAppIgnoredNeitherCountsNorClearsTheTargetDisplay() async throws {
        let (manager, system) = makeManager()
        // Chat sits on the secondary display; its app accepts the write and stays put.
        system.ignoresFrames = [3]
        var layout = SavedWindowLayout(name: "Chat here", slots: [slot("com.example.chat", app: "Chat", title: "Team", display: 1)])
        layout.otherWindows = .close
        let outcome = try await manager.apply(layout, launcher: FakeApplicationLauncher(), sleep: { _ in })
        #expect(outcome == WindowLayoutOutcome(requested: 1, placed: 0, failed: ["Chat"]))
        #expect(!system.events.contains { if case .close = $0 { return true } else { return false } })
        #expect(!system.events.contains(.focus(3)))
    }

    @Test func equalFrameWindowsOnDifferentSpacesAreLeftOutOfCaptureAndCleanup() async throws {
        let shared = CGRect(x: 0, y: 76, width: 1440, height: 800)
        let here = WindowFixture.window(pid: 500, token: 5, app: "Docs", bundle: "com.example.docs", title: "Here", frame: shared)
        let elsewhere = WindowFixture.window(
            pid: 500, token: 6, app: "Docs", bundle: "com.example.docs", title: "Other Space", frame: shared)
        // Only one of the two is on screen, and nothing says which.
        let (manager, system) = makeManager(windows: [here, elsewhere], onScreen: [here])
        #expect(throws: LibraryValidationError.self) { try manager.captureLayout(named: "Unsure") }
        system.windowList.append(WindowFixture.window(pid: 100, token: 1, app: "Editor", bundle: "com.example.editor"))
        var layout = SavedWindowLayout(name: "Editor", slots: [slot("com.example.editor", app: "Editor")])
        layout.otherWindows = .close
        _ = try await manager.apply(layout, launcher: FakeApplicationLauncher(), sleep: { _ in })
        #expect(!system.events.contains(.close(5)) && !system.events.contains(.close(6)))
    }

    // MARK: Model

    @Test func validationEnforcesNameSlotsAndTheEightWindowLimit() throws {
        try SavedWindowLayout(name: "Ok", slots: [slot("a")]).validate()
        let nine = (0..<9).map { _ in slot("a", display: 0) }
        let invalid = [
            SavedWindowLayout(name: " ", slots: [slot("a")]),
            SavedWindowLayout(name: "None", slots: []),
            SavedWindowLayout(name: "Nine", slots: nine),
            SavedWindowLayout(name: "Bad region", slots: [slot("a", region: UnitRect(x: 0.8, y: 0, width: 0.5, height: 1))]),
            SavedWindowLayout(name: "No app", slots: [slot("")]),
        ]
        for layout in invalid {
            #expect(throws: LibraryValidationError.self) { try layout.validate() }
        }
        // Eight on each of two displays is fine.
        try SavedWindowLayout(
            name: "Sixteen", slots: (0..<8).map { _ in slot("a", display: 0) } + (0..<8).map { _ in slot("a", display: 1) }
        ).validate()
    }

    @Test func layoutsRoundTripThroughJSON() throws {
        var layout = WindowLayoutPlanner.capture(named: "Desk", displays: displays, windows: desk())
        layout.otherWindows = .close
        let decoded = try JSONDecoder().decode(SavedWindowLayout.self, from: JSONEncoder().encode(layout))
        #expect(decoded == layout)
        #expect(SavedWindowLayout.OtherWindows.allCases.map(\.title) == ["Leave Open", "Minimize Others", "Close Others"])
    }

    @Test func outcomeMessagesCountAgainstRequestedSlots() {
        #expect(WindowLayoutOutcome(requested: 1, placed: 1).message == "Arranged 1 window")
        #expect(
            WindowLayoutOutcome(requested: 3, placed: 0, missing: ["A", "B"]).message
                == "Arranged 0 of 3 windows. No window for A, B.")
        #expect(
            WindowLayoutOutcome(requested: 4, placed: 2, missing: ["A"], failed: ["B"], cleanupFailures: 2).message
                == "Arranged 2 of 4 windows. No window for A. B didn't move. 2 other windows stayed open.")
        #expect(!WindowLayoutOutcome(requested: 2, placed: 2, cleanupFailures: 1).isComplete)
    }

    private func slot(
        _ bundle: String, app: String = "App", title: String? = nil, display: Int = 1, name: String? = nil,
        region: UnitRect = .full
    ) -> SavedWindowLayout.Slot {
        SavedWindowLayout.Slot(
            bundleIdentifier: bundle, appName: app, windowTitle: title, displayIndex: display, displayName: name,
            region: region)
    }
}
