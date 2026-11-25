import CoreGraphics
import Foundation
import Testing

@testable import OpenRay

@MainActor
struct WindowSwitcherTests {
    /// The laptop is the primary display, 900 pt tall, so AppKit y flips to 900 − maxY.
    private func entry(_ number: UInt32, pid: pid_t, appKitFrame frame: CGRect, layer: Int = 0) -> WindowServerEntry {
        WindowServerEntry(
            number: number, pid: pid, bounds: ScreenCoordinates.flip(frame, primaryHeight: 900), layer: layer)
    }

    private let editorFrame = CGRect(x: 0, y: 76, width: 720, height: 800)
    private let browserFrame = CGRect(x: 720, y: 76, width: 720, height: 800)
    private let notesFrame = CGRect(x: 100, y: 200, width: 600, height: 400)

    private func windows() -> [WindowSnapshot] {
        [
            WindowFixture.window(pid: 100, token: 1, app: "Editor", bundle: "com.example.editor", title: "main.swift", frame: editorFrame),
            WindowFixture.window(pid: 100, token: 2, app: "Editor", bundle: "com.example.editor", title: "", frame: notesFrame),
            WindowFixture.window(pid: 200, token: 3, app: "Browser", bundle: "com.example.browser", title: "Docs", frame: browserFrame),
            WindowFixture.window(pid: 200, token: 4, app: "Browser", bundle: "com.example.browser", title: "Elsewhere", frame: CGRect(x: 5, y: 5, width: 300, height: 300)),
            WindowFixture.window(pid: 300, token: 5, app: "Chat", bundle: "com.example.chat", title: "Team", minimized: true),
        ]
    }

    private func makeSwitcher() -> (WindowSwitcher, FakeWindowSystem) {
        let system = FakeWindowSystem(windows: windows())
        let listing = FakeWindowServerListing([
            entry(90, pid: 999, appKitFrame: CGRect(x: 0, y: 876, width: 1440, height: 24), layer: 25),
            entry(31, pid: 200, appKitFrame: browserFrame),
            entry(12, pid: 100, appKitFrame: notesFrame),
            entry(11, pid: 100, appKitFrame: editorFrame),
        ])
        return (WindowSwitcher(system: system, listing: listing), system)
    }

    @Test func windowsAreOrderedOnScreenFrontToBackThenOtherSpacesThenMinimized() {
        let (switcher, _) = makeSwitcher()
        let listed = switcher.windows()
        #expect(listed.map(\.handle.token) == [3, 2, 1, 4, 5])
        #expect(listed.map(\.windowNumber) == [31, 12, 11, nil, nil])
        #expect(listed.map(\.isOnScreen) == [true, true, true, false, false])
    }

    @Test func orderingMatchesWithinTolerancesAndIgnoresOtherLayersAndMinimizedWindows() {
        let nudged = CGRect(x: 1, y: 77, width: 719, height: 801)
        let ordered = WindowSwitcherOrdering.order(
            [
                WindowFixture.window(pid: 1, token: 1, frame: editorFrame),
                WindowFixture.window(pid: 1, token: 2, frame: editorFrame, minimized: true),
            ],
            entries: [
                entry(5, pid: 1, appKitFrame: editorFrame, layer: 3),
                entry(6, pid: 1, appKitFrame: nudged),
            ], primaryHeight: 900)
        #expect(ordered.map(\.windowNumber) == [6, nil])
        #expect(ordered.map(\.isMinimized) == [false, true])
    }

    @Test func rowsShowTheTitleAndAppAndFallBackToTheAppName() {
        let (switcher, _) = makeSwitcher()
        let listed = switcher.windows()
        let untitled = listed.first { $0.handle.token == 2 }
        #expect(untitled?.title == "Editor")
        #expect(untitled?.subtitle == "")
        let docs = listed.first { $0.handle.token == 3 }
        #expect(docs?.title == "Docs")
        #expect(docs?.subtitle == "Browser")
        #expect(listed.last?.subtitle == "Chat · Minimized")
        #expect(docs?.searchText == "Docs Browser")
        #expect(docs?.icon() == nil)
        #expect(Set(listed.map(\.id)).count == listed.count)
    }

    @Test func searchMatchesTitlesAndAppNames() {
        let (switcher, _) = makeSwitcher()
        let listed = switcher.windows()
        #expect(WindowSwitcher.filter(listed, query: "docs").first?.handle.token == 3)
        #expect(Set(WindowSwitcher.filter(listed, query: "browser").map(\.handle.token)) == [3, 4])
        #expect(WindowSwitcher.filter(listed, query: "main").map(\.handle.token) == [1])
        #expect(WindowSwitcher.filter(listed, query: "  ").count == listed.count)
        #expect(WindowSwitcher.filter(listed, query: "zzzz").isEmpty)
    }

    @Test func focusingRestoresMinimizedWindowsFirst() throws {
        let (switcher, system) = makeSwitcher()
        let listed = switcher.windows()
        try switcher.focus(listed[0])
        #expect(system.events == [.focus(3)])
        system.clearEvents()
        try switcher.focus(listed[4])
        #expect(system.events == [.minimized(5, false), .focus(5)])
    }

    @Test func actionPanelActionsGoThroughTheSystem() throws {
        let (switcher, system) = makeSwitcher()
        let docs = try #require(switcher.windows().first { $0.handle.token == 3 })
        try switcher.minimize(docs)
        try switcher.toggleFullScreen(docs)
        try switcher.hideApplication(of: docs)
        try switcher.close(docs)
        #expect(
            system.events == [
                .minimized(3, true), .fullScreen(3, true), .focus(3), .hide(200), .close(3),
            ])
    }

    @Test func focusNextAndPreviousAppWindowCycleInAStableOrder() throws {
        let (switcher, system) = makeSwitcher()
        system.focusedWindows[100] = WindowHandle(pid: 100, token: 1)
        try switcher.focusAdjacentWindow(of: 100, forward: true)
        #expect(system.events.last == .focus(2))
        system.focusedWindows[100] = WindowHandle(pid: 100, token: 2)
        try switcher.focusAdjacentWindow(of: 100, forward: true)
        #expect(system.events.last == .focus(1))
        try switcher.focusAdjacentWindow(of: 100, forward: false)
        #expect(system.events.last == .focus(1))
        // Chat has a single window.
        #expect(throws: LibraryValidationError.self) { try switcher.focusAdjacentWindow(of: 300, forward: true) }
        #expect(throws: LibraryValidationError.self) { try switcher.focusAdjacentWindow(of: nil, forward: true) }
    }

    @Test func adjacentWindowsPutOnScreenWindowsBeforeOthers() {
        let ordered = [
            SwitchableWindow(snapshot: WindowFixture.window(pid: 1, token: 1, title: "B")),
            SwitchableWindow(snapshot: WindowFixture.window(pid: 1, token: 2, title: "A")),
            SwitchableWindow(snapshot: WindowFixture.window(pid: 1, token: 3, title: "C"), windowNumber: 40),
        ]
        let next = WindowSwitcherOrdering.adjacent(in: ordered, pid: 1, current: nil, forward: true)
        #expect(next?.handle.token == 3)
        let previous = WindowSwitcherOrdering.adjacent(in: ordered, pid: 1, current: nil, forward: false)
        #expect(previous?.handle.token == 1)
        let afterC = WindowSwitcherOrdering.adjacent(
            in: ordered, pid: 1, current: WindowHandle(pid: 1, token: 3), forward: true)
        #expect(afterC?.handle.token == 2)
        #expect(WindowSwitcherOrdering.adjacent(in: ordered, pid: 9, current: nil, forward: true) == nil)
    }

    @Test func withoutAccessibilityNothingIsListedOrChanged() {
        let (switcher, system) = makeSwitcher()
        let listed = switcher.windows()
        system.isTrusted = false
        #expect(!switcher.hasPermission)
        #expect(switcher.windows().isEmpty)
        #expect(throws: LibraryValidationError.self) { try switcher.focus(listed[0]) }
        #expect(throws: LibraryValidationError.self) { try switcher.close(listed[0]) }
        #expect(throws: LibraryValidationError.self) { try switcher.focusAdjacentWindow(of: 100, forward: true) }
        #expect(system.events.isEmpty)
    }

    @Test func openRaysOwnWindowsAreNeverActedOn() {
        let system = FakeWindowSystem(windows: [WindowFixture.window(pid: 1, token: 1)])
        let switcher = WindowSwitcher(system: system, listing: FakeWindowServerListing())
        let own = SwitchableWindow(snapshot: system.windowList[0])
        #expect(throws: LibraryValidationError.self) { try switcher.focus(own) }
        #expect(throws: LibraryValidationError.self) { try switcher.hideApplication(of: own) }
        #expect(system.events.isEmpty)
    }
}
