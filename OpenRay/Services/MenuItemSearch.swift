import AppKit
@preconcurrency import ApplicationServices

/// One element of an app's menu bar, as Accessibility reports it. `AXMenuElement`
/// is the real one; tests build trees of fakes and never press a real menu item.
@MainActor
protocol MenuAXElement: AnyObject {
    /// AXMenuBar, AXMenuBarItem, AXMenu or AXMenuItem.
    var role: String? { get }
    var title: String? { get }
    var isEnabled: Bool { get }
    /// kAXMenuItemCmdCharAttribute and friends: the item's keyboard shortcut.
    var commandCharacter: String? { get }
    var commandModifiers: Int? { get }
    var commandGlyph: Int? { get }
    var commandVirtualKey: Int? { get }
    var children: [any MenuAXElement] { get }
    func press() throws
}

/// Reads the menu bar of a running app.
@MainActor
protocol MenuBarProviding: AnyObject {
    var isTrusted: Bool { get }
    /// Nil without Accessibility access or when the app has no menu bar.
    func menuBar(of pid: pid_t) -> (any MenuAXElement)?
}

/// A menu item you can run, flattened out of its menus.
struct MenuBarItem: Identifiable {
    /// The menus that lead to the item, e.g. ["File", "Export"].
    let path: [String]
    let title: String
    /// Keycaps in menu order, e.g. ["⇧", "⌘", "E"].
    let shortcut: [String]?
    let isEnabled: Bool
    let element: any MenuAXElement

    var id: String { (path + [title]).joined(separator: "\u{1F}") }
    /// "File › Export › PDF".
    var pathText: String { (path + [title]).joined(separator: " › ") }
    /// The menus alone, for a subtitle: "File › Export".
    var menuText: String { path.joined(separator: " › ") }
}

enum MenuItemCollector {
    struct Limits: Sendable {
        var maxDepth = 8
        var maxItems = 4_000
    }

    static let menuBarRole = "AXMenuBar"
    static let menuBarItemRole = "AXMenuBarItem"
    static let menuRole = "AXMenu"
    static let menuItemRole = "AXMenuItem"

    /// Every leaf item under the menu bar, in menu order. Separators and empty
    /// titles drop out, submenus become path components, and the Apple menu is
    /// skipped unless asked for: it is the same in every app.
    @MainActor
    static func collect(
        menuBar: any MenuAXElement, includeAppleMenu: Bool = false, limits: Limits = Limits()
    ) -> [MenuBarItem] {
        var items: [MenuBarItem] = []
        var seen = Set<String>()
        func visit(_ element: any MenuAXElement, path: [String], depth: Int) {
            guard depth <= limits.maxDepth else { return }
            for (index, child) in element.children.enumerated() {
                guard items.count < limits.maxItems else { return }
                switch child.role {
                case menuRole:
                    visit(child, path: path, depth: depth + 1)
                case menuBarItemRole, menuItemRole:
                    if depth == 0 && index == 0 && !includeAppleMenu { continue }
                    let title = (child.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { continue }
                    let submenus = child.children.filter { $0.role == menuRole }
                    if !submenus.isEmpty {
                        for submenu in submenus { visit(submenu, path: path + [title], depth: depth + 1) }
                    } else if child.role == menuItemRole {
                        let item = MenuBarItem(
                            path: path, title: title,
                            shortcut: MenuShortcutFormatter.caps(
                                character: child.commandCharacter, modifiers: child.commandModifiers,
                                glyph: child.commandGlyph, virtualKey: child.commandVirtualKey),
                            isEnabled: child.isEnabled, element: child)
                        if seen.insert(item.id).inserted { items.append(item) }
                    }
                default:
                    continue
                }
            }
        }
        visit(menuBar, path: [], depth: 0)
        return items
    }
}

/// Turns a menu item's Accessibility shortcut attributes into keycaps.
enum MenuShortcutFormatter {
    // kMenuShiftModifier, kMenuOptionModifier, kMenuControlModifier, kMenuNoCommandModifier.
    static let shift = 1
    static let option = 2
    static let control = 4
    static let noCommand = 8

    static func caps(character: String?, modifiers: Int?, glyph: Int?, virtualKey: Int?) -> [String]? {
        let key = glyph.flatMap(glyphName) ?? character.flatMap(characterName)
        guard let key else { return nil }
        let flags = modifiers ?? 0
        var caps: [String] = []
        if flags & control != 0 { caps.append("⌃") }
        if flags & option != 0 { caps.append("⌥") }
        if flags & shift != 0 { caps.append("⇧") }
        if flags & noCommand == 0 { caps.append("⌘") }
        caps.append(key)
        return caps
    }

    /// Carbon's menu glyph codes (Menus.h) for keys a character can't show.
    static func glyphName(_ glyph: Int) -> String? {
        switch glyph {
        case 0x02: "⇥"
        case 0x03: "⇤"
        case 0x04: "⌤"
        case 0x09: "Space"
        case 0x0A: "⌦"
        case 0x0B, 0x0C, 0x0D: "↩"
        case 0x10: "⇣"
        case 0x17: "⌫"
        case 0x1B: "⎋"
        case 0x1C: "⌧"
        case 0x62: "⇞"
        case 0x63: "⇪"
        case 0x64: "←"
        case 0x65: "→"
        case 0x66: "↖"
        case 0x67: "Help"
        case 0x68: "↑"
        case 0x69: "↘"
        case 0x6A: "↓"
        case 0x6B: "⇟"
        case 0x6E: "⏻"
        case 0x6F...0x7A: "F\(glyph - 0x6F + 1)"
        case 0x87...0x89: "F\(glyph - 0x87 + 13)"
        case 0x8C: "⏏"
        default: nil
        }
    }

    /// A shortcut character as a keycap: letters in capitals, function-key
    /// characters by name.
    static func characterName(_ character: String) -> String? {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            let trimmed = character.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed.uppercased()
        }
        switch scalar.value {
        case 0x20: return "Space"
        case 0x0D, 0x03: return "↩"
        case 0x09: return "⇥"
        case 0x1B: return "⎋"
        case 0x08, 0x7F: return "⌫"
        case 0xF700: return "↑"
        case 0xF701: return "↓"
        case 0xF702: return "←"
        case 0xF703: return "→"
        case 0xF704...0xF71A: return "F\(scalar.value - 0xF704 + 1)"
        case 0xF728: return "⌦"
        case 0xF729: return "↖"
        case 0xF72B: return "↘"
        case 0xF72C: return "⇞"
        case 0xF72D: return "⇟"
        case 0x00...0x1F, 0xF700...0xF8FF: return nil
        default: return character.uppercased()
        }
    }
}

/// Search Menu Bar Items: the frontmost app's menu items as one searchable list.
@MainActor
final class MenuItemSearch {
    let provider: any MenuBarProviding

    init(provider: any MenuBarProviding = AXMenuBarProvider()) {
        self.provider = provider
    }

    var hasPermission: Bool { provider.isTrusted }

    func items(for pid: pid_t?) throws -> [MenuBarItem] {
        guard provider.isTrusted else {
            throw LibraryValidationError(
                "Allow OpenRay in System Settings → Privacy & Security → Accessibility to search menu items.")
        }
        guard let pid, pid != ProcessInfo.processInfo.processIdentifier else {
            throw LibraryValidationError("Open OpenRay from another app to search its menus.")
        }
        guard let menuBar = provider.menuBar(of: pid) else {
            throw LibraryValidationError("This app doesn't share its menu bar.")
        }
        return MenuItemCollector.collect(menuBar: menuBar)
    }

    /// Ranks by the item's title first, then its whole path, so "pdf" finds
    /// "File › Export › PDF" and "export" finds everything under Export.
    /// Disabled items stay listed but sink below enabled ones with the same score.
    static func filter(_ items: [MenuBarItem], query: String) -> [MenuBarItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        let scored = items.enumerated().compactMap { offset, item -> (Int, Int, MenuBarItem)? in
            let title = SearchMatcher.score(trimmed, in: item.title)
            let path = SearchMatcher.score(trimmed, in: item.pathText).map { $0 - 100 }
            guard let score = [title, path].compactMap({ $0 }).max() else { return nil }
            return (score + (item.isEnabled ? 1 : 0), offset, item)
        }
        let ranked = scored.sorted { (lhs: (Int, Int, MenuBarItem), rhs: (Int, Int, MenuBarItem)) -> Bool in
            lhs.0 != rhs.0 ? lhs.0 > rhs.0 : lhs.1 < rhs.1
        }
        return ranked.map { $0.2 }
    }

    /// ↩: runs the item. The caller brings the app forward first.
    func press(_ item: MenuBarItem) throws {
        guard item.isEnabled else {
            throw LibraryValidationError("“\(item.title)” is unavailable in this app right now.")
        }
        try item.element.press()
    }
}

// MARK: - Accessibility

@MainActor
final class AXMenuBarProvider: MenuBarProviding {
    /// A hung app must not stall the launcher.
    private static let timeout: Float = 0.5

    nonisolated init() {}

    var isTrusted: Bool { AXIsProcessTrusted() }

    func menuBar(of pid: pid_t) -> (any MenuAXElement)? {
        guard isTrusted else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, Self.timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXMenuBarAttribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return AXMenuElement(unsafeDowncast(value, to: AXUIElement.self))
    }
}

/// A real menu element. Reads its attributes in one round trip, since large apps
/// have thousands of items.
@MainActor
final class AXMenuElement: MenuAXElement {
    private static let attributes = [
        kAXRoleAttribute, kAXTitleAttribute, kAXEnabledAttribute, kAXMenuItemCmdCharAttribute,
        kAXMenuItemCmdModifiersAttribute, kAXMenuItemCmdGlyphAttribute, kAXMenuItemCmdVirtualKeyAttribute,
        kAXChildrenAttribute,
    ]

    let element: AXUIElement
    let role: String?
    let title: String?
    let isEnabled: Bool
    let commandCharacter: String?
    let commandModifiers: Int?
    let commandGlyph: Int?
    let commandVirtualKey: Int?
    private let childElements: [AXUIElement]

    init(_ element: AXUIElement) {
        self.element = element
        AXUIElementSetMessagingTimeout(element, 0.5)
        var values: CFArray?
        let names = Self.attributes as CFArray
        let read =
            AXUIElementCopyMultipleAttributeValues(element, names, AXCopyMultipleAttributeOptions(), &values)
            == .success
        let list = read ? (values as? [AnyObject]) ?? [] : []
        func value(_ index: Int) -> AnyObject? {
            guard list.indices.contains(index) else { return nil }
            let item = list[index]
            // Missing attributes come back as AXValue errors.
            if CFGetTypeID(item) == AXValueGetTypeID(),
                AXValueGetType(unsafeDowncast(item, to: AXValue.self)) == .axError
            {
                return nil
            }
            return item
        }
        role = value(0) as? String
        title = value(1) as? String
        isEnabled = (value(2) as? Bool) ?? true
        commandCharacter = value(3) as? String
        commandModifiers = (value(4) as? NSNumber)?.intValue
        commandGlyph = (value(5) as? NSNumber)?.intValue
        commandVirtualKey = (value(6) as? NSNumber)?.intValue
        childElements = (value(7) as? [AXUIElement]) ?? []
    }

    var children: [any MenuAXElement] { childElements.map { AXMenuElement($0) } }

    func press() throws {
        try SideEffectGuard.check("pressing a menu item")
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
            throw LibraryValidationError("The app didn't run that menu item.")
        }
    }
}
