import Foundation
import Testing

@testable import OpenRay

struct MenuItemSearchTests {
    private typealias M = MenuSpec

    /// A small app: the Apple menu, File with a submenu, separators and a disabled item, and Edit.
    private static func menuBar() -> MenuSpec {
        M.bar([
            M.menu("Apple", [M.item("About This Mac"), M.item("Lock Screen", character: "q", modifiers: 4)]),
            M.menu(
                "File",
                [
                    M.item("New Document", character: "n"),
                    M.separator(),
                    M.item(
                        "Export",
                        submenu: [
                            M.item("PDF", character: "e", modifiers: MenuShortcutFormatter.shift),
                            M.item("PNG"),
                        ]),
                    M.item("Close", character: "w", enabled: false),
                ]),
            M.menu(
                "Edit",
                [
                    M.item("Copy", character: "c"),
                    M.item("Find", submenu: [M.item("Find…", character: "f"), M.item("Find Next", character: "g")]),
                    M.item("  "),
                ]),
        ])
    }

    private func collect(
        _ spec: MenuSpec, includeAppleMenu: Bool = false, limits: MenuItemCollector.Limits = .init(),
        elapsed: () -> Duration = { .zero }
    ) -> (MenuItemCollector.Result, FakeMenuTree) {
        let tree = FakeMenuTree(bars: [42: spec])
        let root = tree.menuBar(of: 42)!
        let result = MenuItemCollector.collect(
            from: tree, menuBar: root, includeAppleMenu: includeAppleMenu, limits: limits, elapsed: elapsed,
            isCancelled: { false })
        return (result, tree)
    }

    @Test func flattensMenusIntoPathsAndSkipsTheAppleMenuAndSeparators() {
        let (result, _) = collect(Self.menuBar())
        let items = result.items
        #expect(
            items.map(\.pathText) == [
                "File › New Document", "File › Export › PDF", "File › Export › PNG", "File › Close", "Edit › Copy",
                "Edit › Find › Find…", "Edit › Find › Find Next",
            ])
        #expect(items[1].path == ["File", "Export"])
        #expect(items[1].menuText == "File › Export")
        #expect(items[1].title == "PDF")
        #expect(items.map(\.isEnabled) == [true, true, true, false, true, true, true])
        #expect(Set(items.map(\.id)).count == items.count)
        #expect(!result.truncated && !result.cancelled)
    }

    @Test func eachNodeIsReadOnceAndTheAppleMenuIsNeverRead() {
        let (result, tree) = collect(Self.menuBar())
        #expect(result.items.count == 7)
        #expect(tree.maxReadsPerNode == 1)
        let (withApple, _) = collect(Self.menuBar(), includeAppleMenu: true)
        #expect(withApple.items.first?.pathText == "Apple › About This Mac")
        #expect(withApple.items.count == 9)
    }

    @Test func shortcutsBecomeKeycapsInMenuOrder() {
        let items = collect(Self.menuBar()).0.items
        #expect(items[0].shortcut == ["⌘", "N"])
        #expect(items[1].shortcut == ["⇧", "⌘", "E"])
        #expect(items[2].shortcut == nil)
    }

    @Test func traversalStopsAtDepthItemVisitAndTimeLimits() {
        let deep = M.bar([
            M.menu("Apple", []),
            M.menu("A", [M.item("B", submenu: [M.item("C", submenu: [M.item("D")])])]),
        ])
        #expect(collect(deep).0.items.map(\.pathText) == ["A › B › C › D"])
        let shallow = collect(deep, limits: .init(maxDepth: 2))
        #expect(shallow.0.items.isEmpty && shallow.0.truncated)

        let wide = M.bar([M.menu("Apple", []), M.menu("Many", (0..<50).map { M.item("Item \($0)") })])
        let capped = collect(wide, limits: .init(maxItems: 20))
        #expect(capped.0.items.count == 20 && capped.0.truncated)

        let visited = collect(wide, limits: .init(maxVisitedNodes: 10))
        #expect(visited.0.truncated)
        #expect(visited.1.totalInfoReads <= 10)

        var ticks = 0
        let timed = collect(wide, limits: .init(timeBudget: .seconds(1))) {
            ticks += 1
            return .milliseconds(ticks * 100)
        }
        #expect(timed.0.truncated)
        #expect(timed.0.items.count < 50)
    }

    @Test func itemsWithTheSameLabelStaySeparate() {
        let bar = M.bar([
            M.menu("Apple", []),
            M.menu("Window", [M.item("Zoom", enabled: false), M.item("Zoom", character: "z", modifiers: 2)]),
        ])
        let items = collect(bar).0.items
        #expect(items.count == 2)
        #expect(items.map(\.isEnabled) == [false, true])
        #expect(items[1].shortcut == ["⌥", "⌘", "Z"])
        #expect(items[0].id != items[1].id)
        #expect(MenuItemSearch.filter(items, query: "zoom").first?.isEnabled == true)
    }

    @Test(arguments: [
        (MenuShortcutFormatter.shift | MenuShortcutFormatter.option | MenuShortcutFormatter.control, ["⌃", "⌥", "⇧", "⌘", "X"]),
        (MenuShortcutFormatter.option, ["⌥", "⌘", "X"]),
        (MenuShortcutFormatter.noCommand | MenuShortcutFormatter.control, ["⌃", "X"]),
        (0, ["⌘", "X"]),
    ])
    func modifiersFollowTheMacOSOrder(_ modifiers: Int, _ caps: [String]) {
        #expect(MenuShortcutFormatter.caps(character: "x", modifiers: modifiers, glyph: nil, virtualKey: nil) == caps)
    }

    @Test func glyphsSpecialCharactersAndVirtualKeysGetReadableKeycaps() {
        func caps(_ character: String?, glyph: Int? = nil, key: Int? = nil, modifiers: Int? = nil) -> [String]? {
            MenuShortcutFormatter.caps(character: character, modifiers: modifiers, glyph: glyph, virtualKey: key)
        }
        #expect(caps(nil, glyph: 0x17) == ["⌘", "⌫"])
        #expect(caps(nil, glyph: 0x73) == ["⌘", "F5"])
        #expect(caps(nil, glyph: 0x88, modifiers: MenuShortcutFormatter.noCommand) == ["F14"])
        #expect(caps(nil, glyph: 0x8F) == ["⌘", "F16"])
        #expect(caps(nil, glyph: 0x92) == ["⌘", "F19"])
        #expect(caps(nil, glyph: 0x64) == ["⌘", "←"])
        #expect(caps("\u{F704}") == ["⌘", "F1"])
        #expect(caps("\u{F700}") == ["⌘", "↑"])
        #expect(caps("\r") == ["⌘", "↩"])
        #expect(caps(" ") == ["⌘", "Space"])
        #expect(caps(",") == ["⌘", ","])
        #expect(caps("+") == ["⌘", "+"])
        // No glyph and no printable character: the virtual key names the key.
        #expect(caps(nil, key: 0x7A) == ["⌘", "F1"])
        #expect(caps("", key: 0x33) == ["⌘", "⌫"])
        #expect(caps(nil, key: 0x24, modifiers: MenuShortcutFormatter.shift) == ["⇧", "⌘", "↩"])
        #expect(caps(nil, key: 0x40) == ["⌘", "F17"])
        #expect(caps(nil, key: 0x7E) == ["⌘", "↑"])
        // A printable character wins over the virtual key.
        #expect(caps("k", key: 0x28) == ["⌘", "K"])
        #expect(caps(nil) == nil)
        #expect(caps("") == nil)
        #expect(caps("\u{1}") == nil)
        #expect(caps(nil, key: 0x00) == nil)
        // A glyph the formatter doesn't know falls back to the character.
        #expect(caps("k", glyph: 0x200) == ["⌘", "K"])
    }

    @Test func searchRanksTitlesAbovePathsAndKeepsDisabledItemsLower() {
        let items = collect(Self.menuBar()).0.items
        #expect(MenuItemSearch.filter(items, query: "pdf").first?.pathText == "File › Export › PDF")
        #expect(MenuItemSearch.filter(items, query: "export").map(\.title) == ["PDF", "PNG"])
        #expect(MenuItemSearch.filter(items, query: "find").prefix(2).map(\.title) == ["Find…", "Find Next"])
        #expect(MenuItemSearch.filter(items, query: "").count == items.count)
        #expect(MenuItemSearch.filter(items, query: "qqq").isEmpty)
    }

    // MARK: Reading off the main actor

    @Test func searchReadsTheFrontmostAppsMenusInTheBackground() async throws {
        let tree = FakeMenuTree(bars: [42: Self.menuBar()])
        let search = MenuItemSearch(source: tree)
        let snapshot = try await search.items(for: 42)
        #expect(snapshot.items.count == 7)
        #expect(snapshot.isComplete)
        let limited = try await search.items(for: 42, limits: .init(maxItems: 3))
        #expect(limited.items.count == 3 && !limited.isComplete)
    }

    @Test func searchRefusesWithoutAccessOrATarget() async {
        let tree = FakeMenuTree(bars: [42: Self.menuBar()])
        let search = MenuItemSearch(source: tree)
        await #expect(throws: LibraryValidationError.self) { try await search.items(for: 43) }
        await #expect(throws: LibraryValidationError.self) { try await search.items(for: nil) }
        await #expect(throws: LibraryValidationError.self) {
            try await search.items(for: ProcessInfo.processInfo.processIdentifier)
        }
        let untrusted = MenuItemSearch(source: FakeMenuTree(bars: [42: Self.menuBar()], trusted: false))
        #expect(!untrusted.hasPermission)
        await #expect(throws: LibraryValidationError.self) { try await untrusted.items(for: 42) }
    }

    @Test func cancellingAReadStopsIt() async throws {
        let gate = DispatchSemaphore(value: 0)
        let tree = FakeMenuTree(bars: [42: Self.menuBar()], gate: gate)
        let search = MenuItemSearch(source: tree)
        let read = Task { try await search.items(for: 42) }
        // Wait until the reader is parked at the menu bar, then cancel and let it go.
        var waited = 0
        while !tree.hasEntered && waited < 500 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        #expect(tree.hasEntered)
        read.cancel()
        gate.signal()
        await #expect(throws: CancellationError.self) { try await read.value }
        #expect(tree.totalInfoReads == 0)
    }

    @Test func pressingRunsOnlyEnabledItemsThroughTheReader() async throws {
        let tree = FakeMenuTree(bars: [42: Self.menuBar()])
        let search = MenuItemSearch(source: tree)
        let items = try await search.items(for: 42).items
        let pdf = try #require(items.first { $0.title == "PDF" })
        try await search.press(pdf)
        #expect(tree.pressedTitles == ["PDF"])
        let close = try #require(items.first { $0.title == "Close" })
        await #expect(throws: LibraryValidationError.self) { try await search.press(close) }
        #expect(tree.pressedTitles == ["PDF"])
    }

    @Test(arguments: [SideEffectGuard.Mode.testHost, .verification])
    func realMenuPressesAreBlockedInInertLaunches(_ mode: SideEffectGuard.Mode) {
        let sideEffects = SideEffectGuard(mode: mode)
        // A token node has no element, and the guard runs before any Accessibility call.
        #expect(throws: SideEffectGuard.Blocked(what: "pressing a menu item", mode: mode)) {
            try AXMenuTreeSource(sideEffects: sideEffects).press(MenuNodeRef(token: 0))
        }
        let inert = MenuSearchEnvironment.makeSource(sideEffects: sideEffects)
        #expect(inert is InertMenuTreeSource)
        #expect(!inert.isTrusted)
        #expect(inert.menuBar(of: 1) == nil)
        #expect(throws: SideEffectGuard.Blocked.self) { try inert.press(MenuNodeRef(token: 0)) }
    }
}
