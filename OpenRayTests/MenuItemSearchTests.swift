import ApplicationServices
import Foundation
import Testing

@testable import OpenRay

@MainActor
struct MenuItemSearchTests {
    private typealias M = FakeMenuElement

    /// A small app: the Apple menu, File with a submenu, separators and a disabled item, and Edit.
    private func menuBar() -> FakeMenuElement {
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

    @Test func flattensMenusIntoPathsAndSkipsTheAppleMenuAndSeparators() {
        let items = MenuItemCollector.collect(menuBar: menuBar())
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
    }

    @Test func theAppleMenuCanBeIncluded() {
        let items = MenuItemCollector.collect(menuBar: menuBar(), includeAppleMenu: true)
        #expect(items.first?.pathText == "Apple › About This Mac")
        #expect(items.count == 9)
    }

    @Test func shortcutsBecomeKeycapsInMenuOrder() {
        let items = MenuItemCollector.collect(menuBar: menuBar())
        #expect(items[0].shortcut == ["⌘", "N"])
        #expect(items[1].shortcut == ["⇧", "⌘", "E"])
        #expect(items[2].shortcut == nil)
    }

    @Test func traversalStopsAtItsLimits() {
        let deep = M.bar([
            M.menu("Apple", []),
            M.menu("A", [M.item("B", submenu: [M.item("C", submenu: [M.item("D")])])]),
        ])
        #expect(MenuItemCollector.collect(menuBar: deep).map(\.pathText) == ["A › B › C › D"])
        #expect(MenuItemCollector.collect(menuBar: deep, limits: .init(maxDepth: 2, maxItems: 10)).isEmpty)
        let wide = M.bar([M.menu("Apple", []), M.menu("Many", (0..<50).map { M.item("Item \($0)") })])
        #expect(MenuItemCollector.collect(menuBar: wide, limits: .init(maxDepth: 8, maxItems: 20)).count == 20)
    }

    @Test func duplicatePathsAreListedOnce() {
        let bar = M.bar([M.menu("Apple", []), M.menu("View", [M.item("Zoom"), M.item("Zoom")])])
        #expect(MenuItemCollector.collect(menuBar: bar).count == 1)
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

    @Test func glyphsAndSpecialCharactersGetReadableKeycaps() {
        func caps(_ character: String?, glyph: Int? = nil, modifiers: Int? = nil) -> [String]? {
            MenuShortcutFormatter.caps(character: character, modifiers: modifiers, glyph: glyph, virtualKey: nil)
        }
        #expect(caps(nil, glyph: 0x17) == ["⌘", "⌫"])
        #expect(caps(nil, glyph: 0x73) == ["⌘", "F5"])
        #expect(caps(nil, glyph: 0x88, modifiers: MenuShortcutFormatter.noCommand) == ["F14"])
        #expect(caps(nil, glyph: 0x64) == ["⌘", "←"])
        #expect(caps("\u{F704}") == ["⌘", "F1"])
        #expect(caps("\u{F700}") == ["⌘", "↑"])
        #expect(caps("\r") == ["⌘", "↩"])
        #expect(caps(" ") == ["⌘", "Space"])
        #expect(caps(",") == ["⌘", ","])
        #expect(caps("+") == ["⌘", "+"])
        #expect(caps(nil) == nil)
        #expect(caps("") == nil)
        #expect(caps("\u{1}") == nil)
        // A glyph the formatter doesn't know falls back to the character.
        #expect(caps("k", glyph: 0x200) == ["⌘", "K"])
    }

    @Test func searchRanksTitlesAbovePathsAndKeepsDisabledItemsLower() {
        let items = MenuItemCollector.collect(menuBar: menuBar())
        #expect(MenuItemSearch.filter(items, query: "pdf").first?.pathText == "File › Export › PDF")
        #expect(MenuItemSearch.filter(items, query: "export").map(\.title) == ["PDF", "PNG"])
        #expect(MenuItemSearch.filter(items, query: "find").prefix(2).map(\.title) == ["Find…", "Find Next"])
        #expect(MenuItemSearch.filter(items, query: "").count == items.count)
        #expect(MenuItemSearch.filter(items, query: "qqq").isEmpty)
        let close = [
            MenuBarItem(path: ["File"], title: "Close", shortcut: nil, isEnabled: false, element: M.item("Close")),
            MenuBarItem(path: ["Window"], title: "Close", shortcut: nil, isEnabled: true, element: M.item("Close")),
        ]
        #expect(MenuItemSearch.filter(close, query: "close").map(\.isEnabled) == [true, false])
    }

    @Test func pressingRunsOnlyEnabledItemsThroughTheirElement() throws {
        let search = MenuItemSearch(provider: FakeMenuBarProvider())
        let pdf = M.item("PDF")
        try search.press(MenuBarItem(path: ["File"], title: "PDF", shortcut: nil, isEnabled: true, element: pdf))
        #expect(pdf.pressCount == 1)
        let close = M.item("Close", enabled: false)
        #expect(throws: LibraryValidationError.self) {
            try search.press(MenuBarItem(path: ["File"], title: "Close", shortcut: nil, isEnabled: false, element: close))
        }
        #expect(close.pressCount == 0)
    }

    @Test func itemsComeFromTheFrontmostAppsMenuBar() throws {
        let provider = FakeMenuBarProvider()
        provider.bars[42] = menuBar()
        let search = MenuItemSearch(provider: provider)
        #expect(try search.items(for: 42).count == 7)
        #expect(throws: LibraryValidationError.self) { try search.items(for: 43) }
        #expect(throws: LibraryValidationError.self) { try search.items(for: nil) }
        #expect(throws: LibraryValidationError.self) {
            try search.items(for: ProcessInfo.processInfo.processIdentifier)
        }
        provider.isTrusted = false
        #expect(!search.hasPermission)
        #expect(throws: LibraryValidationError.self) { try search.items(for: 42) }
    }

    @Test func realMenuPressesAreBlockedInTests() {
        #expect(throws: SideEffectGuard.Blocked.self) {
            try AXMenuElement(AXUIElementCreateApplication(-1)).press()
        }
    }
}
