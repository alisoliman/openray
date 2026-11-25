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

    @Test func capturingKeepsAtMostEightWindowsPerDisplayAndSkipsAppsWithoutIdentifiers() {
        var windows = (0..<10).map {
            WindowFixture.window(pid: pid_t(1_000 + $0), token: $0, bundle: "com.example.app\($0)")
        }
        windows.append(WindowFixture.window(pid: 50, token: 50, bundle: nil))
        let layout = WindowLayoutPlanner.capture(named: "Busy", displays: displays, windows: windows)
        #expect(layout.slots.count == SavedWindowLayout.maximumWindowsPerDisplay)
        #expect(layout.slots.first?.bundleIdentifier == "com.example.app0")
    }

    @Test func savingThroughTheManagerNeedsWindows() throws {
        let system = FakeWindowSystem(displays: displays, windows: desk())
        let manager = WindowManager(system: system)
        #expect(try manager.captureLayout(named: "Desk").slots.count == 3)
        system.windowList.removeAll()
        #expect(throws: LibraryValidationError.self) { try manager.captureLayout(named: "Empty") }
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
        #expect(plan.launches.isEmpty && plan.unmatchedSlots.isEmpty && plan.others.isEmpty)
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

    @Test func otherWindowsAreCollectedOnlyFromTheDisplaysTheLayoutUses() {
        var layout = SavedWindowLayout(
            name: "Focus", slots: [slot("com.example.editor", display: 1, name: "Built-in Display")])
        layout.otherWindows = .minimize
        let plan = WindowLayoutPlanner.plan(layout, displays: displays, windows: desk())
        // The browser shares the laptop; the chat window is on the other display; minimized ones are skipped.
        #expect(plan.others.map(\.token) == [2])
        layout.otherWindows = .leave
        #expect(WindowLayoutPlanner.plan(layout, displays: displays, windows: desk()).others.isEmpty)
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
        let system = FakeWindowSystem(displays: displays, windows: desk())
        let manager = WindowManager(system: system)
        var layout = SavedWindowLayout(
            name: "Swap",
            slots: [
                slot("com.example.browser", display: 1, region: UnitRect(x: 0, y: 0, width: 0.5, height: 1)),
                slot("com.example.chat", title: "Hidden", display: 1, region: UnitRect(x: 0.5, y: 0, width: 0.5, height: 1)),
            ])
        layout.otherWindows = .minimize
        let outcome = try await manager.apply(layout, launcher: FakeApplicationLauncher(), sleep: { _ in })
        #expect(outcome == WindowLayoutOutcome(placed: 2, missing: []))
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
        let system = FakeWindowSystem(displays: displays, windows: [])
        let manager = WindowManager(system: system)
        let launcher = FakeApplicationLauncher()
        launcher.onLaunch = { bundle in
            system.windowList.append(WindowFixture.window(pid: 400, token: 40, app: "Music", bundle: bundle))
        }
        let layout = SavedWindowLayout(name: "Music", slots: [slot("com.example.music", app: "Music")])
        let outcome = try await manager.apply(layout, launcher: launcher, sleep: { _ in })
        #expect(launcher.launched == ["com.example.music"])
        #expect(outcome.placed == 1 && outcome.missing.isEmpty)
        #expect(system.frames == [CGRect(x: 0, y: 76, width: 1440, height: 800)])
    }

    @Test func applyingGivesUpOnAppsThatNeverShowAWindow() async throws {
        let system = FakeWindowSystem(displays: displays, windows: desk())
        let manager = WindowManager(system: system)
        let log = SleepLog()
        let layout = SavedWindowLayout(
            name: "Mixed",
            slots: [slot("com.example.editor", app: "Editor"), slot("com.example.ghost", app: "Ghost"),
                    slot("com.example.ghost", app: "Ghost")])
        let outcome = try await manager.apply(
            layout, launcher: FakeApplicationLauncher(), launchTimeout: .seconds(1), pollInterval: .milliseconds(250),
            sleep: { log.record($0) })
        #expect(outcome == WindowLayoutOutcome(placed: 1, missing: ["Ghost"]))
        #expect(outcome.message == "Arranged 1 of 2 windows. No window for Ghost")
        #expect(log.durations == Array(repeating: .milliseconds(250), count: 4))
    }

    @Test func applyingSkipsWindowsThatRefuseToMoveAndClosesOthersWhenAsked() async throws {
        let system = FakeWindowSystem(displays: displays, windows: desk())
        system.lockedTokens = [1]
        let manager = WindowManager(system: system)
        var layout = SavedWindowLayout(
            name: "Two", slots: [slot("com.example.editor", display: 1), slot("com.example.chat", display: 0)])
        layout.otherWindows = .close
        let outcome = try await manager.apply(layout, launcher: FakeApplicationLauncher(), sleep: { _ in })
        #expect(outcome.placed == 1)
        #expect(system.events.contains(.close(2)))
        #expect(!system.events.contains(.close(3)))
    }

    @Test func applyingNeedsAccessibilityAndAValidLayout() async {
        let system = FakeWindowSystem(displays: displays, windows: desk())
        let manager = WindowManager(system: system)
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

    @Test func outcomeMessagesCountWindows() {
        #expect(WindowLayoutOutcome(placed: 1, missing: []).message == "Arranged 1 window")
        #expect(
            WindowLayoutOutcome(placed: 0, missing: ["A", "B"]).message
                == "Arranged 0 of 2 windows. No window for A, B")
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
